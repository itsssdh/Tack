import AppKit
import ScreenCaptureKit

/// The 3-2-1 shown before a screen recording starts. Screenshots have no countdown.
@MainActor
enum CountdownHUD {
    static func run(seconds: Int, on screen: NSScreen) async {
        guard seconds > 0 else { return }
        let size = CGSize(width: 140, height: 140)
        let frame = CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        // Tack is a background app, so without these the panel is hidden whenever the app is not active.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 24
        bg.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "\(seconds)")
        label.font = .systemFont(ofSize: 64, weight: .semibold)
        label.alignment = .center
        label.frame = CGRect(x: 0, y: 36, width: size.width, height: 76)
        bg.addSubview(label)
        panel.contentView = bg
        panel.orderFrontRegardless()

        for remaining in stride(from: seconds, through: 1, by: -1) {
            label.stringValue = "\(remaining)"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        panel.orderOut(nil)
    }
}

@MainActor
final class CaptureService {
    static let shared = CaptureService()

    private var panels: [SelectionPanel] = []
    private var busy = false

    // MARK: Entry points

    func captureArea() { select(mode: .area, allowSwitch: false) }
    func captureWindow() { select(mode: .window, allowSwitch: false) }

    /// Select an area, read its text and QR codes, copy the text.
    func captureText() {
        select(mode: .area, allowSwitch: false) { image in
            Task {
                let result = await Scanner.scan(image)
                ScanHandler.handle(result)
            }
        }
    }

    /// Select an area and keep it floating on top of everything.
    func capturePinned() {
        select(mode: .area, allowSwitch: true) { PinManager.shared.pin($0) }
    }

    func captureFullscreen() {
        run {
            let screen = Self.screenUnderMouse()
            let content = try await Self.shareable()
            let display = try Self.display(for: screen, in: content)
            return try await Self.grab(display: display, content: content, sourceRect: nil)
        }
    }

    func capturePreviousArea() {
        guard let region = Prefs.lastRegion else {
            Alerts.show(title: "No previous area", message: "Capture an area first, then this option repeats it.")
            return
        }
        run {
            let content = try await Self.shareable()
            guard let screen = NSScreen.screens.first(where: { $0.displayID == region.displayID }) else {
                throw CaptureError.displayUnavailable
            }
            let display = try Self.display(for: screen, in: content)
            return try await Self.grab(
                display: display,
                content: content,
                sourceRect: Self.topLeft(region.rect, in: screen)
            )
        }
    }

    // MARK: Plumbing

    private func run(_ work: @escaping () async throws -> CGImage?, deliver: (@MainActor (CGImage) -> Void)? = nil) {
        guard !busy else { return }
        guard Permissions.ensureScreenRecording() else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if let image = try await work() {
                    if let deliver { deliver(image) } else { CaptureOutput.deliver(image) }
                }
            } catch {
                Alerts.show(error)
            }
        }
    }

    /// Lets the user pick an area / window / screen and returns the choice without capturing it.
    /// Used by screen recording.
    func pickTarget(allowSwitch: Bool) async -> (SelectionResult, SCShareableContent)? {
        guard !busy else { return nil }
        guard Permissions.ensureScreenRecording() else { return nil }
        busy = true
        defer { busy = false }
        do {
            let content = try await Self.shareable()
            var frozen: [(NSScreen, CGImage)] = []
            for screen in NSScreen.screens {
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
                frozen.append((screen, try await Self.grab(display: display, content: content, sourceRect: nil)))
            }
            guard !frozen.isEmpty else { throw CaptureError.displayUnavailable }
            let result = await present(frozen: frozen, content: content, mode: .area, allowSwitch: allowSwitch)
            if case .cancelled = result { return nil }
            return (result, content)
        } catch {
            Alerts.show(error)
            return nil
        }
    }

    /// Grabs a region of one screen right now (rect in the screen's bottom-left point coordinates).
    static func grabRegion(screen: NSScreen, rect: CGRect, content: SCShareableContent) async throws -> CGImage {
        let display = try Self.display(for: screen, in: content)
        return try await grab(display: display, content: content, sourceRect: topLeft(rect, in: screen))
    }

    static func displayRect(for rect: CGRect, in screen: NSScreen) -> CGRect { topLeft(rect, in: screen) }

    private func select(mode: SelectionMode, allowSwitch: Bool, deliver: (@MainActor (CGImage) -> Void)? = nil) {
        run({
            let content = try await Self.shareable()
            var frozen: [(NSScreen, CGImage)] = []
            for screen in NSScreen.screens {
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
                let image = try await Self.grab(display: display, content: content, sourceRect: nil)
                frozen.append((screen, image))
            }
            guard !frozen.isEmpty else { throw CaptureError.displayUnavailable }
            let result = await self.present(frozen: frozen, content: content, mode: mode, allowSwitch: allowSwitch)
            return try await self.finish(result, content: content)
        }, deliver: deliver)
    }

    private func present(
        frozen: [(NSScreen, CGImage)],
        content: SCShareableContent,
        mode: SelectionMode,
        allowSwitch: Bool
    ) async -> SelectionResult {
        return await withCheckedContinuation { (cont: CheckedContinuation<SelectionResult, Never>) in
            var done = false
            var observer: NSObjectProtocol?
            var refresh: Task<Void, Never>?
            var finish: ((SelectionResult) -> Void)!
            finish = { [weak self] result in
                guard !done else { return }
                done = true
                refresh?.cancel()
                if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
                EscapeCatcher.shared.end()
                self?.panels.forEach { $0.orderOut(nil) }
                self?.panels.removeAll()
                cont.resume(returning: result)
            }

            // Builds one overlay per screen on the desktop you are on right now.
            let makePanels: (_ frozen: [(NSScreen, CGImage)], _ content: SCShareableContent, _ mode: SelectionMode, _ activate: Bool) -> Void = { [weak self] frozen, content, mode, activate in
                guard let self else { return }
                let candidates = Self.windowCandidates(content)
                for (screen, image) in frozen {
                    let view = SelectionView(
                        screen: screen,
                        frozen: image,
                        targets: Self.targets(candidates, on: screen),
                        mode: mode,
                        allowSwitch: allowSwitch,
                        onResult: finish
                    )
                    self.panels.append(SelectionPanel(screen: screen, view: view))
                }
                // Activating Tack while a full-screen app is in front can throw you back to your desktop, so skip it then.
                if activate, !Self.otherAppIsFullScreen() { NSApp.activate(ignoringOtherApps: true) }
                self.panels.forEach { $0.orderFrontRegardless() }
                let mouse = NSEvent.mouseLocation
                (self.panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? self.panels.first)?.makeKey()
                let refreshCursor: @MainActor @Sendable () -> Void = { [weak self] in
                    self?.panels.forEach {
                        guard let view = $0.contentView as? SelectionView, NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) else { return }
                        view.applyCursor()
                    }
                }
                refreshCursor()
                // The previous overlay's teardown can reset the cursor just after this one appears.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: refreshCursor)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: refreshCursor)
            }
            makePanels(frozen, content, mode, true)

            // Esc always cancels, even after switching desktops.
            EscapeCatcher.shared.begin { finish(.cancelled) }

            // Swiping to another desktop or full-screen app leaves the old overlay behind on its own desktop.
            // Put a fresh overlay (with a fresh picture) on the desktop you arrived at.
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !done else { return }
                    let currentMode = (self.panels.first?.contentView as? SelectionView)?.currentMode ?? mode
                    self.panels.forEach { $0.orderOut(nil) }
                    self.panels.removeAll()
                    refresh?.cancel()
                    refresh = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        guard !Task.isCancelled, !done else { return }
                        var shots: [(NSScreen, CGImage)] = []
                        for screen in NSScreen.screens {
                            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }),
                                  let image = try? await Self.grab(display: display, content: content, sourceRect: nil) else { continue }
                            shots.append((screen, image))
                        }
                        guard !Task.isCancelled, !done, !shots.isEmpty else { return }
                        makePanels(shots, content, currentMode, true)
                        // Quiet pass: once the swipe animation has surely ended, fix up the picture and the window list.
                        try? await Task.sleep(nanoseconds: 650_000_000)
                        guard !Task.isCancelled, !done else { return }
                        if let fresh = try? await Self.shareable() {
                            await self.reloadPanels(content: fresh, quiet: true)
                        }
                    }
                }
            }
        }
    }

    /// Takes a fresh picture of every screen (without Tack's own windows) and puts it in the overlay.
    private func reloadPanels(content: SCShareableContent, quiet: Bool) async {
        let candidates = Self.windowCandidates(content)
        for panel in panels {
            guard let view = panel.contentView as? SelectionView,
                  let screen = NSScreen.screens.first(where: { $0.frame == panel.frame }),
                  let display = content.displays.first(where: { $0.displayID == screen.displayID }),
                  let image = try? await Self.grab(display: display, content: content, sourceRect: nil) else { continue }
            view.reload(frozen: image, targets: Self.targets(candidates, on: screen), quiet: quiet)
        }
        panels.forEach {
            $0.alphaValue = 1
            $0.orderFrontRegardless()
        }
        if !quiet {
            let mouse = NSEvent.mouseLocation
            (panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? panels.first)?.makeKey()
        }
    }

    private func finish(_ result: SelectionResult, content: SCShareableContent) async throws -> CGImage? {
        switch result {
        case .cancelled:
            return nil

        case .fullscreen(_, let frozen):
            return frozen

        case .window(let window):
            return try await Self.grab(window: window)

        case .area(let screen, let rect, let frozen):
            Prefs.lastRegion = SavedRegion(
                displayID: screen.displayID,
                x: rect.minX, y: rect.minY, w: rect.width, h: rect.height
            )
            return try Self.crop(frozen, rect: rect, in: screen)
        }
    }

    // MARK: Helpers

    /// True when another app's window covers a whole screen (a full-screen app is in front).
    static func otherAppIsFullScreen() -> Bool {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) != mine,
                  let b = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = b["Width"], let h = b["Height"], let x = b["X"], let y = b["Y"] else { continue }
            let cocoa = CGRect(x: x, y: primaryHeight - y - h, width: w, height: h)
            if NSScreen.screens.contains(where: { abs($0.frame.width - w) < 2 && abs($0.frame.height - h) < 2 && abs($0.frame.minX - cocoa.minX) < 2 && abs($0.frame.minY - cocoa.minY) < 2 }) {
                return true
            }
        }
        return false
    }

    static func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    static func shareable() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }
    }

    static func display(for screen: NSScreen, in content: SCShareableContent) throws -> SCDisplay {
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.displayUnavailable
        }
        return display
    }

    /// Converts a rect in screen view coordinates (bottom-left origin) to display coordinates (top-left origin).
    static func topLeft(_ rect: CGRect, in screen: NSScreen) -> CGRect {
        CGRect(
            x: rect.minX,
            y: screen.frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func crop(_ image: CGImage, rect: CGRect, in screen: NSScreen) throws -> CGImage {
        let s = CGFloat(image.width) / screen.frame.width
        let pixels = CGRect(
            x: rect.minX * s,
            y: (screen.frame.height - rect.maxY) * s,
            width: rect.width * s,
            height: rect.height * s
        ).integral
        guard let out = image.cropping(to: pixels) else {
            throw CaptureError.captureFailed("Could not crop the selected area.")
        }
        return out
    }

    /// Tack's floating capture UI: everything above normal window level except pinned screenshots, which are content.
    static func chromeWindows(in content: SCShareableContent) -> [SCWindow] {
        let ids = chromeWindowIDs(NSApp.windows)
        return content.windows.filter { ids.contains($0.windowID) }
    }

    static func chromeWindowIDs(_ windows: [NSWindow]) -> Set<CGWindowID> {
        Set(windows
            .filter { $0.level != .normal && $0.identifier != PinWindow.panelIdentifier }
            .compactMap { CGWindowID(exactly: $0.windowNumber) }) // windows not on screen have a number of -1
    }

    static func windowCandidatesForTesting(_ content: SCShareableContent) -> [SCWindow] { windowCandidates(content) }

    /// Windows that are really on screen, ordered front to back so the one you see under the cursor is the one you pick.
    private static func windowCandidates(_ content: SCShareableContent) -> [SCWindow] {
        // macOS lists on-screen windows in true stacking order, frontmost first.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (i, entry) in info.enumerated() {
            guard let number = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1
            if alpha > 0.05 { order[number] = i }
        }
        return content.windows
            .filter {
                $0.isOnScreen
                    && $0.windowLayer == 0
                    && $0.frame.width > 40
                    && $0.frame.height > 40
                    && (order.isEmpty || order[$0.windowID] != nil)
            }
            .sorted { (order[$0.windowID] ?? Int.max) < (order[$1.windowID] ?? Int.max) }
    }

    /// Window frames from ScreenCaptureKit use a top-left origin on the primary display; convert per screen.
    private static func targets(_ windows: [SCWindow], on screen: NSScreen) -> [WindowTarget] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return windows.compactMap { w in
            let cocoa = CGRect(
                x: w.frame.minX,
                y: primaryHeight - w.frame.maxY,
                width: w.frame.width,
                height: w.frame.height
            )
            guard cocoa.intersects(screen.frame) else { return nil }
            return WindowTarget(
                window: w,
                rect: cocoa.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            )
        }
    }

    // MARK: ScreenCaptureKit

    static func grab(display: SCDisplay, content: SCShareableContent, sourceRect: CGRect?) async throws -> CGImage {
        // Tack's own windows (Settings, the editor, History, pinned screenshots) are captured like any other app's.
        // Only its temporary capture UI (selection overlay, countdown, previews, recording bar) is left out.
        let filter = SCContentFilter(display: display, excludingWindows: chromeWindows(in: content))
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        let area = sourceRect ?? CGRect(origin: .zero, size: info.contentRect.size)

        let config = SCStreamConfiguration()
        if sourceRect != nil { config.sourceRect = area }
        config.width = max(1, Int((area.width * scale).rounded()))
        config.height = max(1, Int((area.height * scale).rounded()))
        config.showsCursor = Prefs.showCursor
        config.captureResolution = .best

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }
    }

    static func grab(window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)

        let config = SCStreamConfiguration()
        config.width = max(1, Int((info.contentRect.width * scale).rounded()))
        config.height = max(1, Int((info.contentRect.height * scale).rounded()))
        config.showsCursor = Prefs.showCursor
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }
    }
}
