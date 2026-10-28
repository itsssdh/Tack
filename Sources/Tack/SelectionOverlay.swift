import AppKit
import ScreenCaptureKit

enum SelectionMode {
    case area
    case window
}

enum SelectionResult {
    case area(screen: NSScreen, rect: CGRect, frozen: CGImage)
    case window(SCWindow)
    case fullscreen(screen: NSScreen, frozen: CGImage)
    case cancelled
}

struct WindowTarget {
    let window: SCWindow
    /// In the screen's own coordinates (origin bottom-left, points).
    let rect: CGRect
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen, view: SelectionView) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // Lives on one desktop only: swiping away leaves it behind instead of dragging a stale picture along.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        contentView = view
        setFrame(screen.frame, display: false)
    }
}

/// Shows a frozen copy of one display, dimmed, with crosshair, magnifier and selection.
final class SelectionView: NSView {
    private let screen: NSScreen
    private var frozen: CGImage
    private var targets: [WindowTarget]
    private var mode: SelectionMode
    var currentMode: SelectionMode { mode }
    private let allowSwitch: Bool
    private let onResult: (SelectionResult) -> Void

    private let fixedSize: CGSize? = Prefs.fixedSize
    private let aspect: CGFloat? = Prefs.aspectRatio

    private var mouse: CGPoint = .zero
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hoverWindow: WindowTarget?
    private var shiftDown = false

    init(
        screen: NSScreen,
        frozen: CGImage,
        targets: [WindowTarget],
        mode: SelectionMode,
        allowSwitch: Bool,
        onResult: @escaping (SelectionResult) -> Void
    ) {
        self.screen = screen
        self.frozen = frozen
        self.targets = targets
        self.mode = mode
        self.allowSwitch = allowSwitch
        self.onResult = onResult
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        buildModeBar()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var hasMouse = false
    private var pixelScale: CGFloat { CGFloat(frozen.width) / max(bounds.width, 1) }

    /// Called after you switch desktops: show the new desktop instead of the old picture.
    /// `quiet` refreshes keep whatever you are doing (a box you are dragging) and only swap the picture.
    func reload(frozen: CGImage, targets: [WindowTarget], quiet: Bool = false) {
        if quiet && dragStart != nil { return }
        self.frozen = frozen
        self.targets = targets
        if !quiet {
            selection = nil
            dragStart = nil
        }
        let p = window.map { $0.mouseLocationOutsideOfEventStream } ?? .zero
        mouse = convert(p, from: nil)
        hasMouse = bounds.contains(mouse)
        updateHover()
        needsDisplay = true
    }

    // MARK: Mode bar (glass)

    private var modePills: [SelectionMode: NSView] = [:]

    /// Lets clicks pass through to the selection view underneath.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private func pill(key: String, title: String) -> NSView {
        let cap = glassLabel(key, size: 11, weight: .bold, color: .labelColor)
        cap.alignment = .center
        let capBox = NSView()
        capBox.wantsLayer = true
        capBox.layer?.cornerRadius = 5
        capBox.layer?.borderWidth = 1
        capBox.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.35).cgColor
        capBox.translatesAutoresizingMaskIntoConstraints = false
        cap.translatesAutoresizingMaskIntoConstraints = false
        capBox.addSubview(cap)
        NSLayoutConstraint.activate([
            // Single letters keep a square box; longer text like "esc" makes the box wider so it never touches the border.
            capBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            capBox.heightAnchor.constraint(equalToConstant: 20),
            cap.leadingAnchor.constraint(equalTo: capBox.leadingAnchor, constant: 6),
            cap.trailingAnchor.constraint(equalTo: capBox.trailingAnchor, constant: -6),
            cap.centerXAnchor.constraint(equalTo: capBox.centerXAnchor),
            cap.centerYAnchor.constraint(equalTo: capBox.centerYAnchor),
        ])
        let label = glassLabel(title, size: 13, weight: .semibold)
        let row = NSStackView(views: [capBox, label])
        row.spacing = 7
        row.alignment = .centerY
        let holder = NSView()
        holder.wantsLayer = true
        holder.layer?.cornerRadius = 17
        holder.layer?.cornerCurve = .continuous
        row.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: holder.topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -7),
        ])
        return holder
    }

    private func buildModeBar() {
        var items: [NSView] = []
        if allowSwitch {
            let area = pill(key: "A", title: "Area")
            let window = pill(key: "W", title: "Window")
            let full = pill(key: "F", title: "Fullscreen")
            modePills = [.area: area, .window: window]
            items = [area, window, full]
        }
        let esc = pill(key: "esc", title: "Cancel")
        items.append(esc)
        let stack = NSStackView(views: items)
        stack.spacing = 2
        stack.alignment = .centerY
        let surface = Glass.surface(stack, cornerRadius: 22, insets: NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6))
        surface.translatesAutoresizingMaskIntoConstraints = false

        let holder = PassthroughView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(surface)
        addSubview(holder)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            surface.topAnchor.constraint(equalTo: holder.topAnchor),
            surface.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            holder.centerXAnchor.constraint(equalTo: centerXAnchor),
            holder.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -44),
        ])
        refreshModeBar()
    }

    private func refreshModeBar() {
        for (m, view) in modePills {
            view.layer?.backgroundColor = (m == mode) ? NSColor.labelColor.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        }
    }

    // MARK: Tracking and cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.pointer)
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.pointer.set()
    }

    /// Cursor rects only apply once the pointer moves, so a quick second capture can keep the old cursor.
    func applyCursor() {
        window?.invalidateCursorRects(for: self)
        Self.pointer.set()
    }

    /// A small translucent ring instead of the system crosshair.
    private static let pointer: NSCursor = {
        let size: CGFloat = 26
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let dot = rect.insetBy(dx: 3, dy: 3)
            NSColor.white.withAlphaComponent(0.3).setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let outer = NSBezierPath(ovalIn: dot.insetBy(dx: -0.5, dy: -0.5))
            outer.lineWidth = 1
            outer.stroke()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        let p = window.map { $0.mouseLocationOutsideOfEventStream } ?? .zero
        mouse = convert(p, from: nil)
        hasMouse = bounds.contains(mouse)
        updateHover()
    }

    // MARK: Selection geometry

    private func clampPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    /// Box with the fixed size centered on the pointer, kept inside the screen.
    private func fixedBox(at p: CGPoint, size: CGSize) -> CGRect {
        var r = CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
        r.origin.x = min(max(r.origin.x, 0), max(0, bounds.width - r.width))
        r.origin.y = min(max(r.origin.y, 0), max(0, bounds.height - r.height))
        return r.intersection(bounds)
    }

    private func dragRect(from a: CGPoint, to rawB: CGPoint) -> CGRect {
        var b = clampPoint(rawB)
        var ratio = aspect
        if shiftDown { ratio = 1 }
        if let ratio {
            var dx = b.x - a.x
            var dy = b.y - a.y
            if abs(dx) / ratio > abs(dy) { dy = (dy < 0 ? -1 : 1) * abs(dx) / ratio } else { dx = (dx < 0 ? -1 : 1) * abs(dy) * ratio }
            // Shrink so the box stays on the screen.
            let maxX = dx < 0 ? a.x : bounds.width - a.x
            let maxY = dy < 0 ? a.y : bounds.height - a.y
            let k = min(1, maxX / max(abs(dx), 0.001), maxY / max(abs(dy), 0.001))
            b = CGPoint(x: a.x + dx * k, y: a.y + dy * k)
        }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func updateHover() {
        hoverWindow = (mode == .window) ? targets.first { $0.rect.contains(mouse) } : nil
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        hasMouse = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hasMouse = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        hasMouse = true
        Self.pointer.set()
        shiftDown = event.modifierFlags.contains(.shift)
        if mode == .area, let fixed = fixedSize {
            selection = fixedBox(at: mouse, size: fixed)
        }
        updateHover()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        shiftDown = event.modifierFlags.contains(.shift)
        switch mode {
        case .window:
            if let target = hoverWindow { onResult(.window(target.window)) }
        case .area:
            if let fixed = fixedSize {
                let box = fixedBox(at: mouse, size: fixed)
                onResult(.area(screen: screen, rect: box, frozen: frozen))
            } else {
                dragStart = clampPoint(mouse)
                selection = nil
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        shiftDown = event.modifierFlags.contains(.shift)
        if mode == .area, fixedSize == nil, let start = dragStart {
            selection = dragRect(from: start, to: mouse)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        guard mode == .area, fixedSize == nil, dragStart != nil else { return }
        dragStart = nil
        if let box = selection, box.width >= 3, box.height >= 3 {
            onResult(.area(screen: screen, rect: box, frozen: frozen))
        } else {
            selection = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onResult(.cancelled)
    }

    override func flagsChanged(with event: NSEvent) {
        shiftDown = event.modifierFlags.contains(.shift)
        if let start = dragStart { selection = dragRect(from: start, to: mouse) }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onResult(.cancelled)
            return
        }
        guard allowSwitch else { return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a":
            mode = .area
            hoverWindow = nil
            refreshModeBar()
            needsDisplay = true
        case "w":
            mode = .window
            selection = nil
            dragStart = nil
            updateHover()
            refreshModeBar()
            needsDisplay = true
        case "f":
            onResult(.fullscreen(screen: screen, frozen: frozen))
        default:
            break
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(frozen, in: bounds)

        // Dim everything, then bring the chosen part back to full brightness.
        let highlight: CGRect? = (mode == .window) ? hoverWindow?.rect : selection
        NSColor.black.withAlphaComponent(0.4).setFill()
        let dim = NSBezierPath(rect: bounds)
        if let h = highlight { dim.append(NSBezierPath(rect: h)) }
        dim.windingRule = .evenOdd
        dim.fill()

        if let h = highlight {
            if mode == .window {
                NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
                NSBezierPath(rect: h).fill()
            }
            let border = NSBezierPath(rect: h.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1.5
            (mode == .window ? NSColor.controlAccentColor : NSColor.white).setStroke()
            border.stroke()
            drawLabel("\(Int(h.width.rounded())) × \(Int(h.height.rounded()))", near: CGPoint(x: h.minX, y: h.maxY + 6))
        }

        if hasMouse && mode == .area { drawMagnifier() }
    }

    private func drawMagnifier() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size: CGFloat = 128
        // Show a fixed 44 pt wide patch of the screen (about 3x), whatever the display density.
        let zoomPixels = Int((44 * pixelScale).rounded()) | 1
        var box = CGRect(x: mouse.x + 22, y: mouse.y - size - 22, width: size, height: size)
        if box.maxX > bounds.width - 8 { box.origin.x = mouse.x - 22 - size }
        if box.minY < 8 { box.origin.y = mouse.y + 22 }
        let px = Int((mouse.x * pixelScale).rounded())
        let py = Int(((bounds.height - mouse.y) * pixelScale).rounded())
        let half = zoomPixels / 2
        let desired = CGRect(x: px - half, y: py - half, width: zoomPixels, height: zoomPixels)
        let src = desired.intersection(CGRect(x: 0, y: 0, width: frozen.width, height: frozen.height))
        // Near a screen edge only part of the patch exists; draw that part where it belongs instead of stretching it.
        let cellSize = size / CGFloat(zoomPixels)
        let drawRect = CGRect(
            x: box.minX + (src.minX - desired.minX) * cellSize,
            y: box.maxY - (src.minY - desired.minY) * cellSize - src.height * cellSize,
            width: src.width * cellSize,
            height: src.height * cellSize
        )
        if let crop = frozen.cropping(to: src) {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 12, color: CGColor(gray: 0, alpha: 0.45))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillEllipse(in: box)
            ctx.restoreGState()
            ctx.saveGState()
            NSBezierPath(ovalIn: box).addClip()
            ctx.interpolationQuality = .high
            ctx.draw(crop, in: drawRect)
            ctx.restoreGState()
        }
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let frame = NSBezierPath(ovalIn: box.insetBy(dx: 1.5, dy: 1.5))
        frame.lineWidth = 3
        frame.stroke()
        // Center marker: a small translucent dot
        let dot = CGRect(x: box.midX - 5, y: box.midY - 5, width: 10, height: 10)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }

    private static func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    private func drawLabel(_ text: String, near origin: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.roundedFont(12, .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        var rect = CGRect(x: origin.x, y: origin.y, width: size.width + 18, height: size.height + 8)
        rect.origin.x = min(max(rect.origin.x, 4), bounds.width - rect.width - 4)
        rect.origin.y = min(max(rect.origin.y, 4), bounds.height - rect.height - 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
        edge.lineWidth = 1
        edge.stroke()
        str.draw(at: CGPoint(x: rect.minX + 9, y: rect.minY + 4))
    }
}
