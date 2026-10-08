import AppKit

/// `--selftest SECONDS [--skip-every SECONDS] [--root DIR]`: plays for a fixed
/// time, sampling memory, then prints a report and exits (status 1 on failure).
/// Without --skip-every it checks that the stream stays continuous across
/// clip boundaries; with it, it hammers the transport controls to check for leaks.
final class SelfTest {
    private let controller: PlayerController
    private let duration: Double
    private let skipEvery: Double?
    private var timers: [Timer] = []
    private var samples: [Double] = []
    private var clipCount = 0
    private var step = 0
    private var scanSeconds = 0.0
    private var baseline = 0.0 // timeline minus wall clock at the first sample

    init(controller: PlayerController, duration: Double, skipEvery: Double?) {
        self.controller = controller
        self.duration = duration
        self.skipEvery = skipEvery
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    func begin(clipCount: Int, scanSeconds: Double) {
        guard timers.isEmpty else { return }
        self.clipCount = clipCount
        self.scanSeconds = scanSeconds
        print(String(format: "scan: %d clips in %.2fs, footprint %.1f MB", clipCount, scanSeconds, Self.footprintMB()))
        timers.append(.scheduledTimer(withTimeInterval: 5, repeats: true) { [unowned self] _ in
            let mb = Self.footprintMB()
            samples.append(mb)
            if samples.count == 1 { baseline = controller.snapshot().timelineSeconds - CACurrentMediaTime() }
            print(String(format: "t+%3ds  clips=%d  footprint=%.1f MB  %@",
                         samples.count * 5, controller.clipsStarted, mb, controller.currentName))
        })
        if let skipEvery {
            timers.append(.scheduledTimer(withTimeInterval: skipEvery, repeats: true) { [unowned self] _ in
                // Cycle through every control, not just skip.
                let actions = [controller.skip, controller.pause, controller.play, controller.skip,
                               controller.stop, controller.play, controller.restart]
                actions[step % actions.count]()
                step += 1
            })
        }
        timers.append(.scheduledTimer(withTimeInterval: duration, repeats: false) { [unowned self] _ in
            finish()
        })
    }

    private func finish() {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let stats = controller.snapshot()
        let half = samples.count / 2
        let mean = { (s: ArraySlice<Double>) in s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count) }

        print("--- selftest report ---")
        print("clips in library:      \(clipCount)")
        print("clips started:         \(controller.clipsStarted)")
        print("clips opened:          \(stats.clipsOpened)")
        print("unplayable, skipped:   \(stats.skippedFiles)")
        print("playback errors:       \(stats.failures)")
        print("late video frames:     \(stats.lateVideoFrames)")
        print("late audio buffers:    \(stats.lateAudioBuffers)")
        print(String(format: "max seam error:        %.3f ms", stats.maxSeamError * 1000))
        if skipEvery == nil {
            // Any stall or gap between clips would show up as the timeline falling behind the wall clock.
            print(String(format: "timeline drift:        %+.1f ms between t+5s and t+%.0fs",
                         (stats.timelineSeconds - CACurrentMediaTime() - baseline) * 1000, duration))
        }
        print(String(format: "CPU:                   %.1fs over %.0fs (%.1f%% of one core)", cpu, duration, cpu / duration * 100))
        print(String(format: "footprint MB:          first half avg %.1f, second half avg %.1f, peak %.1f",
                     mean(samples[..<half]), mean(samples[half...]), samples.max() ?? 0))

        let ok = (skipEvery != nil || controller.state == .playing) && controller.clipsStarted > 1
            && stats.failures == 0 && stats.lateVideoFrames == 0 && stats.lateAudioBuffers == 0
        print(ok ? "RESULT: PASS" : "RESULT: FAIL")
        exit(ok ? 0 : 1)
    }

    /// The same "Memory" figure Activity Monitor shows.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
