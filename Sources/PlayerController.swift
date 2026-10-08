import AVFoundation

/// Plays an endless random sequence of clips as one continuous stream.
///
/// Rather than handing whole files to AVPlayer (which pauses for ~100 ms at
/// every file boundary), each clip is demuxed with AVAssetReader and its
/// samples are re-stamped onto a single running timeline, then fed to an
/// AVSampleBufferDisplayLayer (hardware decode) and audio renderer. The seam
/// between two clips is therefore just two adjacent frames.
///
/// Memory stays flat regardless of library size: the renderers pull only about
/// a second of compressed samples ahead, and at most two files are open at
/// once (while audio and video straddle a seam).
final class PlayerController {
    enum State { case stopped, playing, paused }

    struct Stats {
        var clipsOpened = 0
        var skippedFiles = 0     // no video track or unreadable; passed over
        var failures = 0         // read or decode errors mid-clip
        var lateVideoFrames = 0  // enqueued after their presentation time
        var lateAudioBuffers = 0
        var maxSeamError = 0.0   // seconds a clip's frames stray from its timeline slot
        var timelineSeconds = 0.0
    }

    private final class Clip {
        let name: String
        let reader: AVAssetReader
        let video: AVAssetReaderTrackOutput
        let audio: AVAssetReaderTrackOutput?
        let start: CMTime   // timeline time of the first frame
        let end: CMTime     // timeline time at which the next clip starts
        let offset: CMTime  // added to every sample timestamp
        let audioOffset: CMTime
        var firstVideo: CMSampleBuffer?
        var videoDone = false
        var audioDone: Bool
        var firstPTS = CMTime.positiveInfinity
        var lastEnd = CMTime.negativeInfinity

        init?(url: URL, start: CMTime) {
            let asset = AVURLAsset(url: url)
            guard let videoTrack = asset.tracks(withMediaType: .video).first,
                  let reader = try? AVAssetReader(asset: asset) else { return nil }
            // Compressed samples pass straight through to the display layer's decoder.
            video = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            video.alwaysCopiesSampleData = false
            guard reader.canAdd(video) else { return nil }
            reader.add(video)
            // Audio is decoded to PCM so consecutive clips join without codec priming gaps.
            var audio: AVAssetReaderTrackOutput?
            if let audioTrack = asset.tracks(withMediaType: .audio).first {
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
                output.alwaysCopiesSampleData = false
                if reader.canAdd(output) {
                    reader.add(output)
                    audio = output
                }
            }
            let range = videoTrack.timeRange
            reader.timeRange = range
            guard range.duration.isNumeric, range.duration > .zero, reader.startReading() else { return nil }
            // The clip's slot on the timeline is exactly the span of its video frames, and audio
            // is trimmed to it. Pass-through video keeps raw media timestamps (an edit list can
            // shift them, or start the picture later than the sound), so the slot is measured
            // from the frames themselves rather than taken from the track's rounded time range.
            var first: CMSampleBuffer?
            repeat { first = video.copyNextSampleBuffer() } while first != nil && first!.numSamples == 0
            guard let first else { return nil }
            firstVideo = first
            self.name = url.lastPathComponent
            self.reader = reader
            self.audio = audio
            self.audioDone = audio == nil
            self.start = start
            let firstPTS = first.presentationTimeStamp
            let mediaEnd = videoTrack.makeSampleCursor(presentationTimeStamp: .positiveInfinity)
                .map { $0.presentationTimeStamp + $0.currentSampleDuration }
            if let mediaEnd, mediaEnd.isNumeric, mediaEnd > firstPTS {
                self.end = start + (mediaEnd - firstPTS)
            } else {
                self.end = start + range.duration
            }
            self.offset = start - firstPTS
            // Audio is delivered in track time; find where the first frame sits there to keep sync.
            let segment = videoTrack.segments.first {
                !$0.isEmpty && $0.timeMapping.source.containsTime(firstPTS)
            }
            let firstFrameTrackTime = segment.map {
                $0.timeMapping.target.start + (firstPTS - $0.timeMapping.source.start)
            } ?? range.start
            self.audioOffset = start - firstFrameTrackTime
        }
    }

    let videoLayer = AVSampleBufferDisplayLayer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "VideoRandomizer.feed", qos: .userInitiated)

    // Main-thread state.
    private(set) var state: State = .stopped
    private(set) var currentName = ""
    private(set) var clipCount = 0
    private(set) var clipsStarted = 0
    var onChange: (() -> Void)?
    private var generation = 0
    private var boundaryObservers: [Int: Any] = [:]
    private var nextObserverID = 0
    private var sleepBlocker: NSObjectProtocol?

    // Feed-queue state.
    private var library: Library?
    private var clips: [Clip] = []
    private var timelineEnd = CMTime.zero
    private var feedGeneration = 0
    private var stats = Stats()

    init() {
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        synchronizer.addRenderer(videoLayer)
        synchronizer.addRenderer(audioRenderer)
        NotificationCenter.default.addObserver(
            forName: .AVSampleBufferDisplayLayerFailedToDecode, object: videoLayer, queue: nil
        ) { [weak self] note in
            NSLog("Decode error: %@", String(describing: note.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey]))
            self?.queue.async { self?.stats.failures += 1 }
        }
    }

    // MARK: Controls (main thread)

    func setLibrary(_ library: Library?) {
        stop()
        clipCount = library?.count ?? 0
        queue.async { self.library = library }
    }

    func play() {
        guard clipCount > 0 else { return }
        if state == .stopped {
            begin(reshuffle: false)
        } else {
            queue.async { self.synchronizer.rate = 1 }
        }
        setState(.playing)
    }

    func pause() {
        guard state == .playing else { return }
        queue.async { self.synchronizer.rate = 0 }
        setState(.paused)
    }

    func stop() {
        invalidateSchedule()
        queue.async {
            self.halt()
            self.videoLayer.flushAndRemoveImage()
        }
        currentName = ""
        setState(.stopped)
    }

    /// Starts over with a fresh random order.
    func restart() {
        guard clipCount > 0 else { return }
        begin(reshuffle: true)
        setState(.playing)
    }

    /// Cuts to a new clip immediately.
    func skip() {
        guard state != .stopped else { return }
        begin(reshuffle: false)
        setState(.playing)
    }

    func snapshot() -> Stats {
        queue.sync {
            var s = stats
            s.timelineSeconds = synchronizer.currentTime().seconds
            return s
        }
    }

    private func setState(_ new: State) {
        state = new
        if new == .playing, sleepBlocker == nil {
            sleepBlocker = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing video")
        } else if new != .playing, let blocker = sleepBlocker {
            ProcessInfo.processInfo.endActivity(blocker)
            sleepBlocker = nil
        }
        onChange?()
    }

    private func invalidateSchedule() {
        generation += 1
        boundaryObservers.values.forEach(synchronizer.removeTimeObserver)
        boundaryObservers.removeAll()
    }

    private func begin(reshuffle: Bool) {
        invalidateSchedule()
        let generation = generation
        queue.async {
            self.halt()
            self.feedGeneration = generation
            if reshuffle { self.library?.reshuffle() }
            // Fill both renderers before starting the clock so the first frames are on time.
            self.feedVideo()
            self.feedAudio()
            self.synchronizer.setRate(1, time: .zero)
            self.videoLayer.requestMediaDataWhenReady(on: self.queue) { [weak self] in self?.feedVideo() }
            self.audioRenderer.requestMediaDataWhenReady(on: self.queue) { [weak self] in self?.feedAudio() }
        }
    }

    /// Updates the displayed name at the moment a clip's first frame is shown.
    private func schedule(name: String, at start: CMTime, generation: Int) {
        guard generation == self.generation else { return }
        if start <= synchronizer.currentTime() {
            clipBegan(name)
            return
        }
        let id = nextObserverID
        nextObserverID += 1
        boundaryObservers[id] = synchronizer.addBoundaryTimeObserver(
            forTimes: [NSValue(time: start)], queue: .main
        ) { [weak self] in
            guard let self, let observer = self.boundaryObservers.removeValue(forKey: id) else { return }
            self.synchronizer.removeTimeObserver(observer)
            self.clipBegan(name)
        }
    }

    private func clipBegan(_ name: String) {
        clipsStarted += 1
        currentName = name
        onChange?()
    }

    // MARK: Feeding (feed queue)

    private func halt() {
        videoLayer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        clips.forEach { $0.reader.cancelReading() }
        clips.removeAll()
        videoLayer.flush()
        audioRenderer.flush()
        synchronizer.setRate(0, time: .zero)
        timelineEnd = .zero
    }

    private func feedVideo() {
        if videoLayer.status == .failed { videoLayer.flush() }
        while videoLayer.isReadyForMoreMediaData {
            guard let clip = clip(needing: \.videoDone) else { return }
            guard let sample = clip.firstVideo ?? clip.video.copyNextSampleBuffer() else {
                finish(clip, \.videoDone)
                continue
            }
            clip.firstVideo = nil
            guard sample.numSamples > 0, let out = retimed(sample, by: clip.offset) else { continue }
            let pts = out.presentationTimeStamp
            clip.firstPTS = min(clip.firstPTS, pts)
            clip.lastEnd = max(clip.lastEnd, pts + out.duration)
            if synchronizer.rate > 0, pts < synchronizer.currentTime() { stats.lateVideoFrames += 1 }
            videoLayer.enqueue(out)
        }
    }

    private func feedAudio() {
        while audioRenderer.isReadyForMoreMediaData {
            guard let clip = clip(needing: \.audioDone) else { return }
            guard let sample = clip.audio?.copyNextSampleBuffer() else {
                finish(clip, \.audioDone)
                continue
            }
            guard sample.numSamples > 0, var out = retimed(sample, by: clip.audioOffset) else { continue }
            // Decoded audio can spill past either end of the clip's slot; cut it at the seams
            // so it never overlaps the neighbouring clips.
            let pts = out.presentationTimeStamp
            let perSample = out.duration.seconds / Double(out.numSamples)
            let head = max(0, Int(((clip.start - pts).seconds / perSample).rounded(.up)))
            let tail = max(0, Int(((pts + out.duration - clip.end).seconds / perSample).rounded(.up)))
            if tail > 0 { finish(clip, \.audioDone) }
            if head > 0 || tail > 0 {
                let keep = out.numSamples - head - tail
                var trimmed: CMSampleBuffer?
                if keep > 0 {
                    CMSampleBufferCopySampleBufferForRange(
                        allocator: nil, sampleBuffer: out, sampleRange: CFRange(location: head, length: keep),
                        sampleBufferOut: &trimmed)
                }
                guard let trimmed else { continue }
                out = trimmed
            }
            if synchronizer.rate > 0, out.presentationTimeStamp < synchronizer.currentTime() {
                stats.lateAudioBuffers += 1
            }
            audioRenderer.enqueue(out)
        }
    }

    /// The earliest open clip that still has samples for this stream, opening the next file if needed.
    private func clip(needing done: KeyPath<Clip, Bool>) -> Clip? {
        if let clip = clips.first(where: { !$0[keyPath: done] }) { return clip }
        guard let library else { return nil }
        // A corrupt file is skipped; a run of them (e.g. the volume was ejected) stops playback.
        for _ in 0..<20 {
            guard let url = library.next() else { break }
            guard let clip = Clip(url: url, start: timelineEnd) else {
                stats.skippedFiles += 1
                NSLog("Skipping unplayable clip %@", url.path)
                continue
            }
            clips.append(clip)
            timelineEnd = clip.end
            stats.clipsOpened += 1
            let generation = feedGeneration
            DispatchQueue.main.async {
                self.schedule(name: clip.name, at: clip.start, generation: generation)
            }
            return clip
        }
        videoLayer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        let generation = feedGeneration
        DispatchQueue.main.async {
            if generation == self.generation { self.stop() }
        }
        return nil
    }

    private func finish(_ clip: Clip, _ done: ReferenceWritableKeyPath<Clip, Bool>) {
        clip[keyPath: done] = true
        if clip.reader.status == .failed {
            stats.failures += 1
            NSLog("Read error in %@: %@", clip.name, clip.reader.error?.localizedDescription ?? "unknown")
        } else if done == \.videoDone, clip.firstPTS.isNumeric {
            let error = max(abs((clip.firstPTS - clip.start).seconds), abs((clip.end - clip.lastEnd).seconds))
            stats.maxSeamError = max(stats.maxSeamError, error)
        }
        clips.removeAll { $0.videoDone && $0.audioDone }
    }

    private func retimed(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard var timing = try? sample.sampleTimingInfos() else { return nil }
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + offset
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = timing[i].decodeTimeStamp + offset
            }
        }
        return try? CMSampleBuffer(copying: sample, withNewTiming: timing)
    }
}
