import AppKit
import UniformTypeIdentifiers

// MARK: Canvas

final class EditorCanvas: NSView, NSTextFieldDelegate {
    private let unit: CGFloat
    private let history = UndoManager()

    private(set) var state: EditState {
        didSet {
            needsDisplay = true
            if manualScale != nil { clampPan() }
            onStateChange?()
        }
    }
    var style: DocStyle {
        didSet { needsDisplay = true }
    }
    var onStateChange: (() -> Void)?
    var onZoomChange: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?

    var tool: EditorTool = .arrow {
        didSet {
            finishText()
            selectedID = nil
            window?.invalidateCursorRects(for: self)
        }
    }
    var currentColor: NSColor = .systemRed
    /// Yellow is the highlighter's color until the user picks something else.
    var highlighterColor: NSColor { currentColor == .systemRed ? .systemYellow : currentColor }
    var sizeIndex = 1
    /// width / height, nil = free crop
    var cropAspect: CGFloat?
    /// Space reserved for the title bar and the floating toolbar; the picture is centered in what is left.
    var contentInsets = NSEdgeInsets(top: 56, left: 24, bottom: 130, right: 24) {
        didSet { needsDisplay = true; onZoomChange?() }
    }
    /// View points per image point, nil = fit the window.
    private var manualScale: CGFloat? { didSet { needsDisplay = true; onZoomChange?() } }
    private var pan: CGPoint = .zero { didSet { needsDisplay = true } }
    static let zoomSteps: [CGFloat] = [10, 25, 33, 50, 67, 75, 100, 150, 200, 300, 400]

    private var draft: Annotation? { didSet { needsDisplay = true } }
    private var cropDraft: CGRect? { didSet { needsDisplay = true } }
    private var selectedID: UUID? { didSet { needsDisplay = true } }

    private var dragSnapshot: [Annotation] = []
    private var lastDragPoint: CGPoint = .zero
    private var dragMoved = false
    private var cropAnchor: CGPoint = .zero

    private var editingField: NSTextField?
    private var editingOrigin: CGPoint = .zero

    private var lineWidth: CGFloat { [2.0, 4.0, 7.0][min(max(sizeIndex, 0), 2)] * unit }
    private var fontSize: CGFloat { [16.0, 24.0, 36.0][min(max(sizeIndex, 0), 2)] * unit }

    var annotations: [Annotation] { state.annotations }
    var base: CGImage { state.base }
    var hasChanges: Bool { history.canUndo }

    init(image: CGImage, unit: CGFloat, style: DocStyle) {
        self.unit = unit
        self.state = EditState(base: image)
        self.style = style
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { history }

    // MARK: Geometry

    private var pad: CGFloat { style.effectivePadding }
    private var docSize: CGSize { DocRenderer.size(of: state, style: style) }

    private var area: CGRect {
        CGRect(x: contentInsets.left, y: contentInsets.top,
               width: max(1, bounds.width - contentInsets.left - contentInsets.right),
               height: max(1, bounds.height - contentInsets.top - contentInsets.bottom))
    }

    /// The scale that shows the whole picture, never bigger than 100%.
    private var fitScale: CGFloat {
        let d = docSize
        let a = area
        return max(0.01, min(a.width / d.width, a.height / d.height, 1 / unit))
    }

    private var viewScale: CGFloat { manualScale ?? fitScale }

    /// The zoom as a percentage, where 100 means one image point per screen point.
    var zoomPercent: Int { Int((viewScale * unit * 100).rounded()) }

    func zoomIn() { stepZoom(up: true) }
    func zoomOut() { stepZoom(up: false) }

    private func stepZoom(up: Bool) {
        let current = viewScale * unit * 100
        let steps = Self.zoomSteps
        let next = up ? steps.first(where: { $0 > current + 0.5 }) : steps.last(where: { $0 < current - 0.5 })
        setZoom(percent: next ?? (up ? steps.last! : steps.first!))
    }

    private func setZoom(percent: CGFloat) {
        finishText()
        let old = docRect
        let anchor = CGPoint(x: area.midX, y: area.midY)
        // Keep the picture point under the middle of the window where it is.
        let u = CGPoint(x: (anchor.x - old.minX) / old.width, y: (anchor.y - old.minY) / old.height)
        manualScale = percent / 100 / unit
        let r = docRect
        pan.x += anchor.x - (r.minX + u.x * r.width)
        pan.y += anchor.y - (r.minY + u.y * r.height)
        clampPan()
    }

    func zoomToFit() {
        manualScale = nil
        pan = .zero
    }

    private func clampPan() {
        let d = docSize
        let s = viewScale
        let a = area
        let limitX = (d.width * s + a.width) / 2 - 40
        let limitY = (d.height * s + a.height) / 2 - 40
        pan = CGPoint(x: min(max(-limitX, pan.x), limitX), y: min(max(-limitY, pan.y), limitY))
    }

    private var docRect: CGRect {
        let d = docSize
        let s = viewScale
        let a = area
        return CGRect(x: a.midX - d.width * s / 2 + pan.x, y: a.midY - d.height * s / 2 + pan.y, width: d.width * s, height: d.height * s)
    }

    override func scrollWheel(with event: NSEvent) {
        guard manualScale != nil else { return }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        pan.x += event.scrollingDeltaX * k
        pan.y += event.scrollingDeltaY * k
        clampPan()
    }

    override func magnify(with event: NSEvent) {
        let percent = viewScale * unit * 100 * (1 + event.magnification)
        setZoom(percent: min(max(percent, 10), 400))
    }

    override func layout() {
        super.layout()
        onZoomChange?()
    }

    /// View point -> image pixel (top-left origin, inside the screenshot itself).
    private func toImage(_ p: CGPoint) -> CGPoint {
        let r = docRect
        let s = viewScale
        return CGPoint(x: (p.x - r.minX) / s - pad, y: (p.y - r.minY) / s - pad)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        let r = docRect
        let s = viewScale
        return CGPoint(x: r.minX + (p.x + pad) * s, y: r.minY + (p.y + pad) * s)
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), CGFloat(state.base.width)), y: min(max(0, p.y), CGFloat(state.base.height)))
    }

    // MARK: State changes (all undoable)

    func setState(_ new: EditState, actionName: String) {
        let old = state
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.setState(old, actionName: actionName)
            }
        }
        history.setActionName(actionName)
        state = new
        if let id = selectedID, !new.annotations.contains(where: { $0.id == id }) {
            selectedID = nil
        }
    }

    private func setAnnotations(_ new: [Annotation], actionName: String) {
        var s = state
        s.annotations = new
        setState(s, actionName: actionName)
    }

    func undo() { history.undo() }
    func redo() { history.redo() }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func colorChanged(_ color: NSColor) {
        currentColor = color
        if let id = selectedID,
           let i = state.annotations.firstIndex(where: { $0.id == id }),
           ![.redact, .blur, .pixelate, .spotlight].contains(state.annotations[i].kind) {
            var copy = state.annotations
            copy[i].color = color
            setAnnotations(copy, actionName: "Change Color")
        }
    }

    // MARK: Pixel operations

    private func applyToBase(_ name: String, _ op: (CGImage) -> CGImage?) {
        finishText()
        let flat = DocRenderer.flatten(state)
        guard let out = op(flat) else { return }
        setState(EditState(base: out), actionName: name)
    }

    /// Makes everything but the main subject transparent. Returns false when no subject is found.
    @discardableResult
    func removeBackground() -> Bool {
        finishText()
        guard let out = ImageOps.removeBackground(state.base) else { return false }
        var s = state
        s.base = out
        setState(s, actionName: "Remove Background")
        return true
    }

    func rotateRight() { applyToBase("Rotate") { ImageOps.rotateRight($0) } }
    func rotateLeft() { applyToBase("Rotate") { ImageOps.rotateLeft($0) } }
    func flipHorizontal() { applyToBase("Flip") { ImageOps.flipHorizontal($0) } }
    func flipVertical() { applyToBase("Flip") { ImageOps.flipVertical($0) } }

    func resize(scale: CGFloat) {
        applyToBase("Resize") { ImageOps.resized($0, width: max(1, Int((CGFloat($0.width) * scale).rounded())), height: max(1, Int((CGFloat($0.height) * scale).rounded()))) }
    }

    func resize(toWidth width: Int) {
        applyToBase("Resize") {
            let s = CGFloat(width) / CGFloat($0.width)
            return ImageOps.resized($0, width: max(1, width), height: max(1, Int((CGFloat($0.height) * s).rounded())))
        }
    }

    func combine(with other: CGImage, below: Bool) {
        applyToBase("Combine") { ImageOps.combined($0, with: other, below: below) }
    }

    func crop(to rect: CGRect) {
        applyToBase("Crop") { img in
            let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
            guard r.width >= 2, r.height >= 2 else { return nil }
            return img.cropping(to: r)
        }
    }

    /// The final image: background, screenshot and all annotations. Redaction boxes are opaque.
    func renderFinal() -> CGImage? {
        finishText()
        return DocRenderer.render(state: state, style: style)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let r = docRect
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: viewScale, y: viewScale)

        var live = state
        if let d = draft { live.annotations.append(d) }
        DocRenderer.draw(state: live, style: style, ctx: ctx)

        ctx.translateBy(x: pad, y: pad)
        if let id = selectedID, let a = state.annotations.first(where: { $0.id == id }) {
            let outline = NSBezierPath(rect: a.bounds.insetBy(dx: -4 * unit, dy: -4 * unit))
            outline.lineWidth = 1.5 * unit
            outline.setLineDash([6 * unit, 4 * unit], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
        }
        if let c = cropDraft {
            let full = CGRect(x: 0, y: 0, width: CGFloat(state.base.width), height: CGFloat(state.base.height))
            let dim = NSBezierPath(rect: full)
            dim.append(NSBezierPath(rect: c))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            dim.fill()
            let box = NSBezierPath(rect: c)
            box.lineWidth = 1.5 * unit
            NSColor.white.setStroke()
            box.stroke()
        }
        ctx.restoreGState()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .select || tool == .eraser ? .arrow : .crosshair)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self) // also commits any text being typed
        let p = toImage(convert(event.locationInWindow, from: nil))

        switch tool {
        case .select:
            selectedID = state.annotations.last(where: { $0.hit(p, tolerance: 10 * unit) })?.id
            dragSnapshot = state.annotations
            lastDragPoint = p
            dragMoved = false
        case .eraser:
            dragSnapshot = state.annotations
            dragMoved = false
            erase(at: p)
        case .text:
            beginText(at: clamped(p))
        case .counter:
            let q = clamped(p)
            var a = Annotation(kind: .counter, start: q, end: q, color: currentColor, lineWidth: lineWidth)
            a.fontSize = fontSize
            a.number = state.annotations.filter { $0.kind == .counter }.count + 1
            setAnnotations(state.annotations + [a], actionName: "Add Counter")
        case .crop:
            cropAnchor = clamped(p)
            cropDraft = CGRect(origin: cropAnchor, size: .zero)
        default:
            guard let kind = tool.kind else { return }
            let q = clamped(p)
            var color = currentColor
            if kind == .redact { color = .black }
            if kind == .highlighter { color = highlighterColor }
            var a = Annotation(kind: kind, start: q, end: q, color: color, lineWidth: lineWidth)
            if kind == .freehand || kind == .highlighter { a.points = [q] }
            draft = a
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        switch tool {
        case .select:
            guard let id = selectedID, let i = state.annotations.firstIndex(where: { $0.id == id }) else { return }
            var s = state
            s.annotations[i].move(dx: p.x - lastDragPoint.x, dy: p.y - lastDragPoint.y)
            state = s
            lastDragPoint = p
            dragMoved = true
        case .crop:
            cropDraft = constrainedCrop(to: clamped(p))
        case .eraser:
            erase(at: p)
        case .text, .counter:
            break
        default:
            guard draft != nil else { return }
            var q = clamped(p)
            if event.modifierFlags.contains(.shift), let d = draft, d.kind != .freehand, d.kind != .highlighter {
                // Shift keeps lines at 45-degree steps and boxes square.
                let dx = q.x - d.start.x, dy = q.y - d.start.y
                if d.kind == .arrow || d.kind == .line {
                    let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
                    let len = hypot(dx, dy)
                    q = CGPoint(x: d.start.x + cos(angle) * len, y: d.start.y + sin(angle) * len)
                } else {
                    let side = max(abs(dx), abs(dy))
                    q = CGPoint(x: d.start.x + (dx < 0 ? -side : side), y: d.start.y + (dy < 0 ? -side : side))
                }
            }
            draft?.end = q
            if draft?.kind == .freehand || draft?.kind == .highlighter { draft?.points.append(q) }
        }
    }

    /// Removes the top annotation under the pointer. A whole stroke of the eraser is one undo step.
    func erase(at p: CGPoint) {
        guard let i = state.annotations.lastIndex(where: { $0.hit(p, tolerance: 8 * unit) }) else { return }
        var s = state
        s.annotations.remove(at: i)
        state = s
        dragMoved = true
    }

    private func constrainedCrop(to p: CGPoint) -> CGRect {
        var dx = p.x - cropAnchor.x
        var dy = p.y - cropAnchor.y
        if let ratio = cropAspect {
            if abs(dx) / ratio > abs(dy) { dy = (dy < 0 ? -1 : 1) * abs(dx) / ratio } else { dx = (dx < 0 ? -1 : 1) * abs(dy) * ratio }
            // Keep inside the image.
            let maxX = dx < 0 ? cropAnchor.x : CGFloat(state.base.width) - cropAnchor.x
            let maxY = dy < 0 ? cropAnchor.y : CGFloat(state.base.height) - cropAnchor.y
            let scale = min(1, maxX / max(abs(dx), 1), maxY / max(abs(dy), 1))
            dx *= scale; dy *= scale
        }
        return CGRect(x: min(cropAnchor.x, cropAnchor.x + dx), y: min(cropAnchor.y, cropAnchor.y + dy), width: abs(dx), height: abs(dy))
    }

    override func mouseUp(with event: NSEvent) {
        switch tool {
        case .select, .eraser:
            if dragMoved {
                // Put the old state back, then apply the change as one undoable step.
                let changed = state.annotations
                var s = state
                s.annotations = dragSnapshot
                state = s
                setAnnotations(changed, actionName: tool == .eraser ? "Erase" : "Move")
            }
            dragMoved = false
        case .crop:
            if let c = cropDraft, c.width >= 8, c.height >= 8 { crop(to: c) }
            cropDraft = nil
        case .text, .counter:
            break
        default:
            guard let d = draft else { return }
            draft = nil
            let size = max(abs(d.end.x - d.start.x), abs(d.end.y - d.start.y))
            let isStroke = d.kind == .freehand || d.kind == .highlighter
            if size >= 6 || (isStroke && d.points.count > 2) {
                setAnnotations(state.annotations + [d], actionName: "Add")
            }
        }
    }

    // MARK: Text

    private func beginText(at imagePoint: CGPoint) {
        finishText()
        editingOrigin = imagePoint
        let vp = toView(imagePoint)
        let size = fontSize * viewScale
        let field = NSTextField(frame: NSRect(x: vp.x - 2, y: vp.y - 3, width: 300, height: size + 10))
        field.font = .systemFont(ofSize: size, weight: .semibold)
        field.textColor = currentColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Type, then press Return"
        field.delegate = self
        addSubview(field)
        editingField = field
        window?.makeFirstResponder(field)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishText()
    }

    func finishText() {
        guard let field = editingField else { return }
        editingField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if !text.isEmpty {
            var a = Annotation(kind: .text, start: editingOrigin, end: editingOrigin, color: currentColor, lineWidth: lineWidth)
            a.fontSize = fontSize
            a.text = text
            setAnnotations(state.annotations + [a], actionName: "Add Text")
        }
        window?.makeFirstResponder(self)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            if let id = selectedID {
                setAnnotations(state.annotations.filter { $0.id != id }, actionName: "Delete")
            }
        case 53: // Esc
            selectedID = nil
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder is NSTextView { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z":
            if flags.contains(.shift) { history.redo() } else { history.undo() }
            return true
        case "c":
            onCopy?()
            return true
        case "s":
            onSave?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// Lets the Edit menu's Copy reach the editor too.
    @objc func copy(_ sender: Any?) {
        onCopy?()
    }
}

// MARK: Small controls

/// Drag this onto Finder, Mail, a chat, etc. to export the edited image as a file.
private final class DragExportView: NSView, NSDraggingSource {
    var provider: (() -> CGImage?)?
    private var mouseDownPoint: NSPoint = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "square.and.arrow.up.on.square", accessibilityDescription: "Drag to export") ?? NSImage())
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "Drag")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 88),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        toolTip = "Drag the edited image into Finder, Mail, Slack, a browser…"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(convert(point, to: superview)) ? self : nil }
    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard hypot(event.locationInWindow.x - mouseDownPoint.x, event.locationInWindow.y - mouseDownPoint.y) > 4 else { return }
        mouseDownPoint = NSPoint(x: CGFloat.infinity, y: CGFloat.infinity)
        guard let image = provider?() else { return }
        let format = Prefs.imageFormat
        guard let data = format.encode(image, quality: Prefs.jpegQuality) else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Tack Drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = FileSaver.uniqueURL(in: folder, name: FileSaver.filename(ext: format.fileExtension))
        guard (try? data.write(to: url)) != nil else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let thumb = NSImage(cgImage: image, size: NSSize(width: 120, height: 120 * CGFloat(image.height) / CGFloat(image.width)))
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: thumb.size.width, height: thumb.size.height), contents: thumb)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

// MARK: Toolbar pieces

/// A value that chases a target like a spring, the way Markup's controls settle: quick start, a little overshoot, then rest.
@MainActor
private final class Spring {
    var value: CGFloat
    var target: CGFloat
    private var velocity: CGFloat = 0
    private let omega: CGFloat
    private let damping: CGFloat

    /// `response` is the time of one natural oscillation in seconds; `dampingRatio` below 1 overshoots a little.
    init(value: CGFloat, response: CGFloat, dampingRatio: CGFloat) {
        self.value = value
        target = value
        omega = 2 * .pi / response
        damping = dampingRatio
    }

    var isSettled: Bool { abs(value - target) < 0.002 && abs(velocity) < 0.01 }

    func snap(to v: CGFloat) { value = v; target = v; velocity = 0 }

    func step(_ dt: CGFloat) {
        // Semi-implicit Euler in small slices stays stable at any frame rate.
        let slices = max(1, Int((dt / 0.004).rounded(.up)))
        let h = dt / CGFloat(slices)
        for _ in 0..<slices {
            let accel = -omega * omega * (value - target) - 2 * damping * omega * velocity
            velocity += accel * h
            value += velocity * h
        }
        if isSettled { value = target; velocity = 0 }
    }
}

/// Drives a `Spring` from the display's refresh until it settles.
@MainActor
private final class SpringDriver: NSObject {
    private weak var view: NSView?
    private let spring: Spring
    private var link: CADisplayLink?

    init(view: NSView, spring: Spring) {
        self.view = view
        self.spring = spring
    }

    func start() {
        guard link == nil, let view else { return }
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let dt = CGFloat(min(max(l.targetTimestamp - l.timestamp, 1.0 / 240), 1.0 / 20))
        spring.step(dt)
        view?.needsDisplay = true
        if spring.isSettled {
            l.invalidate()
            link = nil
        }
    }

    deinit { MainActor.assumeIsolated { link?.invalidate() } }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A round color dot. The selected one gets a thin ring around it.
private final class ColorDot: NSControl {
    var dotColor: NSColor?   // nil draws the color wheel
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            select.target = isOn ? 1 : 0
            if window?.isVisible != true { select.snap(to: select.target); needsDisplay = true } else { driver.start() }
        }
    }
    /// 0 = unselected, 1 = selected. The ring grows in around the dot as the dot settles inward.
    private let select = Spring(value: 0, response: 0.28, dampingRatio: 0.72)
    private lazy var driver = SpringDriver(view: self, spring: select)

    init(color: NSColor?, target: AnyObject?, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        dotColor = color
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }

    override func draw(_ dirtyRect: NSRect) {
        let t = select.value
        let dot = bounds.insetBy(dx: 1 + 3 * t, dy: 1 + 3 * t)
        if t > 0.01 {
            // The ring starts a little smaller than its final size and fades in as it expands.
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1 + 3 * (1 - min(t, 1)), dy: 1 + 3 * (1 - min(t, 1))))
            ring.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.9 * min(max(t, 0), 1)).setStroke()
            ring.stroke()
        }
        if let c = dotColor {
            c.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return
        }
        // Color wheel: hue around, fading to white in the middle.
        let center = NSPoint(x: dot.midX, y: dot.midY)
        let r = dot.width / 2
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: dot).addClip()
        let slices = 90
        for i in 0..<slices {
            let wedge = NSBezierPath()
            wedge.move(to: center)
            wedge.appendArc(withCenter: center, radius: r + 1, startAngle: CGFloat(i) * 360 / CGFloat(slices) - 0.5, endAngle: CGFloat(i + 1) * 360 / CGFloat(slices) + 0.5)
            wedge.close()
            NSColor(hue: CGFloat(i) / CGFloat(slices), saturation: 0.75, brightness: 1, alpha: 1).setFill()
            wedge.fill()
        }
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.95), NSColor.white.withAlphaComponent(0)])?
            .draw(in: NSBezierPath(ovalIn: dot), relativeCenterPosition: .zero)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A pen, marker or eraser standing in the toolbar, tip up. The chosen one is raised; the pill clips the bottoms.
private final class MarkupToolView: NSControl {
    enum Kind { case pen, marker, eraser }
    let kind: Kind
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            raise.target = isOn ? 1 : 0
            if window?.isVisible != true { raise.snap(to: raise.target); needsDisplay = true } else { driver.start() }
        }
    }
    /// 0 = resting in the tray, 1 = raised. A spring, so the chosen tool pops up with a slight overshoot and the old one drops back.
    private let raise = Spring(value: 0, response: 0.34, dampingRatio: 0.68)
    private lazy var driver = SpringDriver(view: self, spring: raise)
    /// The tip shows the color the tool will draw with.
    var tipColor: NSColor = .black { didSet { needsDisplay = true } }

    init(kind: Kind, target: AnyObject?, action: Selector) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 85))
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }

    private func fill(_ rect: NSRect, radius: CGFloat, _ top: NSColor, _ bottom: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let top: CGFloat = 29 - 14 * raise.value
        let h = bounds.height
        switch kind {
        case .pen:
            let tip = NSBezierPath()
            tip.move(to: NSPoint(x: w / 2, y: top))
            tip.line(to: NSPoint(x: w / 2 + 7, y: top + 24))
            tip.line(to: NSPoint(x: w / 2 - 7, y: top + 24))
            tip.close()
            tipColor.setFill()
            tip.fill()
            NSColor.white.withAlphaComponent(0.25).setStroke()
            tip.lineWidth = 0.5
            tip.stroke()
            fill(NSRect(x: w / 2 - 9, y: top + 22, width: 18, height: h), radius: 4, NSColor(white: 0.30, alpha: 1), NSColor(white: 0.05, alpha: 1))
        case .marker:
            fill(NSRect(x: w / 2 - 4, y: top, width: 8, height: 14), radius: 2, tipColor, tipColor.blended(withFraction: 0.2, of: .black) ?? tipColor)
            fill(NSRect(x: w / 2 - 9, y: top + 12, width: 18, height: 12), radius: 3, NSColor(white: 0.28, alpha: 1), NSColor(white: 0.08, alpha: 1))
            fill(NSRect(x: w / 2 - 9, y: top + 24, width: 18, height: h), radius: 3, NSColor(red: 1, green: 0.85, blue: 0.2, alpha: 1), NSColor(red: 0.95, green: 0.72, blue: 0.1, alpha: 1))
            fill(NSRect(x: w / 2 - 9, y: top + 40, width: 18, height: h), radius: 3, NSColor(white: 0.22, alpha: 1), NSColor(white: 0.06, alpha: 1))
        case .eraser:
            fill(NSRect(x: w / 2 - 9, y: top, width: 18, height: 22), radius: 6, NSColor(red: 0.98, green: 0.62, blue: 0.62, alpha: 1), NSColor(red: 0.93, green: 0.45, blue: 0.47, alpha: 1))
            fill(NSRect(x: w / 2 - 9, y: top + 18, width: 18, height: h), radius: 3, NSColor(white: 0.30, alpha: 1), NSColor(white: 0.08, alpha: 1))
        }
    }
}

// MARK: Window

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let window: NSWindow
    private let canvas: EditorCanvas
    private var finished = false
    /// Pixel density of the display the picture came from.
    private var scaleUnit: CGFloat = 2
    /// Set when the image came from a file on disk. That file is never touched by the editor.
    private let sourceURL: URL?

    private var pill: NSView!
    private var penTool: MarkupToolView!
    private var markerTool: MarkupToolView!
    private var eraserTool: MarkupToolView!
    private var dots: [ColorDot] = []
    private var wheelDot: ColorDot!
    private var undoButton: PillButton!
    private var redoButton: PillButton!
    private var moreButton: PillButton!
    private var currentTool: EditorTool = .freehand

    private static let pillSize = NSSize(width: 380, height: 85)
    private static let presetColors: [NSColor] = [.black, .systemBlue, .systemGreen, .systemYellow, .systemRed]

    private enum ItemID {
        static let title = NSToolbarItem.Identifier("title")
        static let zoom = NSToolbarItem.Identifier("zoom")
        static let done = NSToolbarItem.Identifier("done")
    }

    init(image: CGImage, source: URL? = nil, scale: CGFloat? = nil) {
        sourceURL = source
        let screen = CaptureService.screenUnderMouse()
        let unit = scale ?? screen.backingScaleFactor
        scaleUnit = unit
        let d = UserDefaults.standard
        var style = DocStyle()
        style.unit = unit
        style.backdrop = Backdrop(rawValue: d.string(forKey: PrefKey.annBackground) ?? "none") ?? .none
        style.padding = CGFloat(d.integer(forKey: PrefKey.annPadding)) * unit
        style.rounded = d.bool(forKey: PrefKey.annRounded)
        style.shadow = d.bool(forKey: PrefKey.annShadow)
        canvas = EditorCanvas(image: image, unit: unit, style: style)
        canvas.sizeIndex = d.integer(forKey: PrefKey.annSize)

        let visible = screen.visibleFrame
        let natural = NSSize(width: CGFloat(image.width) / unit, height: CGFloat(image.height) / unit)
        let chrome: CGFloat = 52 + 104
        let fit = min((visible.width * 0.85 - 48) / natural.width, (visible.height * 0.85 - chrome - 24) / natural.height, 1)
        let content = NSSize(
            width: max(720, natural.width * fit + 48),
            height: max(480, natural.height * fit + chrome + 24)
        )
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: content),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        build()
        window.setContentSize(content)
    }

    // MARK: Building the window

    private func build() {
        window.title = sourceURL?.lastPathComponent ?? "Edit Screenshot"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 720, height: 480)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear

        let toolbar = NSToolbar(identifier: "TackEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // The window is a dark, see-through sheet, like Markup.
        let root = NSVisualEffectView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.contentInsets = NSEdgeInsets(top: 52, left: 24, bottom: 104, right: 24)
        canvas.onCopy = { [weak self] in self?.copyTapped() }
        canvas.onSave = { [weak self] in self?.saveTapped() }
        canvas.onStateChange = { [weak self] in self?.updateUndoButtons() }
        root.addSubview(canvas)

        pill = makePill()
        pill.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pill)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pill.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            // Without a floor the window collapses to the width of what its constraints require.
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 720),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])
        window.contentView = root

        selectTool(.freehand)
        updateUndoButtons()
        updateSwatches()
    }

    /// The floating glass pill: undo, redo, pen, marker, eraser, colors and the "…" menu.
    private func makePill() -> NSView {
        let size = Self.pillSize
        let content = FlippedView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.cornerRadius = size.height / 2
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        content.heightAnchor.constraint(equalToConstant: size.height).isActive = true

        func place(_ v: NSView, centerX: CGFloat, centerY: CGFloat) {
            v.translatesAutoresizingMaskIntoConstraints = true
            v.frame = NSRect(x: centerX - v.frame.width / 2, y: centerY - v.frame.height / 2, width: v.frame.width, height: v.frame.height)
            content.addSubview(v)
        }

        func round(_ symbol: String, tip: String, action: Selector) -> PillButton {
            let b = Glass.iconButton(symbol, tip: tip, target: self, action: action)
            b.controlSize = .small
            b.frame = NSRect(x: 0, y: 0, width: 26, height: 26)
            return b
        }

        undoButton = round("arrow.uturn.backward", tip: "Undo", action: #selector(undoTapped))
        redoButton = round("arrow.uturn.forward", tip: "Redo", action: #selector(redoTapped))
        place(undoButton, centerX: 30, centerY: size.height / 2)
        place(redoButton, centerX: 64, centerY: size.height / 2)

        penTool = MarkupToolView(kind: .pen, target: self, action: #selector(penTapped))
        markerTool = MarkupToolView(kind: .marker, target: self, action: #selector(markerTapped))
        eraserTool = MarkupToolView(kind: .eraser, target: self, action: #selector(eraserTapped))
        penTool.toolTip = EditorTool.freehand.title
        markerTool.toolTip = EditorTool.highlighter.title
        eraserTool.toolTip = EditorTool.eraser.title
        place(penTool, centerX: 116, centerY: size.height / 2)
        place(markerTool, centerX: 156, centerY: size.height / 2)
        place(eraserTool, centerX: 195, centerY: size.height / 2)

        let columns: [CGFloat] = [239, 273, 307]
        let rows: [CGFloat] = [25, 58]
        for (i, color) in Self.presetColors.enumerated() {
            let dot = ColorDot(color: color, target: self, action: #selector(dotTapped(_:)))
            dot.tag = i
            dots.append(dot)
            place(dot, centerX: columns[i % 3], centerY: rows[i / 3])
        }
        wheelDot = ColorDot(color: nil, target: self, action: #selector(wheelTapped))
        wheelDot.toolTip = "More colors"
        place(wheelDot, centerX: columns[2], centerY: rows[1])

        moreButton = round("ellipsis", tip: "More tools and options", action: #selector(moreTapped(_:)))
        // The symbol's dots sit low in its frame, so draw three dots exactly centered instead.
        moreButton.image = Self.centeredEllipsis()
        place(moreButton, centerX: 350, centerY: size.height / 2)

        return Glass.surface(content, cornerRadius: size.height / 2)
    }

    private static func centeredEllipsis() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let r: CGFloat = 1.7, gap: CGFloat = 4.6
            for i in -1...1 {
                let c = NSPoint(x: rect.midX + CGFloat(i) * gap, y: rect.midY)
                NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Toolbar (title bar)

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.title, .flexibleSpace, ItemID.zoom, ItemID.done]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.isBordered = false
        switch id {
        case ItemID.title:
            let label = NSTextField(labelWithString: window.title)
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
            item.view = label
        case ItemID.zoom:
            let minus = Glass.iconButton("minus", tip: "Zoom out", target: self, action: #selector(zoomOutTapped))
            let plus = Glass.iconButton("plus", tip: "Zoom in", target: self, action: #selector(zoomInTapped))
            minus.kind = .plain
            plus.kind = .plain
            let stack = NSStackView(views: [minus, plus])
            stack.spacing = 0
            stack.alignment = .centerY
            let surface = Glass.surface(stack, cornerRadius: 16, insets: NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2))
            sizeItem(surface, width: 76, height: 32)
            item.view = surface
        case ItemID.done:
            let b = Glass.button("Done", prominent: false, target: self, action: #selector(saveTapped))
            b.toolTip = "Copy to the clipboard and save to your screenshot folder"
            sizeItem(b, width: 66, height: 32)
            item.view = b
        default:
            return nil
        }
        return item
    }

    private func sizeItem(_ v: NSView, width: CGFloat, height: CGFloat) {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    // MARK: Showing

    private func selectTool(_ tool: EditorTool) {
        currentTool = tool
        penTool.isOn = tool == .freehand
        markerTool.isOn = tool == .highlighter
        eraserTool.isOn = tool == .eraser
        canvas.tool = tool
    }

    func show() {
        window.centerOnPointerScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    /// Presses Done (used by tests).
    func doneForTesting() { saveTapped() }

    /// Closes without asking (used by tests).
    func forceClose() {
        finished = true
        window.close()
    }

    private func updateUndoButtons() {
        undoButton?.isEnabled = canvas.canUndo
        redoButton?.isEnabled = canvas.canRedo
    }

    // MARK: Colors

    private static func hex(from color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private func updateTips() {
        penTool?.tipColor = canvas.currentColor
        markerTool?.tipColor = canvas.highlighterColor
    }

    private func updateSwatches() {
        updateTips()
        let current = Self.hex(from: canvas.currentColor)
        var matched = false
        for (i, dot) in dots.enumerated() {
            let on = Self.hex(from: Self.presetColors[i]) == current
            dot.isOn = on
            matched = matched || on
        }
        wheelDot.isOn = !matched
    }

    private func setColor(_ color: NSColor) {
        canvas.colorChanged(color)
        updateSwatches()
    }

    @objc private func dotTapped(_ sender: ColorDot) {
        if let c = sender.dotColor { setColor(c) }
    }

    /// A bare color wheel (no tabs, no opacity) that sits just to the right of the editor.
    @objc private func wheelTapped() {
        NSColorPanel.setPickerMask([.wheelModeMask])
        let panel = NSColorPanel.shared
        panel.mode = .wheel
        panel.showsAlpha = false
        panel.color = canvas.currentColor
        panel.setTarget(self)
        panel.setAction(#selector(panelColorChanged(_:)))
        panel.setFrameTopLeftPoint(panelTopLeft(for: panel))
        panel.orderFront(nil)
    }

    private func panelTopLeft(for panel: NSPanel) -> NSPoint {
        let gap: CGFloat = 8
        let visible = (window.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        // Right of the editor; if there is no room, tuck it against the screen's right edge instead.
        let x = min(window.frame.maxX + gap, visible.maxX - panel.frame.width)
        let y = min(window.frame.maxY, visible.maxY)
        return NSPoint(x: x, y: max(y, visible.minY + panel.frame.height))
    }

    @objc private func panelColorChanged(_ sender: NSColorPanel) {
        setColor(sender.color)
    }

    // MARK: Actions

    @objc private func penTapped() { selectTool(.freehand) }
    @objc private func markerTapped() { selectTool(.highlighter) }
    @objc private func eraserTapped() { selectTool(.eraser) }
    @objc private func undoTapped() { canvas.undo() }
    @objc private func redoTapped() { canvas.redo() }
    @objc private func zoomInTapped() { canvas.zoomIn() }
    @objc private func zoomOutTapped() { canvas.zoomOut() }
    @objc private func rotateLeftTapped() { canvas.rotateLeft() }
    @objc private func rotateRightTapped() { canvas.rotateRight() }
    @objc private func flipHTapped() { canvas.flipHorizontal() }
    @objc private func flipVTapped() { canvas.flipVertical() }

    // MARK: The "…" menu

    private func menuItem(_ title: String, symbol: String? = nil, action: Selector, tag: Int = 0, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.state = on ? .on : .off
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        return item
    }

    private func submenu(_ title: String, symbol: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        parent.submenu = menu
        return parent
    }

    private func toolItem(_ tool: EditorTool, _ title: String) -> NSMenuItem {
        menuItem(title, symbol: tool.symbol, action: #selector(toolPicked(_:)), tag: tool.rawValue, on: currentTool == tool)
    }

    /// A short menu of everyday tools; the rarer ones are one level down under "More".
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let style = canvas.style
        let unit = style.unit

        menu.addItem(toolItem(.text, "Text"))
        menu.addItem(submenu("Shapes", symbol: "square.on.circle", [
            toolItem(.arrow, "Arrow"), toolItem(.line, "Line"), toolItem(.rectangle, "Rectangle"), toolItem(.ellipse, "Ellipse"),
        ]))
        menu.addItem(submenu("Hide Details", symbol: "eye.slash", [
            toolItem(.redact, "Redact (solid, secure)"), toolItem(.blur, "Blur (not secure)"),
        ]))
        let aspects = ["Free crop", "1:1", "4:3", "3:2", "16:9", "16:10", "9:16"]
        menu.addItem(submenu("Crop", symbol: "crop", aspects.enumerated().map { i, title in
            menuItem(title, action: #selector(cropPicked(_:)), tag: i)
        }))
        menu.addItem(submenu("Rotate and Flip", symbol: "rotate.right", [
            menuItem("Rotate Left", symbol: "rotate.left", action: #selector(rotateLeftTapped)),
            menuItem("Rotate Right", symbol: "rotate.right", action: #selector(rotateRightTapped)),
            menuItem("Flip Horizontally", action: #selector(flipHTapped)),
            menuItem("Flip Vertically", action: #selector(flipVTapped)),
        ]))
        menu.addItem(.separator())

        // More
        var resizeItems = [25, 50, 75, 150, 200].map { menuItem("\($0)%", action: #selector(resizePicked(_:)), tag: $0) }
        resizeItems.append(menuItem("Set Width…", action: #selector(resizePicked(_:)), tag: -1))
        let currentPad = Int((style.padding / unit).rounded())
        var more: [NSMenuItem] = [
            toolItem(.select, "Select and Move"),
            toolItem(.filledRect, "Filled Rectangle"),
            toolItem(.counter, "Numbered Counter"),
            toolItem(.pixelate, "Pixelate (not secure)"),
            toolItem(.spotlight, "Spotlight"),
            .separator(),
            submenu("Line and Text Size", symbol: "textformat.size", ["Small", "Medium", "Large"].enumerated().map { i, title in
                menuItem(title, action: #selector(sizePicked(_:)), tag: i, on: canvas.sizeIndex == i)
            }),
            submenu("Resize", symbol: "arrow.up.left.and.arrow.down.right", resizeItems),
            submenu("Combine", symbol: "rectangle.on.rectangle", [
                "Add Image Below…", "Add Image to the Right…", "Add Clipboard Image Below", "Add Clipboard Image to the Right",
            ].enumerated().map { i, title in menuItem(title, action: #selector(combinePicked(_:)), tag: i) }),
            .separator(),
            menuItem("Remove Background (Cut Out Subject)", symbol: "person.crop.rectangle", action: #selector(cutOutTapped)),
        ]
        if style.backdrop != .none {
            more.append(menuItem("Remove Backdrop", symbol: "rectangle.slash", action: #selector(removeBackdropTapped)))
        }
        more.append(submenu("Background", symbol: "photo", Backdrop.allCases.enumerated().map { i, b in
            menuItem(b.title, action: #selector(backdropPicked(_:)), tag: i, on: style.backdrop == b)
        } + [.separator()] + [0, 24, 48, 72, 96, 128].map { p in
            let item = menuItem("Padding \(p)", action: #selector(paddingPicked(_:)), tag: p, on: currentPad == p)
            item.isEnabled = style.backdrop != .none
            return item
        } + [.separator()] + {
            let rounded = menuItem("Rounded Corners", action: #selector(roundedToggled), on: style.rounded)
            let shadow = menuItem("Shadow", action: #selector(shadowToggled), on: style.shadow)
            rounded.isEnabled = style.backdrop != .none
            shadow.isEnabled = style.backdrop != .none
            return [rounded, shadow]
        }()))
        let moreParent = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        let moreMenu = NSMenu(title: "More")
        more.forEach { moreMenu.addItem($0) }
        moreParent.submenu = moreMenu
        menu.addItem(moreParent)
        menu.addItem(.separator())

        menu.addItem(menuItem("Copy", symbol: "doc.on.doc", action: #selector(copyTapped)))
        menu.addItem(menuItem("Export…", symbol: "square.and.arrow.up", action: #selector(exportTapped)))
        return menu
    }

    @objc private func moreTapped(_ sender: NSView) {
        buildMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    @objc private func toolPicked(_ sender: NSMenuItem) {
        if let tool = EditorTool(rawValue: sender.tag) { selectTool(tool) }
    }

    @objc private func cropPicked(_ sender: NSMenuItem) {
        let titles = ["Free crop", "1:1", "4:3", "3:2", "16:9", "16:10", "9:16"]
        let parts = titles[min(max(sender.tag, 0), titles.count - 1)].split(separator: ":").compactMap { Double($0) }
        canvas.cropAspect = parts.count == 2 ? CGFloat(parts[0] / parts[1]) : nil
        selectTool(.crop)
    }

    @objc private func sizePicked(_ sender: NSMenuItem) {
        canvas.sizeIndex = sender.tag
        UserDefaults.standard.set(sender.tag, forKey: PrefKey.annSize)
    }

    @objc private func backdropPicked(_ sender: NSMenuItem) {
        let b = Backdrop.allCases[sender.tag]
        canvas.style.backdrop = b
        UserDefaults.standard.set(b.rawValue, forKey: PrefKey.annBackground)
        if b != .none && canvas.style.padding == 0 {
            canvas.style.padding = 48 * canvas.style.unit
        }
    }

    @objc private func paddingPicked(_ sender: NSMenuItem) {
        canvas.style.padding = CGFloat(sender.tag) * canvas.style.unit
        UserDefaults.standard.set(sender.tag, forKey: PrefKey.annPadding)
    }

    @objc private func removeBackdropTapped() {
        canvas.style.backdrop = .none
        UserDefaults.standard.set(Backdrop.none.rawValue, forKey: PrefKey.annBackground)
    }

    @objc private func cutOutTapped() {
        if !canvas.removeBackground() {
            Alerts.show(title: "No subject found", message: "Tack could not find a person or object to cut out of this picture.")
        }
    }

    @objc private func roundedToggled() {
        canvas.style.rounded.toggle()
        UserDefaults.standard.set(canvas.style.rounded, forKey: PrefKey.annRounded)
    }

    @objc private func shadowToggled() {
        canvas.style.shadow.toggle()
        UserDefaults.standard.set(canvas.style.shadow, forKey: PrefKey.annShadow)
    }

    @objc private func resizePicked(_ sender: NSMenuItem) {
        let tag = sender.tag
        if tag > 0 {
            canvas.resize(scale: CGFloat(tag) / 100)
        } else if tag == -1 {
            let alert = NSAlert()
            alert.messageText = "Resize to width"
            alert.informativeText = "Enter the new width in pixels. The height follows automatically."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
            field.stringValue = "\(canvas.base.width)"
            alert.accessoryView = field
            alert.addButton(withTitle: "Resize")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn, let w = Int(field.stringValue), w > 0, w < 20000 {
                canvas.resize(toWidth: w)
            }
        }
    }

    @objc private func combinePicked(_ sender: NSMenuItem) {
        let index = sender.tag
        let below = index == 0 || index == 2
        var other: CGImage?
        if index <= 1 {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
                other = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        } else if let img = NSImage(pasteboard: NSPasteboard.general) {
            other = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else {
            Alerts.show(title: "No image on the clipboard", message: "Copy an image first, then choose this again.")
        }
        if let other { canvas.combine(with: other, below: below) }
    }

    @objc private func exportTapped() {
        guard let final = canvas.renderFinal() else {
            Alerts.show(title: "Could not export", message: "The edited image could not be created.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.directoryURL = Prefs.screenshotFolder
        panel.nameFieldStringValue = FileSaver.filename(ext: Prefs.imageFormat.fileExtension)
        panel.message = "Choose a name and format. Tack never replaces an existing file; a number is added if the name is taken."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.lowercased()
        let format = ImageFormat.allCases.first { $0.fileExtension == ext || ($0 == .jpeg && ext == "jpeg") } ?? Prefs.imageFormat
        do {
            try FileSaver.save(final, as: format, to: url)
            finished = true
        } catch {
            Alerts.show(title: "Could not export", message: error.localizedDescription)
        }
    }

    /// Copy: clipboard only. Nothing is written to disk.
    @objc private func copyTapped() {
        guard let final = canvas.renderFinal() else {
            Alerts.show(title: "Could not copy", message: "The edited image could not be created.")
            return
        }
        Clipboard.copy(final, scale: scaleUnit)
        finished = true
        window.close()
    }

    /// Done: the editor closes and the edited picture comes back as a preview in the corner, with Copy and Save showing.
    /// Nothing is copied or saved until you choose one of them.
    @objc private func saveTapped() {
        guard let final = canvas.renderFinal() else {
            Alerts.show(title: "Could not finish", message: "The edited image could not be created.")
            return
        }
        finished = true
        window.close()
        QuickAccess.shared.present(final, scale: scaleUnit, showingActions: true)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if finished { return true }
        let alert = NSAlert()
        if let sourceURL {
            // The picture already exists as a file. Closing never deletes it.
            guard canvas.hasChanges else { return true }
            alert.messageText = "Close without saving your edits?"
            alert.informativeText = "Your original file “\(sourceURL.lastPathComponent)” is not changed or deleted."
            alert.addButton(withTitle: "Close")
        } else {
            alert.messageText = "Discard this screenshot?"
            alert.informativeText = "It hasn't been copied or saved yet."
            alert.addButton(withTitle: "Discard")
        }
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        Editor.release(self)
    }
}

@MainActor
enum Editor {
    private static var controllers: [EditorWindowController] = []
    /// The most recent capture, so "Open annotation editor" has something to open.
    static var lastCapture: CGImage?

    static func open(_ image: CGImage, source: URL? = nil, scale: CGFloat? = nil) {
        let controller = EditorWindowController(image: image, source: source, scale: scale)
        controllers.append(controller)
        DockPresence.refresh()
        controller.show()
    }

    /// Opens the clipboard image, else the last capture, else asks for a file.
    static func openFromAnywhere() {
        if let img = NSImage(pasteboard: NSPasteboard.general),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            open(cg)
        } else if let last = lastCapture {
            open(last)
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.message = "Choose an image to edit"
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url,
               let img = NSImage(contentsOf: url),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                open(cg, source: url)
            }
        }
    }

    static func open(file url: URL) {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Alerts.show(title: "Could not open the image", message: "Tack could not read “\(url.lastPathComponent)”.")
            return
        }
        open(cg, source: url)
    }

    static var openCount: Int { controllers.count }
    static var firstForTesting: EditorWindowController? { controllers.first }
    static func closeAllWithoutAsking() { controllers.forEach { $0.forceClose() } }

    static func release(_ controller: EditorWindowController) {
        controllers.removeAll { $0 === controller }
        DockPresence.refresh()
    }

}
