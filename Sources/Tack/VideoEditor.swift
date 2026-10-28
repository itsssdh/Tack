import AppKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers

// MARK: Timeline

private final class TimelineView: NSView {
    var duration: Double = 1 { didSet { needsDisplay = true } }
    var trimStart: Double = 0 { didSet { needsDisplay = true } }
    var trimEnd: Double = 1 { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }

    var onSeek: ((Double) -> Void)?
    /// Called continuously while a trim handle is dragged, with the new start and end and the time under the handle.
    var onTrim: ((Double, Double, Double) -> Void)?
    var onDragBegan: (() -> Void)?

    private enum Drag { case none, seek, trimStart, trimEnd }
    private var drag = Drag.none

    private let inset: CGFloat = 14
    private var trackWidth: CGFloat { max(1, bounds.width - 2 * inset) }
    override var isFlipped: Bool { true }

    private func x(_ t: Double) -> CGFloat { inset + CGFloat(t / max(duration, 0.001)) * trackWidth }
    private func time(_ x: CGFloat) -> Double { min(max(Double((x - inset) / trackWidth) * duration, 0), duration) }
    private var trackRect: CGRect { CGRect(x: inset, y: 12, width: trackWidth, height: 32) }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6).fill()

        let kept = CGRect(x: x(trimStart), y: track.minY, width: x(trimEnd) - x(trimStart), height: track.height)
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: kept, xRadius: 6, yRadius: 6).fill()

        NSColor.black.withAlphaComponent(0.35).setFill()
        CGRect(x: track.minX, y: track.minY, width: x(trimStart) - track.minX, height: track.height).fill()
        CGRect(x: x(trimEnd), y: track.minY, width: track.maxX - x(trimEnd), height: track.height).fill()

        NSColor.white.setFill()
        for t in [trimStart, trimEnd] {
            NSBezierPath(roundedRect: CGRect(x: x(t) - 3, y: track.minY - 3, width: 6, height: track.height + 6), xRadius: 3, yRadius: 3).fill()
        }

        NSColor.systemRed.setFill()
        CGRect(x: x(playhead) - 1, y: 0, width: 2, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = trackRect.insetBy(dx: -10, dy: -6)
        onDragBegan?()
        if abs(p.x - x(trimStart)) < 8, hit.contains(p) { drag = .trimStart; return }
        if abs(p.x - x(trimEnd)) < 8, hit.contains(p) { drag = .trimEnd; return }
        drag = .seek
        onSeek?(time(p.x))
    }

    override func mouseDragged(with event: NSEvent) {
        let t = time(convert(event.locationInWindow, from: nil).x)
        switch drag {
        case .seek:
            onSeek?(t)
        case .trimStart:
            trimStart = min(t, trimEnd - 0.1)
            onTrim?(trimStart, trimEnd, trimStart)
        case .trimEnd:
            trimEnd = max(t, trimStart + 0.1)
            onTrim?(trimStart, trimEnd, trimEnd)
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) { drag = .none }
}

/// Sits over the video. A click plays or pauses.
private final class VideoClickCatcher: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: Window

@MainActor
final class VideoEditorController: NSObject, NSWindowDelegate {
    private let url: URL
    private let asset: AVURLAsset
    private let window: NSWindow
    private let player = AVPlayer()
    private let playerView = AVPlayerView()
    private let timeline = TimelineView()
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let playButton = Glass.iconButton("play.fill", tip: "Play / pause", prominent: true, target: nil, action: #selector(NSResponder.noResponder))
    private let status = NSTextField(labelWithString: "")
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var exportButton: PillButton!

    private var duration: Double = 0
    private var trimStart = 0.0
    private var trimEnd = 0.0
    private var timeObserver: Any?
    private var exporting = false

    // Scrubbing: keep only the newest requested time while a seek is in flight, so dragging stays smooth.
    private var seeking = false
    private var pendingSeek: Double?

    init(url: URL) {
        self.url = url
        asset = AVURLAsset(url: url)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init()
        build()
        Task { await load() }
    }

    private func load() async {
        do {
            duration = try await asset.load(.duration).seconds
        } catch {
            Alerts.show(title: "Could not open the video", message: error.localizedDescription)
            window.close()
            return
        }
        trimStart = 0
        trimEnd = duration
        timeline.duration = duration
        timeline.trimStart = 0
        timeline.trimEnd = duration
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.04, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        updateTime(0)
    }

    private func tick(_ t: Double) {
        if t >= trimEnd - 0.02, player.rate > 0 {
            player.pause()
            playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        }
        // While scrubbing the playhead follows the mouse, not the player.
        guard !seeking, pendingSeek == nil else { return }
        timeline.playhead = t
        updateTime(t)
    }

    private func updateTime(_ t: Double) {
        func f(_ s: Double) -> String { String(format: "%d:%02d.%d", Int(s) / 60, Int(s) % 60, Int((s * 10).truncatingRemainder(dividingBy: 10))) }
        timeLabel.stringValue = "\(f(t)) / \(f(duration))"
    }

    // MARK: UI

    private func tintedLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func pill(_ title: String, symbol: String? = nil, tip: String? = nil, action: Selector) -> PillButton {
        let b = Glass.button(title, symbol: symbol, target: self, action: action)
        b.controlSize = .small
        if let tip { b.toolTip = tip }
        return b
    }

    private func build() {
        window.title = url.lastPathComponent
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 700, height: 480)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.07, alpha: 1)

        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor

        let catcher = VideoClickCatcher()
        catcher.translatesAutoresizingMaskIntoConstraints = false
        catcher.onClick = { [weak self] in self?.playTapped() }

        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.heightAnchor.constraint(equalToConstant: 56).isActive = true
        timeline.onSeek = { [weak self] t in self?.seek(t) }
        timeline.onDragBegan = { [weak self] in self?.pause() }
        timeline.onTrim = { [weak self] s, e, handle in
            guard let self else { return }
            self.trimStart = s
            self.trimEnd = e
            // Show the frame under the handle. Seeking exactly to the end would land past the last frame.
            self.seek(min(handle, max(0, self.duration - 0.04)))
        }
        let timelineGroup = Glass.surface(timeline, cornerRadius: 20, insets: NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6))

        playButton.target = self
        playButton.action = #selector(playTapped)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = .labelColor

        let resetTrim = pill("Reset", symbol: "arrow.counterclockwise", tip: "Undo trimming", action: #selector(resetTrimTapped))
        let playGroup = Glass.group([playButton, timeLabel], spacing: 12, insets: NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 16))
        let trimGroup = Glass.group([resetTrim], spacing: 6)
        let spacer1 = NSView()
        spacer1.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row1 = NSStackView(views: [playGroup, spacer1, trimGroup])
        row1.spacing = 10

        formatPopup.addItems(withTitles: ["MP4 video", "GIF"])
        exportButton = Glass.button("Done", prominent: false, target: self, action: #selector(exportTapped))
        exportButton.keyEquivalent = "\r"
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        let exportGroup = Glass.group([formatPopup, exportButton], spacing: 8)
        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row2 = NSStackView(views: [status, spacer2, exportGroup])
        row2.spacing = 10
        row2.alignment = .centerY

        let controls = NSStackView(views: [timelineGroup, row1, row2])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        for v in [timelineGroup, row1, row2] {
            v.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }

        let root = NSView()
        root.addSubview(playerView)
        root.addSubview(catcher)
        root.addSubview(controls)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: root.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
            catcher.topAnchor.constraint(equalTo: playerView.topAnchor),
            catcher.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            catcher.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            catcher.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        window.contentView = root
    }

    func show() {
        window.centerOnPointerScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Playback

    private func pause() {
        player.pause()
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
    }

    /// Moves the playhead and shows that exact frame. Safe to call on every mouse drag.
    private func seek(_ t: Double) {
        timeline.playhead = t
        updateTime(t)
        pendingSeek = t
        guard !seeking else { return }
        runSeek()
    }

    private func runSeek() {
        guard let t = pendingSeek else { return }
        pendingSeek = nil
        seeking = true
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seeking = false
                if self.pendingSeek != nil { self.runSeek() }
            }
        }
    }

    @objc private func playTapped() {
        if player.rate > 0 {
            pause()
        } else {
            if timeline.playhead < trimStart || timeline.playhead >= trimEnd - 0.05 { seek(trimStart) }
            player.play()
            playButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
        }
    }

    @objc private func resetTrimTapped() {
        trimStart = 0
        trimEnd = duration
        timeline.trimStart = 0
        timeline.trimEnd = duration
        updateTime(timeline.playhead)
    }

    // MARK: Export

    @objc private func exportTapped() {
        guard !exporting else { return }
        pause()
        exporting = true
        exportButton.isEnabled = false
        let asGIF = formatPopup.indexOfSelectedItem == 1
        let range = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600), end: CMTime(seconds: trimEnd, preferredTimescale: 600))
        let folder = Prefs.recordingFolder
        let base = "Edited " + url.deletingPathExtension().lastPathComponent
        let asset = self.asset

        Task {
            defer {
                exporting = false
                exportButton.isEnabled = true
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("framegrab-export-\(UUID().uuidString).mp4")
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                    throw CaptureError.captureFailed("This video cannot be exported.")
                }
                session.outputURL = tmp
                session.outputFileType = .mp4
                session.timeRange = range

                let poll = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.status.stringValue = "Exporting… \(Int(session.progress * 100))%" }
                }
                await session.export()
                poll.invalidate()
                guard session.status == .completed else {
                    throw session.error ?? CaptureError.captureFailed("The export did not finish.")
                }

                let final: URL
                if asGIF {
                    status.stringValue = "Making GIF…"
                    final = FileSaver.uniqueURL(in: folder, name: base + ".gif")
                    try await GIFConverter.convert(
                        video: tmp, to: final,
                        fps: max(1, UserDefaults.standard.integer(forKey: PrefKey.gifFPS)),
                        maxWidth: max(100, UserDefaults.standard.integer(forKey: PrefKey.gifWidth))
                    )
                    try? FileManager.default.removeItem(at: tmp)
                    History.shared.add(url: final, kind: "gif")
                } else {
                    final = FileSaver.uniqueURL(in: folder, name: base + ".mp4")
                    try FileManager.default.moveItem(at: tmp, to: final)
                    History.shared.add(url: final, kind: "recording")
                }
                // Like the photo editor: the editor closes and the result comes back as a preview with Copy and Save showing.
                window.close()
                QuickAccess.shared.presentMedia(final, isGIF: asGIF, showingActions: true)
            } catch {
                status.stringValue = ""
                Alerts.show(title: "Export failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        VideoEditor.release(self)
    }

    /// Closes without asking (used by tests).
    func forceClose() { window.close() }

    /// For the self-test: the trim range, the playhead, and where the player really is.
    var stateForTesting: (trimStart: Double, trimEnd: Double, playhead: Double, playerTime: Double) {
        (trimStart, trimEnd, timeline.playhead, player.currentTime().seconds)
    }

    /// For the self-test: the timeline view and the window it is in.
    var timelineForTesting: NSView { timeline }
}

@MainActor
enum VideoEditor {
    private static var controllers: [VideoEditorController] = []

    static func open(_ url: URL) {
        let c = VideoEditorController(url: url)
        controllers.append(c)
        DockPresence.refresh()
        c.show()
    }

    static func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.directoryURL = Prefs.recordingFolder
        panel.message = "Choose a video to edit"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    static func release(_ controller: VideoEditorController) {
        controllers.removeAll { $0 === controller }
        DockPresence.refresh()
    }

    static var openCount: Int { controllers.count }
    static var firstForTesting: VideoEditorController? { controllers.first }
}
