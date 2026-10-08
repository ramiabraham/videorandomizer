import AppKit
import AVFoundation

/// A view backed directly by the player's display layer, so decoded frames go
/// straight from the hardware decoder to the compositor.
final class PlayerView: NSView {
    private let videoLayer: CALayer
    init(videoLayer: CALayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { videoLayer }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let rootKey = "rootDirectory"

    private let controller = PlayerController()
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private let statusLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private var playButton: NSButton!
    private var pauseButton: NSButton!
    private var stopButton: NSButton!
    private var scanID = 0
    private var scanning = false
    private var selfTest: SelfTest?

    /// The scenes directory beside this project if it exists, else the user's Movies folder.
    private var defaultRoot: String {
        let projectDir = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            projectDir.appendingPathComponent("scene-detect/scenes").path,
            "/Volumes/ssd2tb/tng-scene-detection-project/scene-detect/scenes",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? NSHomeDirectory() + "/Movies"
    }

    private var root: String {
        UserDefaults.standard.string(forKey: Self.rootKey) ?? defaultRoot
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        controller.onChange = { [weak self] in self?.refresh() }

        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        if let seconds = value("--selftest").flatMap(Double.init) {
            selfTest = SelfTest(controller: controller, duration: seconds,
                                skipEvery: value("--skip-every").flatMap(Double.init))
        }
        load(root: value("--root") ?? root)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Library

    private func load(root: String) {
        controller.setLibrary(nil)
        scanID += 1
        let id = scanID
        scanning = true
        refresh()
        DispatchQueue.global(qos: .userInitiated).async {
            let started = CACurrentMediaTime()
            let library = Library(root: root)
            let elapsed = CACurrentMediaTime() - started
            DispatchQueue.main.async {
                guard id == self.scanID else { return } // superseded by a newer scan
                self.scanning = false
                self.controller.setLibrary(library)
                self.selfTest?.begin(clipCount: library.count, scanSeconds: elapsed)
                self.controller.play()
                self.refresh()
            }
        }
    }

    // MARK: UI

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "VideoRandomizer"
        window.minSize = NSSize(width: 480, height: 320)
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        window.setFrameAutosaveName("main")

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
            let b = NSButton(image: image, target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            return b
        }
        playButton = button("play.fill", "Play (Space)", #selector(play))
        pauseButton = button("pause.fill", "Pause (Space)", #selector(pause))
        stopButton = button("stop.fill", "Stop (⌘.)", #selector(stop))
        let restartButton = button("arrow.counterclockwise", "Restart with a new shuffle (⌘R)", #selector(restart))
        let nextButton = button("forward.end.fill", "Next clip (⌘→)", #selector(next))

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [playButton, pauseButton, stopButton, restartButton, nextButton, statusLabel])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        let video = PlayerView(videoLayer: controller.videoLayer)
        let content = NSStackView(views: [video, bar])
        content.orientation = .vertical
        content.spacing = 0
        content.distribution = .fill
        video.setContentHuggingPriority(.defaultLow, for: .vertical)
        bar.setContentHuggingPriority(.required, for: .vertical)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            main.addItem(item)
            let menu = NSMenu(title: title)
            item.submenu = menu
            return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                 _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
        }

        let app = submenu("VideoRandomizer")
        add(app, "About VideoRandomizer", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        app.addItem(.separator())
        add(app, "Settings…", #selector(showSettings), ",")
        app.addItem(.separator())
        add(app, "Hide VideoRandomizer", #selector(NSApplication.hide(_:)), "h")
        add(app, "Quit VideoRandomizer", #selector(NSApplication.terminate(_:)), "q")

        let playback = submenu("Playback")
        add(playback, "Play/Pause", #selector(togglePlay), " ", [])
        add(playback, "Stop", #selector(stop), ".")
        add(playback, "Restart", #selector(restart), "r")
        add(playback, "Next Clip", #selector(next), String(UnicodeScalar(NSRightArrowFunctionKey)!))

        let windowMenu = submenu("Window")
        add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windowMenu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        add(windowMenu, "Close", #selector(NSWindow.performClose(_:)), "w")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    private func refresh() {
        let count = controller.clipCount
        let ready = count > 0
        playButton.isEnabled = ready && controller.state != .playing
        pauseButton.isEnabled = controller.state == .playing
        stopButton.isEnabled = controller.state != .stopped

        if scanning {
            statusLabel.stringValue = "Scanning…"
        } else if !ready {
            statusLabel.stringValue = "No .mp4 files found — choose a folder in Settings (⌘,)"
        } else if controller.state == .stopped {
            statusLabel.stringValue = "Stopped — \(count) clips"
        } else {
            statusLabel.stringValue = controller.currentName
        }
    }

    // MARK: Actions

    @objc private func play() { controller.play() }
    @objc private func pause() { controller.pause() }
    @objc private func stop() { controller.stop() }
    @objc private func restart() { controller.restart() }
    @objc private func next() { controller.skip() }
    @objc private func togglePlay() {
        controller.state == .playing ? controller.pause() : controller.play()
    }

    // MARK: Settings

    @objc private func showSettings() {
        if settingsWindow == nil {
            let title = NSTextField(labelWithString: "Video folder (subfolders are included):")
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.isSelectable = true
            pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseRoot))
            let reset = NSButton(title: "Reset to Default", target: self, action: #selector(resetRoot))
            let buttons = NSStackView(views: [choose, reset])
            let stack = NSStackView(views: [title, pathLabel, buttons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 120),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.contentView = stack
            stack.widthAnchor.constraint(equalToConstant: 520).isActive = true
            w.center()
            settingsWindow = w
        }
        pathLabel.stringValue = root
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: root)
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Self.rootKey)
        pathLabel.stringValue = url.path
        load(root: url.path)
    }

    @objc private func resetRoot() {
        UserDefaults.standard.removeObject(forKey: Self.rootKey)
        pathLabel.stringValue = root
        load(root: root)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
