import AppKit
import AVFoundation
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

// MARK: GIF

enum GIFConverter {
    /// Turns a video into an animated GIF. Runs in the background.
    static func convert(video: URL, to output: URL, fps: Int, maxWidth: Int) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw CaptureError.captureFailed("The recording is empty.") }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        let step = 1.0 / Double(max(1, fps))
        var times: [CMTime] = []
        var t = 0.0
        while t < duration {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += step
        }

        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            throw CaptureError.encodingFailed
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: step]] as CFDictionary

        var count = 0
        for await result in generator.images(for: times) {
            if case .success(_, let image, _) = result {
                CGImageDestinationAddImage(dest, image, frameProps)
                count += 1
            }
        }
        guard count > 0, CGImageDestinationFinalize(dest) else { throw CaptureError.encodingFailed }
    }
}

// MARK: Writer + stream

private func retimed(_ sb: CMSampleBuffer, minus offset: CMTime) -> CMSampleBuffer? {
    var count = 0
    CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    guard count > 0 else { return sb }
    var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
    CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
    for i in infos.indices {
        infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, offset)
        if infos[i].decodeTimeStamp.isValid {
            infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, offset)
        }
    }
    var out: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count, sampleTimingArray: infos, sampleBufferOut: &out)
    return out
}

struct RecordingOptions {
    var fps: Int
    var cursor: Bool
    var systemAudio: Bool
    var microphone: Bool
}

/// Owns one SCStream and one AVAssetWriter. All writer state lives on `queue`.
final class RecordingSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.local.framegrab.recording")
    private let filter: SCContentFilter
    private let pixelSize: CGSize
    private let sourceRect: CGRect?
    private let options: RecordingOptions
    let tempURL: URL

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var micFormat: AudioStreamBasicDescription?
    private var started = false
    private var startPTS = CMTime.zero
    private var firstFrameWait: Date?
    private var paused = false
    private var pauseStart: CMTime?
    private var offset = CMTime.zero
    private(set) var hasSystemAudio = false
    private(set) var hasMic = false
    var onFailure: (@Sendable (String) -> Void)?

    init(filter: SCContentFilter, pixelSize: CGSize, sourceRect: CGRect?, options: RecordingOptions) {
        self.filter = filter
        self.pixelSize = pixelSize
        self.sourceRect = sourceRect
        self.options = options
        self.tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("framegrab-\(UUID().uuidString).mp4")
        super.init()
    }

    func start() async throws {
        let config = SCStreamConfiguration()
        config.width = Int(pixelSize.width) & ~1
        config.height = Int(pixelSize.height) & ~1
        if let sourceRect { config.sourceRect = sourceRect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, options.fps)))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = options.cursor
        config.capturesAudio = options.systemAudio
        config.sampleRate = 48000
        config.channelCount = 2
        if #available(macOS 15.0, *), options.microphone {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if #available(macOS 15.0, *), options.microphone {
            try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        stream = s
        firstFrameWait = Date()
        try await s.startCapture()
    }

    func setPaused(_ on: Bool) {
        queue.async {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if on, !self.paused {
                self.paused = true
                self.pauseStart = now
            } else if !on, self.paused {
                if let p = self.pauseStart { self.offset = CMTimeAdd(self.offset, CMTimeSubtract(now, p)) }
                self.paused = false
                self.pauseStart = nil
            }
        }
    }

    /// Stops capturing and finishes the file. Returns false if no video was recorded.
    func stop() async -> Bool {
        try? await stream?.stopCapture()
        stream = nil
        return await withCheckedContinuation { cont in
            queue.async {
                guard self.started, let writer = self.writer, writer.status == .writing else {
                    self.writer?.cancelWriting()
                    cont.resume(returning: false)
                    return
                }
                // ScreenCaptureKit only sends a frame when something on screen changes. Without this the file would end at the
                // last change, so a recording of a quiet screen (or a quiet last few seconds) came out far too short.
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                let stoppedAt = CMTimeSubtract(self.paused ? (self.pauseStart ?? now) : now, self.offset)
                if stoppedAt > self.startPTS { writer.endSession(atSourceTime: stoppedAt) }
                self.videoInput?.markAsFinished()
                self.systemInput?.markAsFinished()
                self.micInput?.markAsFinished()
                writer.finishWriting {
                    cont.resume(returning: writer.status == .completed)
                }
            }
        }
    }

    // MARK: SCStreamDelegate / Output

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error.localizedDescription)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            handleVideo(sb)
        case .audio:
            if started, !paused { append(sb, to: systemInput) }
        default:
            if #available(macOS 15.0, *), type == .microphone {
                if micFormat == nil,
                   let desc = CMSampleBufferGetFormatDescription(sb),
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                    micFormat = asbd
                }
                if started, !paused { append(sb, to: micInput) }
            }
        }
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        // Only frames that carry new pixels.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           SCFrameStatus(rawValue: raw) != .complete {
            return
        }
        guard CMSampleBufferGetImageBuffer(sb) != nil else { return }
        if paused { return }

        if !started {
            // With a microphone, wait briefly for its first buffer so the file can be set up with the right audio format.
            if options.microphone, micFormat == nil, Date().timeIntervalSince(firstFrameWait ?? Date()) < 2 { return }
            guard startWriter(at: sb.presentationTimeStamp) else { return }
        }
        append(sb, to: videoInput)
    }

    private func startWriter(at pts: CMTime) -> Bool {
        do {
            let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
            let w = Int(pixelSize.width) & ~1
            let h = Int(pixelSize.height) & ~1
            let bitrate = min(max(Double(w * h * options.fps) * 0.08, 4_000_000), 60_000_000)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: options.fps,
                ],
            ])
            video.expectsMediaDataInRealTime = true
            writer.add(video)
            videoInput = video

            if options.systemAudio {
                let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 160_000,
                ])
                a.expectsMediaDataInRealTime = true
                writer.add(a)
                systemInput = a
                hasSystemAudio = true
            }
            if options.microphone, let f = micFormat {
                let channels = Int(max(1, min(2, f.mChannelsPerFrame)))
                let m = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: f.mSampleRate > 0 ? f.mSampleRate : 48000,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: 96_000 * channels,
                ])
                m.expectsMediaDataInRealTime = true
                writer.add(m)
                micInput = m
                hasMic = true
            }
            guard writer.startWriting() else {
                onFailure?(writer.error?.localizedDescription ?? "Could not start the recording file.")
                return false
            }
            writer.startSession(atSourceTime: pts)
            self.writer = writer
            startPTS = pts
            started = true
            return true
        } catch {
            onFailure?(error.localizedDescription)
            return false
        }
    }

    private func append(_ sb: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, let writer, writer.status == .writing else {
            if let w = writer, w.status == .failed { onFailure?(w.error?.localizedDescription ?? "Writing failed.") }
            return
        }
        guard sb.presentationTimeStamp >= startPTS else { return }
        guard input.isReadyForMoreMediaData else { return }
        let out = offset == .zero ? sb : retimed(sb, minus: offset)
        if let out { input.append(out) }
    }
}

// MARK: Controller

@MainActor
final class RecordingController {
    static let shared = RecordingController()

    private(set) var isRecording = false
    var onStateChange: (() -> Void)?

    private var session: RecordingSession?
    private var hud: RecordingHUD?
    private var captureRect = CGRect.zero // global screen coordinates, bottom-left origin
    private var clickMonitor: Any?
    private var indicators = InputIndicators()
    private var clock = RecordingClock()
    private var format = "mp4"
    private var recordingScale: CGFloat = 2
    private var starting = false
    private var outline: RegionOutline?
    private var webcam: WebcamBubble?

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording, !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            await begin()
        }
    }

    private func begin() async {
        guard let (result, _) = await CaptureService.shared.pickTarget(allowSwitch: true) else { return }

        // Work out what to record.
        var screen = NSScreen.main ?? NSScreen.screens[0]
        var sourceRect: CGRect?
        var windowTarget: SCWindow?
        var size: CGSize
        switch result {
        case .area(let s, let rect, _):
            screen = s
            sourceRect = CaptureService.topLeft(rect, in: s)
            size = rect.size
            captureRect = rect.offsetBy(dx: s.frame.minX, dy: s.frame.minY)
        case .fullscreen(let s, _):
            screen = s
            size = s.frame.size
            captureRect = s.frame
        case .window(let w):
            windowTarget = w
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            captureRect = CGRect(x: w.frame.minX, y: primaryHeight - w.frame.maxY, width: w.frame.width, height: w.frame.height)
            screen = NSScreen.screens.first { $0.frame.intersects(captureRect) } ?? screen
            size = w.frame.size
        case .cancelled:
            return
        }
        recordingScale = screen.backingScaleFactor

        // Setup bar: sound, camera, indicators, format. Record or cancel.
        let summary: String
        switch result {
        case .window: summary = "Recording a window"
        case .fullscreen: summary = "Recording the whole screen"
        default: summary = "Recording \(Int(size.width)) × \(Int(size.height))"
        }
        let isWindow = windowTarget != nil
        guard await RecordingSetup.ask(on: screen, summary: summary, allowWebcam: !isWindow) else { return }

        let d = UserDefaults.standard
        var options = RecordingOptions(
            fps: max(5, d.integer(forKey: PrefKey.recFPS)),
            cursor: d.bool(forKey: PrefKey.recCursor),
            systemAudio: d.bool(forKey: PrefKey.recSystemAudio),
            microphone: d.bool(forKey: PrefKey.recMic)
        )
        format = d.string(forKey: PrefKey.recFormat) ?? "mp4"
        if format == "gif" { options.systemAudio = false; options.microphone = false }

        if options.microphone {
            let granted = await Self.microphoneAllowed()
            if !granted {
                options.microphone = false
                Alerts.microphoneNeeded()
            }
            if #unavailable(macOS 15.0) {
                options.microphone = false
                Alerts.show(title: "Microphone needs macOS 15", message: "Recording the microphone together with the screen needs macOS 15 or newer. The recording continues without it.")
            }
        }
        var wantWebcam = d.bool(forKey: PrefKey.recWebcam) && !isWindow && format != "gif"
        if wantWebcam, !(await WebcamBubble.allowed()) {
            wantWebcam = false
            Alerts.show(title: "Camera permission needed", message: "To show your webcam in the recording, turn on Tack in System Settings > Privacy & Security > Camera. The recording continues without it.")
            Permissions.openCameraSettings()
        }

        let scale = screen.backingScaleFactor
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)

        await CountdownHUD.run(seconds: d.integer(forKey: PrefKey.recCountdown), on: screen)

        // The control panel must not appear in the video, so find its window id and exclude it.
        let hud = RecordingHUD(screen: screen)
        hud.onStop = { [weak self] in self?.stop() }
        hud.onPause = { [weak self] paused in self?.setPaused(paused) }
        hud.showInvisibly() // visible only once recording has started; see below
        self.hud = hud

        // A thin frame around the recorded area (not part of the video) and the optional webcam bubble (part of the video).
        var outline: RegionOutline?
        if case .area = result {
            outline = RegionOutline(around: captureRect)
            outline?.showInvisibly()
        }
        self.outline = outline
        if wantWebcam {
            let bubble = WebcamBubble()
            bubble.show(inside: captureRect)
            self.webcam = bubble
        }

        do {
            var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let filter: SCContentFilter
            if let windowTarget {
                filter = SCContentFilter(desktopIndependentWindow: windowTarget)
            } else {
                // Only the recording bar and the area outline stay out of the video. Everything else, including
                // Tack's own Settings, editor and History windows, the click rings and the webcam bubble, is recorded.
                var hidden: [CGWindowID] = [CGWindowID(hud.windowNumber)]
                if let outline { hidden.append(CGWindowID(outline.windowNumber)) }
                // The two windows were only just put on screen, and ScreenCaptureKit can take a moment to list them. If it has not
                // yet, they cannot be excluded and would be recorded (the red dashed outline showed up in a GIF this way), so wait for them.
                for _ in 0..<30 {
                    let listed = Set(content.windows.map { $0.windowID })
                    if hidden.allSatisfy(listed.contains) { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                }
                let display = try CaptureService.display(for: screen, in: content)
                let mine = content.windows.filter { hidden.contains($0.windowID) }
                filter = SCContentFilter(display: display, excludingWindows: mine)
            }
            let session = RecordingSession(filter: filter, pixelSize: pixelSize, sourceRect: sourceRect, options: options)
            session.onFailure = { [weak self] message in
                Task { @MainActor in self?.failed(message) }
            }
            try await session.start()
            self.session = session
            // ScreenCaptureKit's very first frame can still contain windows that are excluded from later ones (the red outline
            // showed up in the opening frame, which a GIF of a still screen then held for its whole length). So the bar and the
            // outline only become visible a moment after capture has begun.
            let hud = self.hud, outline = self.outline
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                hud?.reveal()
                outline?.reveal()
            }
        } catch {
            hud.close()
            self.hud = nil
            self.outline?.close(); self.outline = nil
            self.webcam?.stop(); self.webcam = nil
            Alerts.show(title: "Could not start recording", message: error.localizedDescription + " Check that Screen Recording is allowed for Tack in System Settings.")
            return
        }

        isRecording = true
        clock.reset()
        startMonitors(showClicks: d.bool(forKey: PrefKey.recClicks))
        hud.startTimer(clock: clock)
        onStateChange?()
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func setPaused(_ paused: Bool) {
        session?.setPaused(paused)
        clock.setPaused(paused)
    }

    private func failed(_ message: String) {
        guard isRecording else { return }
        stop(failure: message)
    }

    func stop(failure: String? = nil) {
        guard isRecording, let session else { return }
        isRecording = false
        stopMonitors()
        let hud = self.hud
        outline?.close(); outline = nil
        webcam?.stop(); webcam = nil
        hud?.showConverting("Saving…")
        self.session = nil
        onStateChange?()

        Task {
            let ok = await session.stop()
            hud?.close()
            self.hud = nil
            if let failure {
                Alerts.show(title: "Recording stopped", message: failure)
            }
            guard ok else {
                try? FileManager.default.removeItem(at: session.tempURL)
                if failure == nil {
                    Alerts.show(title: "Nothing was recorded", message: "No video frames arrived. Check that Screen Recording is allowed for Tack in System Settings.")
                }
                return
            }
            await finish(session: session)
        }
    }

    private func finish(session: RecordingSession) async {
        let folder = Prefs.recordingFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let baseName = FileSaver.filename(template: "Recording {date} at {time}", ext: "mp4")
            let videoURL = FileSaver.uniqueURL(in: folder, name: baseName)

            if session.hasSystemAudio && session.hasMic {
                // Mix the two audio tracks into one so every player hears both.
                if await Self.mixAudio(from: session.tempURL, to: videoURL) {
                    try? FileManager.default.removeItem(at: session.tempURL)
                } else {
                    try FileManager.default.moveItem(at: session.tempURL, to: videoURL)
                }
            } else {
                try FileManager.default.moveItem(at: session.tempURL, to: videoURL)
            }

            if format == "gif" {
                let gifURL = FileSaver.uniqueURL(in: folder, name: videoURL.deletingPathExtension().lastPathComponent + ".gif")
                let hud = RecordingHUD(screen: CaptureService.screenUnderMouse())
                hud.show()
                hud.showConverting("Making GIF…")
                defer { hud.close() }
                try await GIFConverter.convert(
                    video: videoURL, to: gifURL,
                    fps: max(1, UserDefaults.standard.integer(forKey: PrefKey.gifFPS)),
                    maxWidth: max(100, UserDefaults.standard.integer(forKey: PrefKey.gifWidth))
                )
                try? FileManager.default.removeItem(at: videoURL)
                History.shared.add(url: gifURL, kind: "gif")
                offerResult(url: gifURL, isGIF: true)
            } else {
                History.shared.add(url: videoURL, kind: "recording")
                offerResult(url: videoURL, isGIF: false)
            }
        } catch {
            Alerts.show(title: "Could not save the recording", message: error.localizedDescription + " The unsaved video is at \(session.tempURL.path).")
        }
    }

    /// The finished recording comes back as a preview in the corner, playing, with Copy and Save showing.
    private func offerResult(url: URL, isGIF: Bool) {
        if Prefs.playSound { NSSound(named: NSSound.Name("Glass"))?.play() }
        QuickAccess.shared.presentMedia(url, isGIF: isGIF, scale: recordingScale, showingActions: true)
    }

    private static func mixAudio(from source: URL, to output: URL) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let audioTracks = try? await asset.loadTracks(withMediaType: .audio), audioTracks.count > 1,
              let duration = try? await asset.load(.duration) else { return false }
        let comp = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: duration)
        guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
        try? v.insertTimeRange(range, of: videoTrack, at: .zero)
        var params: [AVMutableAudioMixInputParameters] = []
        for t in audioTracks {
            guard let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try? a.insertTimeRange(range, of: t, at: .zero)
            let p = AVMutableAudioMixInputParameters(track: a)
            p.setVolume(1, at: .zero)
            params.append(p)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { return false }
        export.outputURL = output
        export.outputFileType = .mp4
        export.audioMix = mix
        await export.export()
        return export.status == .completed
    }

    // MARK: Input indicators

    private func startMonitors(showClicks: Bool) {
        guard showClicks else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, self.isRecording, !self.clock.paused, self.captureRect.contains(location) else { return }
                self.indicators.click(at: location)
            }
        }
    }

    private func stopMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }
}

/// Elapsed recording time with pauses removed.
@MainActor
final class RecordingClock {
    private var started = Date()
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    var paused: Bool { pausedAt != nil }

    func reset() {
        started = Date()
        pausedAt = nil
        pausedTotal = 0
    }

    func setPaused(_ on: Bool) {
        if on, pausedAt == nil { pausedAt = Date() }
        if !on, let p = pausedAt {
            pausedTotal += Date().timeIntervalSince(p)
            pausedAt = nil
        }
    }

    var elapsed: TimeInterval {
        let end = pausedAt ?? Date()
        return max(0, end.timeIntervalSince(started) - pausedTotal)
    }
}

// MARK: Click ring (drawn on screen, so they are part of the video)

@MainActor
final class InputIndicators {
    func click(at point: NSPoint) {
        let size: CGFloat = 70
        let panel = NSPanel(
            contentRect: NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView(frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        view.wantsLayer = true
        let ring = CALayer()
        ring.frame = view.bounds.insetBy(dx: 10, dy: 10)
        ring.cornerRadius = ring.frame.width / 2
        ring.borderWidth = 4
        ring.borderColor = NSColor.systemYellow.cgColor
        ring.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor
        view.layer?.addSublayer(ring)
        panel.contentView = view
        panel.orderFrontRegardless()

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.5
        grow.toValue = 1.15
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.5
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "click")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { panel.orderOut(nil) }
    }
}

// MARK: Control panel

/// Floating recording controls: a glass capsule with a live timer, pause and stop.
@MainActor
final class RecordingHUD: NSObject {
    private var panel: NSPanel
    private let dot = NSTextField(labelWithString: "●")
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private var pauseButton: NSButton!
    private var stopButton: NSButton!
    private var timer: Timer?
    private var paused = false
    private var clock: RecordingClock?
    var onStop: (() -> Void)?
    var onPause: ((Bool) -> Void)?

    var windowNumber: Int { panel.windowNumber }

    init(screen: NSScreen) {
        panel = NSPanel() // replaced below, once the content size is known
        super.init()

        dot.textColor = .systemRed
        dot.font = .systemFont(ofSize: 15)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        timeLabel.textColor = .labelColor

        pauseButton = Glass.iconButton("pause.fill", tip: "Pause / resume", target: self, action: #selector(pauseTapped))
        stopButton = Glass.iconButton("stop.fill", tip: "Stop and save", prominent: true, tint: .systemRed, target: self, action: #selector(stopTapped))

        let stack = NSStackView(views: [dot, timeLabel, pauseButton, stopButton])
        stack.spacing = 12
        stack.alignment = .centerY
        let insets = NSEdgeInsets(top: 8, left: 18, bottom: 8, right: 10)
        let surface = Glass.surface(stack, cornerRadius: 28, insets: insets)
        let size = Glass.fittingSize(of: stack, insets: insets)
        panel = Glass.floatingPanel(surface: surface, size: NSSize(width: max(size.width, 150), height: 56), centerX: screen.frame.midX, bottom: screen.frame.minY + 28)
        panel.isMovableByWindowBackground = true
    }

    func show() { panel.orderFrontRegardless() }
    /// Ordered in but see-through, so the window exists for exclusion but cannot appear in the first recorded frame.
    func showInvisibly() { panel.alphaValue = 0; panel.orderFrontRegardless() }
    func reveal() { panel.alphaValue = 1 }
    func close() {
        timer?.invalidate()
        panel.orderOut(nil)
    }

    func startTimer(clock: RecordingClock) {
        self.clock = clock
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let clock else { return }
        let s = Int(clock.elapsed)
        timeLabel.stringValue = String(format: "%d:%02d", s / 60, s % 60)
        dot.alphaValue = paused ? 0.3 : (s % 2 == 0 ? 1 : 0.5)
    }

    func showConverting(_ text: String) {
        timer?.invalidate()
        pauseButton.isHidden = true
        stopButton.isHidden = true
        dot.isHidden = true
        timeLabel.stringValue = text
        timeLabel.font = .systemFont(ofSize: 15, weight: .medium)
    }

    @objc private func pauseTapped() {
        paused.toggle()
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: paused ? "Resume" : "Pause")
        onPause?(paused)
    }

    @objc private func stopTapped() { onStop?() }
}

// MARK: Setup bar

/// Shown after you pick what to record: choose sound / camera / indicators, then press Record.
@MainActor
final class RecordingSetup: NSObject {
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var videoOnlyChips: [PillButton] = []

    static func ask(on screen: NSScreen, summary: String, allowWebcam: Bool) async -> Bool {
        let setup = RecordingSetup()
        return await setup.run(on: screen, summary: summary, allowWebcam: allowWebcam)
    }

    private func run(on screen: NSScreen, summary: String, allowWebcam: Bool) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            continuation = cont

            let title = glassLabel(summary, size: 13, weight: .semibold, color: .secondaryLabelColor)

            // A GIF has no sound and is too small and choppy for a webcam bubble, so those options go away for GIF.
            videoOnlyChips = [
                chip("Sound", "speaker.wave.2.fill", PrefKey.recSystemAudio),
                chip("Mic", "mic.fill", PrefKey.recMic),
            ]
            if allowWebcam { videoOnlyChips.append(chip("Webcam", "video.fill", PrefKey.recWebcam)) }
            let chips: [NSView] = videoOnlyChips + [chip("Cursor", "cursorarrow", PrefKey.recCursor), chip("Clicks", "cursorarrow.click.2", PrefKey.recClicks)]
            let row1 = NSStackView(views: chips)
            row1.spacing = 8
            let startsAsGIF = UserDefaults.standard.string(forKey: PrefKey.recFormat) == "gif"
            videoOnlyChips.forEach { $0.isHidden = startsAsGIF }

            let format = NSSegmentedControl(labels: ["MP4", "GIF"], trackingMode: .selectOne, target: self, action: #selector(formatChanged(_:)))
            format.selectedSegment = UserDefaults.standard.string(forKey: PrefKey.recFormat) == "gif" ? 1 : 0
            format.controlSize = .large
            let cancel = Glass.button("Cancel", size: .large, target: self, action: #selector(cancelTapped))
            cancel.keyEquivalent = "\u{1b}"
            let record = Glass.button("Record", symbol: "record.circle.fill", prominent: true, tint: .systemRed, size: .large, target: self, action: #selector(recordTapped))
            record.keyEquivalent = "\r"
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            let row2 = NSStackView(views: [format, spacer, cancel, record])
            row2.spacing = 10

            let stack = NSStackView(views: [title, row1, row2])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 14
            row1.setContentHuggingPriority(.required, for: .horizontal)
            row2.translatesAutoresizingMaskIntoConstraints = false
            row2.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

            let insets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
            let surface = Glass.surface(stack, cornerRadius: 30, insets: insets)
            let width: CGFloat = allowWebcam ? 640 : 560
            stack.widthAnchor.constraint(equalToConstant: width - insets.left - insets.right).isActive = true
            let size = Glass.fittingSize(of: stack, insets: insets)
            let p = Glass.floatingPanel(surface: surface, size: size, centerX: screen.frame.midX, bottom: screen.frame.minY + 70, level: .screenSaver, key: true)
            panel = p
            EscapeCatcher.shared.begin { [weak self] in self?.finish(false) }
            if !CaptureService.otherAppIsFullScreen() { NSApp.activate(ignoringOtherApps: true) }
            p.makeKeyAndOrderFront(nil)
        }
    }

    private func chip(_ title: String, _ symbol: String, _ key: String) -> PillButton {
        let b = PillButton(title: title, target: self, action: #selector(toggled(_:)))
        b.kind = .chip
        b.controlSize = .large
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.key = key
        b.isOn = UserDefaults.standard.bool(forKey: key)
        return b
    }

    @objc private func toggled(_ sender: PillButton) {
        sender.isOn.toggle()
        UserDefaults.standard.set(sender.isOn, forKey: sender.key)
    }

    @objc private func formatChanged(_ sender: NSSegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegment == 1 ? "gif" : "mp4", forKey: PrefKey.recFormat)
        // Hidden, not reset: switching back to MP4 brings the options back as they were.
        videoOnlyChips.forEach { $0.isHidden = sender.selectedSegment == 1 }
    }

    @objc private func recordTapped() { finish(true) }
    @objc private func cancelTapped() { finish(false) }

    private func finish(_ go: Bool) {
        guard continuation != nil else { return }
        EscapeCatcher.shared.end()
        panel?.orderOut(nil)
        panel = nil
        continuation?.resume(returning: go)
        continuation = nil
    }
}

// MARK: Region outline (shown while recording an area, not part of the video)

@MainActor
final class RegionOutline {
    private var panel: NSPanel
    var windowNumber: Int { panel.windowNumber }

    init(around rect: CGRect) {
        let outer = rect.insetBy(dx: -4, dy: -4)
        panel = NSPanel(contentRect: outer, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView(frame: NSRect(origin: .zero, size: outer.size))
        view.wantsLayer = true
        let border = CAShapeLayer()
        border.path = CGPath(rect: view.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        border.lineWidth = 3
        border.lineDashPattern = [10, 6]
        view.layer?.addSublayer(border)
        panel.contentView = view
    }

    func show() { panel.orderFrontRegardless() }
    func showInvisibly() { panel.alphaValue = 0; panel.orderFrontRegardless() }
    func reveal() { panel.alphaValue = 1 }
    func close() { panel.orderOut(nil) }
}

// MARK: Webcam bubble (a window on screen, so it is recorded with everything else)

@MainActor
final class WebcamBubble {
    private var panel: NSPanel?
    private var session: AVCaptureSession?

    static func allowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func show(inside rect: CGRect) {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let size: CGFloat = min(200, rect.width * 0.35, rect.height * 0.35)
        guard size > 60 else { return }
        let p = NSPanel(
            contentRect: NSRect(x: rect.minX + 24, y: rect.minY + 24, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView(frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        view.wantsLayer = true
        view.layer?.cornerRadius = size / 2
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 3
        view.layer?.borderColor = NSColor.white.cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        preview.connection?.automaticallyAdjustsVideoMirroring = false
        preview.connection?.isVideoMirrored = true
        view.layer?.addSublayer(preview)
        p.contentView = view
        p.orderFrontRegardless()
        panel = p
        self.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    func stop() {
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s?.stopRunning() }
        session = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
