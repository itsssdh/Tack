import AppKit

/// Tack's look: Apple's Liquid Glass on macOS 26 and later, a blurred material on older versions.
@MainActor
enum Glass {
    static var isLiquid: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Wraps `content` in a glass surface. `cornerRadius` of half the height makes a capsule.
    static func surface(
        _ content: NSView,
        cornerRadius: CGFloat,
        tint: NSColor? = nil,
        clear: Bool = false,
        insets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    ) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -insets.right),
            content.topAnchor.constraint(equalTo: holder.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -insets.bottom),
        ])
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = clear ? .clear : .regular
            if let tint { glass.tintColor = tint }
            glass.contentView = holder
            return glass
        }
        let fallback = NSVisualEffectView()
        fallback.material = .hudWindow
        fallback.blendingMode = .behindWindow
        fallback.state = .active
        fallback.wantsLayer = true
        fallback.layer?.cornerRadius = cornerRadius
        fallback.layer?.masksToBounds = true
        fallback.layer?.borderWidth = 0.5
        fallback.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        if let tint {
            let wash = NSView()
            wash.wantsLayer = true
            wash.layer?.backgroundColor = tint.withAlphaComponent(0.25).cgColor
            wash.translatesAutoresizingMaskIntoConstraints = false
            fallback.addSubview(wash)
            NSLayoutConstraint.activate([
                wash.leadingAnchor.constraint(equalTo: fallback.leadingAnchor),
                wash.trailingAnchor.constraint(equalTo: fallback.trailingAnchor),
                wash.topAnchor.constraint(equalTo: fallback.topAnchor),
                wash.bottomAnchor.constraint(equalTo: fallback.bottomAnchor),
            ])
        }
        holder.translatesAutoresizingMaskIntoConstraints = false
        fallback.addSubview(holder)
        NSLayoutConstraint.activate([
            holder.leadingAnchor.constraint(equalTo: fallback.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: fallback.trailingAnchor),
            holder.topAnchor.constraint(equalTo: fallback.topAnchor),
            holder.bottomAnchor.constraint(equalTo: fallback.bottomAnchor),
        ])
        return fallback
    }

    /// A capsule button with an optional icon. `prominent` fills it with `tint` (the accent color by default).
    static func button(
        _ title: String,
        symbol: String? = nil,
        prominent: Bool = false,
        tint: NSColor? = nil,
        size: NSControl.ControlSize = .regular,
        target: AnyObject?,
        action: Selector
    ) -> PillButton {
        let b = PillButton(title: title, target: target, action: action)
        b.controlSize = size
        if prominent { b.kind = .prominent; b.tint = tint ?? .controlAccentColor }
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            b.image = img
            b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        return b
    }

    /// A round icon-only button.
    static func iconButton(_ symbol: String, tip: String, prominent: Bool = false, tint: NSColor? = nil, target: AnyObject?, action: Selector) -> PillButton {
        let b = PillButton(title: "", target: target, action: action)
        b.iconOnly = true
        if prominent { b.kind = .prominent; b.tint = tint ?? .controlAccentColor }
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.toolTip = tip
        return b
    }

    /// A floating glass group of controls.
    static func group(_ views: [NSView], spacing: CGFloat = 8, insets: NSEdgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10), cornerRadius: CGFloat = 22) -> NSView {
        let stack = NSStackView(views: views)
        stack.spacing = spacing
        stack.alignment = .centerY
        return surface(stack, cornerRadius: cornerRadius, insets: insets)
    }

    /// The size a surface needs to hold `content` plus `insets`.
    static func fittingSize(of content: NSView, insets: NSEdgeInsets) -> NSSize {
        content.layoutSubtreeIfNeeded()
        let s = content.fittingSize
        return NSSize(width: ceil(s.width + insets.left + insets.right), height: ceil(s.height + insets.top + insets.bottom))
    }

    /// Puts a glass surface in its own floating panel, centered horizontally on `centerX`, `bottom` points above the screen's bottom.
    /// The panel is a little larger than the glass so the glass's soft shadow is not cut off at the window edge.
    static func floatingPanel(
        surface: NSView,
        size: NSSize,
        centerX: CGFloat,
        bottom: CGFloat,
        level: NSWindow.Level = .statusBar,
        key: Bool = false
    ) -> NSPanel {
        let margin: CGFloat = 30
        let frame = NSRect(x: centerX - size.width / 2 - margin, y: bottom - margin, width: size.width + 2 * margin, height: size.height + 2 * margin)
        let p = panel(frame: frame, level: level, key: key)
        let root = NSView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            surface.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margin),
        ])
        p.contentView = root
        return p
    }

    /// A standard borderless, transparent, always-on-top panel for floating UI.
    static func panel(frame: NSRect, level: NSWindow.Level = .statusBar, key: Bool = false) -> NSPanel {
        let p: NSPanel = key ? KeyablePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                             : NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = level
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // the glass draws its own edge; a window shadow would show as a rectangle
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A label that is not selectable and sits nicely inside glass.
@MainActor
func glassLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .medium, color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    return l
}


/// Tack's capsule button. Drawn by us (not the system bezel) so it looks the same on every macOS version,
/// reacts to hover and press, and keeps its tint when placed on glass.
@MainActor
final class PillButton: NSButton {
    enum Kind { case regular, prominent, chip, plain }

    var kind: Kind = .regular { didSet { refresh() } }
    var tint: NSColor = .controlAccentColor { didSet { refresh() } }
    var isOn = false { didSet { refresh() } }
    var iconOnly = false
    /// Free-form key for callers (e.g. the preference this chip controls).
    var key = ""

    private var hovering = false
    private var pressing = false
    private var trackingArea: NSTrackingArea?

    convenience init(title: String, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerCurve = .circular
        setButtonType(.momentaryChange)
        focusRingType = .none
        imageHugsTitle = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var height: CGFloat {
        switch controlSize {
        case .mini, .small: return 26
        case .large, .extraLarge: return 38
        default: return 32
        }
    }

    private var textSize: CGFloat {
        switch controlSize {
        case .mini, .small: return 12
        case .large, .extraLarge: return 14
        default: return 13
        }
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: iconOnly ? height : base.width + (image != nil && !title.isEmpty ? 30 : 26), height: height)
    }

    /// NSButton reports padding for its (unused) system bezel, which made a 26 pt round button 29 to 33 pt tall and turned it
    /// into a lens. The button is drawn entirely by us, so it has no such padding.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.4 } }
    override var title: String { didSet { refresh() } }
    override var image: NSImage? { didSet { refresh() } }
    override var controlSize: NSControl.ControlSize { didSet { refresh(); invalidateIntrinsicContentSize() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressing = true
        refresh()
        super.mouseDown(with: event) // tracks until the mouse is released
        pressing = false
        refresh()
    }

    private func refresh() {
        guard let layer else { return }
        let filled = (kind == .prominent) || ((kind == .chip || kind == .plain) && isOn)
        var color: NSColor
        if filled {
            color = tint
        } else if kind == .plain {
            color = .clear
        } else {
            color = NSColor.labelColor.withAlphaComponent(0.13)
        }
        if pressing {
            color = filled ? (tint.blended(withFraction: 0.25, of: .black) ?? tint) : NSColor.labelColor.withAlphaComponent(0.26)
        } else if hovering {
            color = filled ? (tint.blended(withFraction: 0.15, of: .white) ?? tint) : NSColor.labelColor.withAlphaComponent(kind == .plain ? 0.15 : 0.22)
        }
        // Resolve dynamic colors for the current appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = color.cgColor
        }
        let textColor: NSColor = filled ? .white : .labelColor
        contentTintColor = textColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: textSize, weight: .semibold),
            .foregroundColor: textColor,
        ])
    }
}


extension NSWindow {
    /// Centers on the display the pointer is on (the display you are looking at), not always the main one.
    @MainActor
    func centerOnPointerScreen() {
        let area = CaptureService.screenUnderMouse().visibleFrame
        setFrameOrigin(NSPoint(x: (area.midX - frame.width / 2).rounded(), y: (area.midY - frame.height / 2 + area.height * 0.05).rounded()))
    }
}
