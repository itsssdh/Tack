import AppKit

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PinView: NSImageView {
    weak var owner: PinWindow?

    override var mouseDownCanMoveWindow: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        owner?.zoom(by: event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.03))
    }

    override func magnify(with event: NSEvent) {
        owner?.zoom(by: event.magnification)
    }

    override func menu(for event: NSEvent) -> NSMenu? { owner?.buildMenu() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One always-on-top screenshot. Drag to move, scroll or pinch to resize, right-click for options.
@MainActor
final class PinWindow: NSObject {
    nonisolated static let panelIdentifier = NSUserInterfaceItemIdentifier("framegrab.pin")
    let image: CGImage
    private let panel: PinPanel
    private let baseSize: NSSize
    private var scale: CGFloat = 1
    private(set) var locked = false
    private var opacity: CGFloat = 1
    var onClose: ((PinWindow) -> Void)?

    init(image: CGImage, near point: NSPoint? = nil) {
        self.image = image
        let screen = point.flatMap { p in NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } } ?? CaptureService.screenUnderMouse()
        let s = screen.backingScaleFactor
        var size = NSSize(width: CGFloat(image.width) / s, height: CGFloat(image.height) / s)
        let maxW = screen.visibleFrame.width * 0.8
        let maxH = screen.visibleFrame.height * 0.8
        let fit = min(maxW / size.width, maxH / size.height, 1)
        size = NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        baseSize = size
        panel = PinPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.level = .floating
        panel.identifier = Self.panelIdentifier
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = PinView(frame: NSRect(origin: .zero, size: size))
        view.owner = self
        view.imageScaling = .scaleAxesIndependently
        view.image = NSImage(cgImage: image, size: size)
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        panel.contentView = view

        let origin = point ?? NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func zoom(by delta: CGFloat) {
        setScale(scale * (1 + delta))
    }

    private func setScale(_ new: CGFloat) {
        let clamped = min(max(new, 0.1), 6)
        let old = panel.frame
        let size = NSSize(width: baseSize.width * clamped, height: baseSize.height * clamped)
        // Keep the center where it is.
        let frame = NSRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2, width: size.width, height: size.height)
        scale = clamped
        panel.setFrame(frame, display: true)
    }

    func bringToFront() { panel.orderFrontRegardless() }

    func setLocked(_ on: Bool) {
        locked = on
        panel.ignoresMouseEvents = on
    }

    func close() {
        panel.orderOut(nil)
        onClose?(self)
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, value) in [("Opacity 100%", 1.0), ("Opacity 75%", 0.75), ("Opacity 50%", 0.5), ("Opacity 25%", 0.25)] {
            let item = NSMenuItem(title: title, action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            if abs(opacity - value) < 0.01 { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let lock = NSMenuItem(title: "Lock Mode (clicks pass through)", action: #selector(lockTapped), keyEquivalent: "")
        lock.target = self
        menu.addItem(lock)
        let reset = NSMenuItem(title: "Actual Size", action: #selector(resetSize), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy", action: #selector(copyTapped), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let text = NSMenuItem(title: "Copy Text (OCR)", action: #selector(ocrTapped), keyEquivalent: "")
        text.target = self
        menu.addItem(text)
        let edit = NSMenuItem(title: "Edit…", action: #selector(editTapped), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close", action: #selector(closeTapped), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        opacity = CGFloat(v)
        panel.alphaValue = opacity
    }

    @objc private func lockTapped() {
        setLocked(true)
        PinManager.shared.showLockHint()
    }

    @objc private func resetSize() { setScale(1) }
    @objc private func copyTapped() { Clipboard.copy(image) }
    @objc private func editTapped() { Editor.open(image) }
    @objc private func closeTapped() { close() }

    @objc private func ocrTapped() {
        let image = self.image
        Task {
            let result = await Scanner.scan(image)
            ScanHandler.handle(result)
        }
    }
}

@MainActor
final class PinManager {
    static let shared = PinManager()
    private(set) var pins: [PinWindow] = []

    var anyLocked: Bool { pins.contains { $0.locked } }

    func pin(_ image: CGImage) {
        let w = PinWindow(image: image)
        w.onClose = { [weak self] closed in self?.pins.removeAll { $0 === closed } }
        pins.append(w)
    }

    func pinFromClipboard() {
        guard let nsImage = NSImage(pasteboard: NSPasteboard.general),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Alerts.show(title: "Nothing to pin", message: "Copy an image first (or capture one), then try again.")
            return
        }
        pin(cg)
    }

    func unlockAll() { pins.forEach { $0.setLocked(false) } }
    /// Puts every pinned screenshot back in front (after a desktop or app switch macOS can leave one hidden).
    func bringAllToFront() { pins.forEach { $0.bringToFront() } }
    func closeAll() { pins.forEach { $0.close() } }

    func showLockHint() {
        // Locked pins ignore the mouse, so tell the user where the way back is.
        Alerts.show(title: "Lock Mode is on", message: "Clicks now pass through this pinned screenshot. To undo it, click the Tack menu bar icon and choose “Unlock Pinned Screenshots”.")
    }
}
