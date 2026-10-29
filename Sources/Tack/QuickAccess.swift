import AppKit
import AVFoundation

private final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Click anywhere on the preview (except the buttons) to edit. Right-click for more options.
private final class OverlayContentView: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    /// Called once when the pointer is pulled away from the card with the button held, to start dragging it out.
    var onDrag: ((NSEvent) -> Void)?
    var makeMenu: (() -> NSMenu)?
    private var pressStart: NSPoint?
    private var dragging = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // One area for the life of the view: `.inVisibleRect` already follows resizes, and rebuilding it while the pointer is
        // inside (as happens when a text card grows) loses the "pointer left" event.
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        var cursor: NSView? = v
        while let c = cursor {
            if c is NSButton { return c }
            cursor = c.superview
        }
        return v == nil ? nil : self
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {
        pressStart = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStart, !dragging, let onDrag else { return }
        if hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 {
            dragging = true
            onDrag(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressStart = nil; dragging = false }
        if !dragging { onClick?() }
    }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// What a preview shows. Videos and GIFs play inside the card.
enum PreviewMedia {
    case image
    case video(URL)
    case gif(URL)
    /// Text read from the screen. The card is drawn from the text; Copy puts the text itself on the clipboard.
    case text(String)
}

/// Plays a video silently, on a loop, filling its frame.
private final class LoopingVideoView: NSView {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()

    init(url: URL, frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        player = queue
        playerLayer.player = queue
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
        queue.play()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func setPlaying(_ on: Bool) { on ? player?.play() : player?.pause() }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        playerLayer.player = nil
        player = nil
    }
}

/// Text read from the screen, drawn as a preview card. The card is only as big as its text needs, up to a limit; text that
/// does not fit ends in "…" and the card grows to show more of it while the pointer is over it.
private enum TextCard {
    /// Room kept clear for the close button above the text and the pin and Copy buttons below it.
    static let side: CGFloat = 16, top: CGFloat = 40, bottom: CGFloat = 44
    static let minSize = NSSize(width: 150, height: 112)

    /// The biggest a resting card gets, following the Preview size setting.
    static var limit: NSSize {
        switch UserDefaults.standard.string(forKey: PrefKey.overlaySize) {
        case "small": return NSSize(width: 170, height: 170)
        case "large": return NSSize(width: 300, height: 270)
        default: return NSSize(width: 220, height: 205)
        }
    }

    private static var font: NSFont { .systemFont(ofSize: 12.5 * limit.width / 220, weight: .medium) }
    private static let spacing: CGFloat = 2

    private static func attributed(_ text: String) -> NSTextStorage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = spacing
        return NSTextStorage(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .paragraphStyle: paragraph,
        ])
    }

    /// How much room the whole text takes when wrapped to `width` (the width of the whole card).
    private static func measure(_ text: String, cardWidth: CGFloat) -> NSSize {
        let storage = attributed(text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(cardWidth - 2 * side, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }

    /// Small text gives a small card; a lot of text gives the biggest resting card.
    static func collapsedSize(for text: String) -> NSSize {
        let max = limit
        let natural = measure(text, cardWidth: 100_000).width + 2 * side
        let width = min(Swift.max(natural.rounded(.up), minSize.width), max.width)
        let needed = top + measure(text, cardWidth: width).height + bottom
        return NSSize(width: width.rounded(), height: min(Swift.max(needed.rounded(.up), minSize.height), max.height))
    }

    /// The size the card grows to under the pointer, or nil when the resting card already shows everything.
    /// Never taller than the screen; text beyond that ends in "…".
    static func expandedSize(for text: String, collapsed: NSSize, in visible: NSRect) -> NSSize? {
        let needsAll = top + measure(text, cardWidth: collapsed.width).height + bottom
        guard needsAll > collapsed.height + 0.5 else { return nil }
        let width = Swift.max(collapsed.width, min(limit.width * 1.7, visible.width * 0.45)).rounded()
        let needed = top + measure(text, cardWidth: width).height + bottom
        let height = min(Swift.max(needed.rounded(.up), collapsed.height), visible.height - 32)
        let size = NSSize(width: width, height: height.rounded())
        return (size.width > collapsed.width || size.height > collapsed.height) ? size : nil
    }

    /// Draws the card at `size` points on a display with the given pixel density.
    static func render(_ text: String, size: NSSize, scale: CGFloat) -> CGImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size // points; the context is made after this so it draws in points, not pixels
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        // Work out how much of the text fits, and mark where it was cut with "…" (also when the cut falls at the end of a line).
        let area = NSSize(width: size.width - 2 * side, height: size.height - top - bottom)
        let lineHeight = font.ascender - font.descender + font.leading
        let maxLines = Swift.max(1, Int((area.height + spacing) / (lineHeight + spacing)))
        var shown = text
        do {
            let probe = NSLayoutManager()
            let box = NSTextContainer(size: area)
            box.lineFragmentPadding = 0
            probe.addTextContainer(box)
            let storage = attributed(text)
            storage.addLayoutManager(probe)
            let range = probe.characterRange(forGlyphRange: probe.glyphRange(for: box), actualGlyphRange: nil)
            if range.upperBound < (text as NSString).length {
                let kept = (text as NSString).substring(to: range.upperBound).trimmingCharacters(in: .whitespacesAndNewlines)
                shown = kept + "…"
            }
        }

        let storage = attributed(shown)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: area)
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byTruncatingTail
        container.maximumNumberOfLines = maxLines
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        // TextKit draws from the top down, so flip the drawing space.
        let cg = ctx.cgContext
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: NSPoint(x: side, y: top))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

/// One floating preview. Stays until the user chooses Copy or Save (or dismisses it), so a capture is never lost by accident.
@MainActor
private final class QuickAccessItem: NSObject {
    /// For a video or GIF this is a still of its first frame, used for sizing and thumbnails.
    let image: CGImage
    let media: PreviewMedia
    private var videoView: LoopingVideoView?
    /// The display the previews are shown on.
    let screen: NSScreen
    /// Pixel density of the display the picture was captured on (which may not be the one showing the preview).
    let captureScale: CGFloat
    let size: NSSize
    let panel: QuickPanel
    /// Smallest card that still has room for the corner buttons and the stacked Copy / Save buttons without touching.
    /// The close, pin and edit buttons in the corners are all this size.
    private static let cornerButton: CGFloat = 26
    private static let minSize = NSSize(width: 150, height: 150)
    private let onDone: (QuickAccessItem) -> Void
    private let onEdit: (QuickAccessItem) -> Void
    var onTogglePin: ((QuickAccessItem) -> Void)?
    /// Set when the picture is already a file on disk (pinned from the history window), so Save does not write a second copy.
    var savedURL: URL?
    /// A pinned preview stays on screen (above newer ones) until it is unpinned, copied, saved or dismissed.
    var pinned = false {
        didSet {
            if pinned && !oldValue { pinOrder = QuickAccessItem.nextPinOrder; QuickAccessItem.nextPinOrder += 1 }
            refreshPin()
        }
    }
    /// When it was pinned, so the most recently pinned preview can sit closest to the corner.
    private(set) var pinOrder = 0
    private static var nextPinOrder = 1
    /// True while the preview is folded into the group tile because the stack ran out of room.
    var hiddenInGroup = false
    private var pinButton: PillButton?
    private var pinBadge: NSView?
    /// Keeps the drag's data provider alive while a drag is under way.
    fileprivate var dragData: AnyObject?
    /// A text card that is cut off grows while the pointer is over it. The picture view shows whichever drawing is current.
    private var textImageView: NSView?
    /// Where the stack puts this card when it is not grown. Set by the layout, never read back from the window,
    /// which may be part-way through an animation.
    var restFrame: NSRect?
    private(set) var isExpanded = false
    /// While a card is grown, this checks that the pointer is still over it, in case the "pointer left" event is missed.
    private var pointerWatch: Timer?

    init(
        image: CGImage,
        media: PreviewMedia,
        screen: NSScreen,
        captureScale: CGFloat,
        onDone: @escaping (QuickAccessItem) -> Void,
        onEdit: @escaping (QuickAccessItem) -> Void
    ) {
        self.image = image
        self.media = media
        self.screen = screen
        self.captureScale = captureScale
        self.onDone = onDone
        self.onEdit = onEdit

        let scale = captureScale
        if case .text = media {
            guard case .text(let string) = media else { fatalError("unreachable") }
            self.size = TextCard.collapsedSize(for: string)
            self.panel = QuickPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            super.init()
            buildUI(scale: scale)
            return
        }
        let natural = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let box: NSSize
        switch UserDefaults.standard.string(forKey: PrefKey.overlaySize) {
        case "small": box = NSSize(width: 170, height: 120)
        case "large": box = NSSize(width: 300, height: 200)
        default: box = NSSize(width: 220, height: 150)
        }
        // The card has exactly the picture's shape, so there are never bars around it.
        let fit = min(box.width / natural.width, box.height / natural.height, 1)
        var w = natural.width * fit, h = natural.height * fit
        // Very small or very thin pictures are enlarged so the buttons fit; if that makes one side too long it is cropped, not padded.
        let grow = max(Self.minSize.width / w, Self.minSize.height / h, 1)
        // The "Small" size setting is shorter than the room the buttons need, so the minimum wins over the box.
        w = max(min(w * grow, box.width), Self.minSize.width)
        h = max(min(h * grow, box.height), Self.minSize.height)
        self.size = NSSize(width: w.rounded(), height: h.rounded())
        self.panel = QuickPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildUI(scale: scale)
    }

    private func buildUI(scale: CGFloat) {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true // the preview is an opaque rounded picture, so a window shadow suits it
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Stationary: switching desktops or opening Mission Control leaves the card alone instead of moving or hiding it.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = OverlayContentView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.cornerRadius = 22
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        content.onClick = { [weak self] in
            guard let self, self.canEdit else { return }
            self.onEdit(self)
        }
        content.makeMenu = { [weak self] in self?.buildMenu() ?? NSMenu() }
        content.onDrag = { [weak self, weak content] event in
            guard let self, let content else { return }
            self.beginDrag(with: event, from: content)
        }

        let imageView = NSView(frame: content.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.contents = image
        imageView.layer?.contentsGravity = .resizeAspectFill
        imageView.layer?.contentsScale = scale
        imageView.layer?.magnificationFilter = .trilinear
        content.addSubview(imageView)
        if isText { textImageView = imageView }

        switch media {
        case .image:
            break
        case .video(let url):
            let v = LoopingVideoView(url: url, frame: content.bounds)
            v.autoresizingMask = [.width, .height]
            content.addSubview(v)
            videoView = v
        case .text:
            break // the picture already is the text
        case .gif(let url):
            // The first frame is already showing; this replaces it with the animation.
            let v = NSImageView(frame: content.bounds)
            v.autoresizingMask = [.width, .height]
            v.imageScaling = .scaleProportionallyUpOrDown
            v.animates = true
            v.image = NSImage(contentsOf: url)
            content.addSubview(v)
        }

        let badge = NSView(frame: NSRect(x: size.width - 32, y: 10, width: 22, height: 22))
        badge.autoresizingMask = [.minXMargin, .maxYMargin]
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 11
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        let badgeIcon = NSImageView(frame: badge.bounds.insetBy(dx: 5, dy: 5))
        badgeIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        badgeIcon.contentTintColor = .white
        badge.addSubview(badgeIcon)
        badge.isHidden = true
        content.addSubview(badge)
        pinBadge = badge

        let dim = NSView(frame: content.bounds)
        dim.autoresizingMask = [.width, .height]
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        dim.alphaValue = 0
        content.addSubview(dim)

        let close = Glass.iconButton("xmark", tip: "Dismiss without saving", target: self, action: #selector(dismissTapped))
        close.controlSize = .small
        close.translatesAutoresizingMaskIntoConstraints = false
        dim.addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: dim.topAnchor, constant: 10),
            close.leadingAnchor.constraint(equalTo: dim.leadingAnchor, constant: 10),
            close.widthAnchor.constraint(equalToConstant: Self.cornerButton),
            close.heightAnchor.constraint(equalToConstant: Self.cornerButton),
        ])

        let pin = Glass.iconButton("pin.fill", tip: "Pin this preview", target: self, action: #selector(togglePinTapped))
        pin.controlSize = .small
        pinButton = pin
        pin.translatesAutoresizingMaskIntoConstraints = false
        dim.addSubview(pin)
        NSLayoutConstraint.activate([
            pin.bottomAnchor.constraint(equalTo: dim.bottomAnchor, constant: -10),
            pin.leadingAnchor.constraint(equalTo: dim.leadingAnchor, constant: 10),
            pin.widthAnchor.constraint(equalToConstant: Self.cornerButton),
            pin.heightAnchor.constraint(equalToConstant: Self.cornerButton),
        ])

        let edit = Glass.iconButton("pencil", tip: "Edit", target: self, action: #selector(editTapped))
        edit.isHidden = !canEdit
        edit.controlSize = .small
        edit.translatesAutoresizingMaskIntoConstraints = false
        dim.addSubview(edit)
        NSLayoutConstraint.activate([
            edit.topAnchor.constraint(equalTo: dim.topAnchor, constant: 10),
            edit.trailingAnchor.constraint(equalTo: dim.trailingAnchor, constant: -10),
            edit.widthAnchor.constraint(equalToConstant: Self.cornerButton),
            edit.heightAnchor.constraint(equalToConstant: Self.cornerButton),
        ])

        layoutButtons(in: dim)

        content.onHover = { [weak self, weak dim] inside in
            if !inside, let self, self.isExpanded, NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false) { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                dim?.animator().alphaValue = inside ? 1 : 0
            }
            guard let self else { return }
            if inside {
                self.expand()
            } else if !(self.isExpanded && NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false)) {
                self.collapse() // growing or shrinking can report a false "pointer left"; only collapse when it really has
            }
        }

        panel.contentView = content
    }

    /// Copy above Save, centered, growing with the card. The corner buttons take 10 pt of inset plus their own size
    /// at the top and bottom, so the pair stays between them whatever the card's size.
    private func layoutButtons(in dim: NSView) {
        if isText, let pin = pinButton {
            // Copy sits beside the pin button along the bottom, so it never covers the text.
            let copy = Glass.button("Copy", symbol: "doc.on.doc", prominent: true, size: .small, target: self, action: #selector(copyTapped))
            copy.translatesAutoresizingMaskIntoConstraints = false
            dim.addSubview(copy)
            NSLayoutConstraint.activate([
                copy.leadingAnchor.constraint(equalTo: pin.trailingAnchor, constant: 8),
                copy.centerYAnchor.constraint(equalTo: pin.centerYAnchor),
                copy.widthAnchor.constraint(equalToConstant: 84),
                copy.heightAnchor.constraint(equalToConstant: Self.cornerButton),
            ])
            return
        }
        let w = size.width, h = size.height
        let clearance: CGFloat = 10 + Self.cornerButton + 8
        let spacing: CGFloat = 10

        var bh = min(max(h * 0.16, 28), 48)
        bh = min(bh, (h - 2 * clearance - spacing) / 2) // never taller than the gap between the corner buttons allows
        let bw = min(max(w * 0.52, 72), 190)
        let withIcons = bw >= 100
        let control: NSControl.ControlSize = bh >= 40 ? .large : (bh >= 32 ? .regular : .small)
        let font = NSFont.systemFont(ofSize: min(max(bh * 0.42, 12), 19), weight: .semibold)

        func make(_ title: String, symbol: String, prominent: Bool, action: Selector) -> NSButton {
            let b = Glass.button(title, symbol: withIcons ? symbol : nil, prominent: prominent, size: control, target: self, action: action)
            b.font = font
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: bw).isActive = true
            b.heightAnchor.constraint(equalToConstant: bh).isActive = true
            return b
        }
        let copy = make("Copy", symbol: "doc.on.doc", prominent: false, action: #selector(copyTapped))
        let save = make("Save", symbol: "square.and.arrow.down", prominent: true, action: #selector(saveTapped))
        let group = NSStackView(views: [copy, save])
        group.orientation = .vertical
        group.spacing = spacing
        group.alignment = .centerX
        group.translatesAutoresizingMaskIntoConstraints = false
        dim.addSubview(group)
        NSLayoutConstraint.activate([
            group.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
            group.centerYAnchor.constraint(equalTo: dim.centerYAnchor),
        ])
    }

    /// Grows a cut-off text card away from its corner of the screen (over the cards beside it) to show more of the text.
    private func expand() {
        guard case .text(let string) = media, !isExpanded, !hiddenInGroup, let view = textImageView else { return }
        let visible = screen.visibleFrame
        guard let target = TextCard.expandedSize(for: string, collapsed: size, in: visible),
              let image = TextCard.render(string, size: target, scale: captureScale) else { return }
        let rest = restFrame ?? panel.frame
        var frame = NSRect(origin: .zero, size: target)
        frame.origin.x = rest.midX > visible.midX ? rest.maxX - target.width : rest.minX
        frame.origin.y = rest.midY > visible.midY ? rest.maxY - target.height : rest.minY
        frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - 8 - target.width)
        frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - 8 - target.height)
        isExpanded = true
        pointerWatch?.invalidate()
        pointerWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isExpanded else { return }
                if !NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false) {
                    (self.panel.contentView as? OverlayContentView)?.onHover?(false)
                }
            }
        }
        view.layer?.contents = image
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Back to the resting size. `animated: false` is used when the stack is being laid out again.
    func collapse(animated: Bool = true) {
        guard isExpanded, let rest = restFrame, let view = textImageView else { return }
        isExpanded = false
        pointerWatch?.invalidate()
        pointerWatch = nil
        view.layer?.contents = image
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(rest, display: true)
            }
        } else {
            panel.setFrame(rest, display: true)
        }
    }

    /// Used by the visual test to show the hover state.
    func simulateHover() { (panel.contentView as? OverlayContentView)?.onHover?(true) }

    /// GIFs have nothing to edit; photos open the editor and videos open the trimmer.
    var canEdit: Bool {
        switch media {
        case .gif, .text: return false
        default: return true
        }
    }

    /// Play or pause the video (folded-away previews should not keep playing).
    func setPlaying(_ on: Bool) { videoView?.setPlaying(on) }
    func stopMedia() { videoView?.stop() }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        var entries: [(String, Selector)] = []
        if canEdit { entries.append((isVideo ? "Trim…" : "Edit…", #selector(editTapped))) }
        if isText { entries.append(("Copy", #selector(copyTapped))) }
        if !isVideo, !isGIF, !isText {
            entries.append(("Pin to Screen", #selector(pinTapped)))
            entries.append(("Copy Text (OCR / QR)", #selector(ocrTapped)))
        }
        for (title, sel) in entries {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !entries.isEmpty { menu.addItem(.separator()) }
        let dismiss = NSMenuItem(title: "Dismiss Without Saving", action: #selector(dismissTapped), keyEquivalent: "")
        dismiss.target = self
        menu.addItem(dismiss)
        return menu
    }

    private func refreshPin() {
        pinButton?.image = NSImage(systemSymbolName: pinned ? "pin.slash.fill" : "pin.fill", accessibilityDescription: pinned ? "Unpin" : "Pin")
        pinButton?.toolTip = pinned ? "Unpin this preview" : "Pin this preview"
        pinBadge?.isHidden = !pinned
    }

    @objc fileprivate func togglePinTapped() { onTogglePin?(self) }
    @objc fileprivate func editTapped() { onEdit(self) }
    @objc private func pinTapped() { PinManager.shared.pin(image) }

    @objc private func ocrTapped() {
        let image = self.image
        Task {
            let result = await Scanner.scan(image)
            ScanHandler.handle(result)
        }
    }

    /// A pinned preview does not close: it shakes to say so. Unpin it first.
    @objc fileprivate func dismissTapped() {
        if pinned { shake(); return }
        onDone(self)
    }

    private func shake() {
        let base = panel.frame
        let offsets: [CGFloat] = [-9, 9, -7, 7, -4, 4, 0]
        for (i, dx) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045 * Double(i + 1)) { [weak self] in
                guard let self, self.pinned || dx == 0 else { return }
                // Only move it if layout has not moved it meanwhile.
                guard abs(self.panel.frame.minY - base.minY) < 1 else { return }
                self.panel.setFrameOrigin(NSPoint(x: base.minX + dx, y: base.minY))
            }
        }
    }

    private var isVideo: Bool { if case .video = media { return true }; return false }
    private var isGIF: Bool { if case .gif = media { return true }; return false }
    var isText: Bool { if case .text = media { return true }; return false }

    /// A picture goes on the clipboard as an image; a video or GIF as its file, so it pastes into Finder, Mail, Messages.
    private func copyToClipboard() {
        switch media {
        case .image:
            Clipboard.copy(image, scale: captureScale)
        case .video(let url), .gif(let url):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        case .text(let string):
            Clipboard.copy(text: string)
        }
    }

    /// Copy: clipboard only. Nothing is written to disk.
    @objc fileprivate func copyTapped() {
        copyToClipboard()
        onDone(self)
    }

    /// Save: clipboard and the screenshot folder. If saving fails the preview stays so nothing is lost.
    /// Videos and GIFs are saved the moment a recording ends, so for them Save just copies the file and closes the preview.
    @objc fileprivate func saveTapped() {
        copyToClipboard()
        if savedURL != nil {
            onDone(self)
            return
        }
        do {
            try FileSaver.save(image)
        } catch {
            Alerts.show(title: "Could not save the screenshot", message: error.localizedDescription)
            return
        }
        onDone(self)
    }
}


// MARK: Dragging a preview out

/// Brings another app to the front. Recent macOS versions only let an app be activated by an app that is itself active and
/// hands the activation over, so Tack takes it first and then passes it on; if the system still refuses, the app is
/// asked to open again with activation on, which also raises it.
@MainActor
private func bringToFront(pid: pid_t) {
    guard let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated else { return }
    NSApp.activate(ignoringOtherApps: true)
    NSApp.yieldActivation(to: target)
    target.activate(from: NSRunningApplication.current, options: [])
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        guard !target.isActive, let url = target.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }
}

/// Hands a screenshot to whatever it is dropped on, as a file and as image data, so it works in text boxes, chats, mail and Finder.
/// The file is only written when the drop target asks for it.
private final class PreviewDragData: NSObject, NSPasteboardItemDataProvider {
    private let image: CGImage

    init(image: CGImage) { self.image = image }

    /// Where dragged files are made. Old ones are swept up so screenshots do not pile up in the temporary folder.
    static var folder: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Tack Drag", isDirectory: true) }

    static func sweep() {
        let cutoff = Date().addingTimeInterval(-3600)
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in items where ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        MainActor.assumeIsolated {
            switch type {
            case .fileURL:
                let format = Prefs.imageFormat
                guard let data = format.encode(image, quality: Prefs.jpegQuality) else { return }
                let folder = Self.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let url = folder.appendingPathComponent(FileSaver.filename(ext: format.fileExtension))
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    item.setString(url.absoluteString, forType: .fileURL)
                } catch {}
            case .png:
                item.setData(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data(), forType: .png)
            case .tiff:
                item.setData(NSBitmapImageRep(cgImage: image).tiffRepresentation ?? Data(), forType: .tiff)
            default:
                break
            }
        }
    }
}

extension QuickAccessItem: NSDraggingSource {
    /// Pull a preview out of its corner and drop it into another app: a picture arrives as an image file, a recording as its
    /// file, text as text. Like Apple's screenshot previews, the card goes away once it has been dropped somewhere.
    fileprivate func beginDrag(with event: NSEvent, from view: NSView) {
        let writer: NSPasteboardWriting
        switch media {
        case .image:
            PreviewDragData.sweep()
            let pasteboardItem = NSPasteboardItem()
            let provider = PreviewDragData(image: image)
            dragData = provider // the pasteboard only keeps a weak reference
            pasteboardItem.setDataProvider(provider, forTypes: [.fileURL, .png, .tiff])
            writer = pasteboardItem
        case .video(let url), .gif(let url):
            writer = url as NSURL
        case .text(let string):
            writer = string as NSString
        }
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(view.bounds, contents: NSImage(cgImage: image, size: view.bounds.size))
        view.beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        panel.animator().alphaValue = 0.45
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragData = nil
        if !operation.isEmpty { Self.focusApp(at: screenPoint) }
        if operation.isEmpty || pinned {
            panel.animator().alphaValue = 1 // dropped nowhere, or pinned: the card stays
        } else {
            dismissTapped()
        }
    }

    /// The app that was dropped on comes to the front, so you can carry on typing or editing right where the drop landed.
    private static func focusApp(at screenPoint: NSPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y) // window lists count from the top left
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in windows { // front to back
            guard let layer = entry[kCGWindowLayer as String] as? Int, (0...8).contains(layer), // ordinary, floating and modal windows; not the menu bar or Dock
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let b = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"],
                  CGRect(x: x, y: y, width: w, height: h).contains(point) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { bringToFront(pid: pid) }
            return
        }
    }
}

// MARK: Pinned group

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// "3 pinned", "3 screenshots" or, when text cards are among them, "3 previews".
@MainActor
private func groupTitle(for items: [QuickAccessItem]) -> String {
    if items.allSatisfy({ $0.pinned }) { return "\(items.count) pinned" }
    return items.contains(where: { $0.isText }) ? "\(items.count) previews" : "\(items.count) screenshots"
}

/// What the pinned previews turn into when the stack reaches the top of the screen: one card with a count. Click it for the list.
@MainActor
private final class PinnedGroupTile: NSObject {
    static let size = NSSize(width: 150, height: 96)

    let panel: QuickPanel
    var onClick: (() -> Void)?
    private let imageLayerView = NSView()
    private let countLabel = glassLabel("", size: 15, weight: .semibold, color: .white)
    private let icon = NSImageView()

    override init() {
        panel = QuickPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = OverlayContentView(frame: NSRect(origin: .zero, size: Self.size))
        content.wantsLayer = true
        content.layer?.cornerRadius = 22
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        content.onClick = { [weak self] in self?.onClick?() }

        imageLayerView.frame = content.bounds
        imageLayerView.autoresizingMask = [.width, .height]
        imageLayerView.wantsLayer = true
        imageLayerView.layer?.contentsGravity = .resizeAspectFill
        content.addSubview(imageLayerView)

        let dim = NSView(frame: content.bounds)
        dim.autoresizingMask = [.width, .height]
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        content.addSubview(dim)

        icon.contentTintColor = .white
        let stack = NSStackView(views: [icon, countLabel])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        dim.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: dim.centerYAnchor),
        ])
        panel.contentView = content
    }

    func update(items: [QuickAccessItem]) {
        let allPinned = items.allSatisfy { $0.pinned }
        countLabel.stringValue = groupTitle(for: items)
        icon.image = NSImage(systemSymbolName: allPinned ? "pin.fill" : "photo.on.rectangle", accessibilityDescription: nil)
        imageLayerView.layer?.contents = items.first?.image
        // A text card is taller than the tile; show its top lines instead of the middle of the card.
        if let first = items.first, first.isText {
            let tileAspect = Self.size.width / Self.size.height
            let shown = min(1, (CGFloat(first.image.width) / tileAspect) / CGFloat(max(first.image.height, 1)))
            imageLayerView.layer?.contentsRect = CGRect(x: 0, y: 1 - shown, width: 1, height: shown)
        } else {
            imageLayerView.layer?.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }
}

/// The list that opens from the group tile: every pinned preview, with Unpin All in the corner.
@MainActor
private final class PinnedMenu: NSObject {
    let panel: NSPanel
    private let screen: NSScreen
    private var anchor: NSRect
    private var items: [QuickAccessItem] = []
    private var monitors: [Any] = []
    private let onTogglePin: (QuickAccessItem) -> Void
    private let onUnpinAll: () -> Void
    private let onDeleteAll: () -> Void
    private let onClose: () -> Void
    private let ignoring: NSWindow

    private static let thumbWidth: CGFloat = 250
    private static let buttonColumn: CGFloat = 70
    private static let margin: CGFloat = 30 // room around the glass for its shadow

    init(screen: NSScreen, anchor: NSRect, ignoring: NSWindow,
         onTogglePin: @escaping (QuickAccessItem) -> Void, onUnpinAll: @escaping () -> Void, onDeleteAll: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.screen = screen
        self.anchor = anchor
        self.ignoring = ignoring
        self.onTogglePin = onTogglePin
        self.onUnpinAll = onUnpinAll
        self.onDeleteAll = onDeleteAll
        self.onClose = onClose
        panel = Glass.panel(frame: .zero, level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
        super.init()
    }

    func show(items: [QuickAccessItem]) {
        reload(items: items, anchor: anchor)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            if let self, event.window !== self.panel, event.window !== self.ignoring { self.close() }
            return event
        }) { monitors.append(m) }
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 },
                                             completionHandler: { Task { @MainActor in panel.orderOut(nil) } })
        onClose()
    }

    func reload(items: [QuickAccessItem], anchor: NSRect) {
        self.items = items
        self.anchor = anchor
        let visible = screen.visibleFrame

        let anyPinned = items.contains { $0.pinned }
        let title = glassLabel(groupTitle(for: items), size: 14, weight: .semibold)
        let unpinAll = Glass.button("Unpin All", symbol: "pin.slash.fill", size: .small, target: self, action: #selector(unpinAllTapped))
        unpinAll.toolTip = "Unpin every preview"
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let deleteAll = Glass.button("Delete All", symbol: "trash", size: .small, target: self, action: #selector(deleteAllTapped))
        deleteAll.toolTip = "Discard every preview without saving"
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.lineBreakMode = .byClipping
        let header = NSStackView(views: (anyPinned ? [title, spacer, unpinAll, deleteAll] : [title, spacer, deleteAll]))
        header.spacing = 6
        header.alignment = .centerY

        let rows = NSStackView(views: items.map { row(for: $0) })
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: doc.topAnchor),
            rows.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            rows.widthAnchor.constraint(equalToConstant: Self.thumbWidth + 12 + Self.buttonColumn),
            rows.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        let rowsWidth = Self.thumbWidth + 12 + Self.buttonColumn
        let rowsHeight = items.reduce(CGFloat(0)) { $0 + thumbHeight(for: $1) } + 12 * CGFloat(max(0, items.count - 1))
        let inset: CGFloat = 14
        let headerHeight: CGFloat = 28
        let maxHeight = visible.height - 32
        let scrollHeight = min(rowsHeight, maxHeight - 2 * inset - headerHeight - 10)

        // When the list scrolls, leave a strip on the right for the scroll bar so it never sits over a button.
        let gutter: CGFloat = rowsHeight > scrollHeight ? 14 : 0
        let contentWidth = rowsWidth + gutter

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = rowsHeight > scrollHeight
        scroll.scrollerStyle = .overlay
        scroll.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.addSubview(doc)
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])

        let column = NSStackView(views: [header, scroll])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: scrollHeight).isActive = true

        let surfaceSize = NSSize(width: contentWidth + 2 * inset, height: headerHeight + 10 + scrollHeight + 2 * inset)
        let surface = Glass.surface(column, cornerRadius: 24, insets: NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset))
        let root = NSView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(surface)
        let m = Self.margin
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            surface.topAnchor.constraint(equalTo: root.topAnchor, constant: m),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -m),
        ])
        panel.contentView = root

        // Beside the group tile, on the side facing the middle of the screen, kept fully on screen.
        let onRight = anchor.midX > visible.midX
        let x = onRight ? anchor.minX - 12 - surfaceSize.width : anchor.maxX + 12
        let y = min(max(anchor.midY - surfaceSize.height / 2, visible.minY + 16), visible.maxY - 16 - surfaceSize.height)
        panel.setFrame(NSRect(x: x - m, y: y - m, width: surfaceSize.width + 2 * m, height: surfaceSize.height + 2 * m), display: true)
    }

    private func thumbHeight(for item: QuickAccessItem) -> CGFloat {
        let ratio = CGFloat(item.image.height) / CGFloat(max(item.image.width, 1))
        // A text card keeps its full shape so none of the text is cut off; pictures are held to a short strip.
        if item.isText { return (Self.thumbWidth * ratio).rounded() }
        return min(max((Self.thumbWidth * ratio).rounded(), 64), 140)
    }

    private func row(for item: QuickAccessItem) -> NSView {
        let thumb = OverlayContentView()
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 12
        thumb.layer?.cornerCurve = .continuous
        thumb.layer?.masksToBounds = true
        thumb.layer?.contents = item.image
        thumb.layer?.contentsGravity = .resizeAspectFill
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        if item.canEdit { thumb.onClick = { [weak item] in item?.editTapped() } } // text has nothing to edit, and editing closes the preview
        thumb.onDrag = { [weak item, weak thumb] event in
            guard let item, let thumb else { return }
            item.beginDrag(with: event, from: thumb)
        }
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.widthAnchor.constraint(equalToConstant: Self.thumbWidth).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: thumbHeight(for: item)).isActive = true

        let index = items.firstIndex { $0 === item } ?? 0
        func tag(_ b: PillButton, _ action: String, width: CGFloat) -> PillButton {
            b.key = action
            b.tag = index
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: width).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            return b
        }
        let copy = tag(Glass.button("Copy", prominent: item.isText, size: .small, target: self, action: #selector(rowAction(_:))), "copy", width: Self.buttonColumn)
        let save = tag(Glass.button("Save", prominent: true, size: .small, target: self, action: #selector(rowAction(_:))), "save", width: Self.buttonColumn)
        let unpin = tag(Glass.iconButton(item.pinned ? "pin.slash.fill" : "pin.fill", tip: item.pinned ? "Unpin" : "Pin", target: self, action: #selector(rowAction(_:))), "pin", width: 30)
        let dismiss = tag(Glass.iconButton("xmark", tip: "Dismiss without saving", target: self, action: #selector(rowAction(_:))), "dismiss", width: 30)
        let icons = NSStackView(views: [unpin, dismiss])
        icons.spacing = 10
        let buttons = NSStackView(views: item.isText ? [copy, icons] : [copy, save, icons]) // text can only be copied
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 8

        let row = NSStackView(views: [thumb, buttons])
        row.alignment = .top
        row.spacing = 12
        return row
    }

    /// A pinned preview cannot be dismissed; its button shakes instead.
    private func shake(_ view: NSView) {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -6, 6, -4, 4, -2, 2, 0]
        a.duration = 0.35
        view.wantsLayer = true
        view.layer?.add(a, forKey: "shake")
    }

    @objc private func unpinAllTapped() { onUnpinAll() }
    @objc private func deleteAllTapped() { onDeleteAll() }

    @objc private func rowAction(_ sender: PillButton) {
        guard items.indices.contains(sender.tag) else { return }
        let item = items[sender.tag]
        switch sender.key {
        case "copy": item.copyTapped()
        case "save": item.saveTapped()
        case "pin": onTogglePin(item)
        default:
            if item.pinned { shake(sender) } else { item.dismissTapped() }
        }
    }
}

// MARK: Manager

@MainActor
final class QuickAccess {
    static let shared = QuickAccess()

    private var items: [QuickAccessItem] = []
    private var groups: [ObjectIdentifier: PinnedGroupTile] = [:]
    private var menu: PinnedMenu?
    private var menuScreen: NSScreen?
    private let margin: CGFloat = 16
    private let gap: CGFloat = 10

    private struct Layout {
        var frames: [ObjectIdentifier: NSRect] = [:]
        var folded: Set<ObjectIdentifier> = []
        var groupFrames: [ObjectIdentifier: NSRect] = [:]
        /// What each group tile holds, newest first (pinned ones first).
        var groupItems: [ObjectIdentifier: [QuickAccessItem]] = [:]
    }

    /// Previews always appear on the main display (the one with the menu bar), whichever display the capture was made on.
    /// `scale` is the pixel density of the display the picture came from; it defaults to the display the pointer is on.
    func present(_ image: CGImage, scale: CGFloat? = nil, showingActions: Bool = false, pinned: Bool = false, savedURL: URL? = nil, media: PreviewMedia = .image) {
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let captureScale = scale ?? CaptureService.screenUnderMouse().backingScaleFactor

        let item = QuickAccessItem(
            image: image,
            media: media,
            screen: screen,
            captureScale: captureScale,
            onDone: { [weak self] done in
                self?.finish(done)
            },
            onEdit: { [weak self] done in
                self?.finish(done)
                switch done.media {
                case .image: Editor.open(done.image, scale: done.captureScale)
                case .video(let url): VideoEditor.open(url)
                case .gif, .text: break
                }
            }
        )
        item.onTogglePin = { [weak self] in self?.togglePin($0) }
        item.savedURL = savedURL
        item.pinned = pinned
        items.append(item)

        let layout = computeLayout()
        // A preview that arrives already pinned while the stack is full goes straight into the group tile, not on screen.
        if layout.folded.contains(ObjectIdentifier(item)) {
            item.hiddenInGroup = true
            item.setPlaying(false)
            apply(layout, skipping: nil)
            return
        }
        let target = layout.frames[ObjectIdentifier(item)] ?? .zero
        item.restFrame = target
        let slide = (target.width + margin + 20) * (isRight ? 1 : -1)
        item.panel.setFrame(target.offsetBy(dx: slide, dy: 0), display: false)
        item.panel.alphaValue = 0
        item.panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            item.panel.animator().setFrame(target, display: true)
            item.panel.animator().alphaValue = 1
        }, completionHandler: { [weak item] in
            // A desktop switch in the middle of the slide-in can freeze it half-way; whatever happened, the card ends up shown.
            MainActor.assumeIsolated {
                guard let item, !item.hiddenInGroup, !item.isExpanded else { return }
                item.panel.alphaValue = 1
                item.panel.orderFrontRegardless()
            }
        })
        apply(layout, skipping: item)
        if showingActions {
            // Show Copy / Save right away, as if the pointer were over it; moving the pointer in and out works as usual.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { item.simulateHover() }
        }
    }

    private var healWork: DispatchWorkItem?

    /// After a desktop switch, an app switch or a display change, macOS can leave a floating panel hidden or half-faded.
    /// Everything that should be showing is put back in its place, fully visible, in front.
    func healAfterSpaceChange() {
        healWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let layout = self.computeLayout()
            for item in self.items where !item.hiddenInGroup && !layout.folded.contains(ObjectIdentifier(item)) {
                item.collapse(animated: false)
                if let frame = layout.frames[ObjectIdentifier(item)] { item.panel.setFrame(frame, display: true) }
                item.panel.alphaValue = 1
                item.panel.orderFrontRegardless()
            }
            for tile in self.groups.values {
                tile.panel.alphaValue = 1
                tile.panel.orderFrontRegardless()
            }
        }
        healWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Shows text read from the screen as a preview card in the same corner. Copy puts the whole text on the clipboard.
    func presentText(_ text: String) {
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let scale = screen.backingScaleFactor
        guard let image = TextCard.render(text, size: TextCard.collapsedSize(for: text), scale: scale) else { return }
        present(image, scale: scale, media: .text(text))
    }

    /// Shows a finished recording as a preview that plays in the card. The file is already saved.
    func presentMedia(_ url: URL, isGIF: Bool, scale: CGFloat? = nil, showingActions: Bool = false) {
        Task {
            guard let poster = await Self.poster(for: url, isGIF: isGIF) else { return }
            present(poster, scale: isGIF ? 1 : scale, showingActions: showingActions, savedURL: url, media: isGIF ? .gif(url) : .video(url))
        }
    }

    private static func poster(for url: URL, isGIF: Bool) async -> CGImage? {
        if isGIF {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        return try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
    }

    /// Pins a saved picture (from the history window) as a preview in the corner stack. Pinning the same file twice does nothing new.
    func pinFile(_ url: URL) {
        if let existing = items.first(where: { $0.savedURL == url }) {
            if !existing.pinned { togglePin(existing) }
            return
        }
        guard let nsImage = NSImage(contentsOf: url),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Alerts.show(title: "Could not pin the image", message: "Tack could not read “\(url.lastPathComponent)”.")
            return
        }
        // Points per pixel from the file itself, so a screenshot keeps the size it was taken at.
        let scale = nsImage.size.width > 0 ? max(1, CGFloat(cg.width) / nsImage.size.width) : nil
        present(cg, scale: scale, pinned: true, savedURL: url)
    }

    /// Developer aids for the demo mode.
    func openGroupMenuForTesting() {
        guard let screen = NSScreen.screens.first else { return }
        let hadTile = groups[ObjectIdentifier(screen)] != nil
        let before = menu != nil
        toggleMenu(on: screen)
        print("menu test: tile=\(hadTile) menuBefore=\(before) menuAfter=\(menu != nil) visible=\(menu?.panel.isVisible ?? false) frame=\(menu?.panel.frame ?? .zero)")
    }
    func pinNewestForTesting(_ count: Int) { items.suffix(count).forEach { $0.pinned = true }; relayout() }
    var itemCountForTesting: Int { items.count }
    func deleteAllForTesting() { if let screen = NSScreen.screens.first { deleteAll(on: screen) } }
    /// Sizes of the round buttons on the newest preview, for the self-test.
    func buttonSizesForTesting() -> [NSSize] {
        guard let content = items.last?.panel.contentView else { return [] }
        content.layoutSubtreeIfNeeded()
        var found: [NSSize] = []
        func walk(_ v: NSView) {
            if let b = v as? PillButton, b.iconOnly { found.append(b.frame.size) }
            v.subviews.forEach(walk)
        }
        walk(content)
        return found
    }

    func debugFramesForTesting() -> String {
        let frames = items.map { "item \(Int($0.panel.frame.minX)),\(Int($0.panel.frame.minY)) \(Int($0.size.width))x\(Int($0.size.height)) hidden=\($0.hiddenInGroup) visible=\($0.panel.isVisible)" }
        let tiles = groups.values.map { "tile \(Int($0.panel.frame.minX)),\(Int($0.panel.frame.minY)) visible=\($0.panel.isVisible)" }
        return (frames + tiles).joined(separator: "; ")
    }
    func removeLastForTesting() { if let last = items.last { finish(last) } }

    /// For the self-test: the card size for each "Size" setting, for a picture of the given shape.
    func cardSizesForTesting(_ image: CGImage) -> [NSSize] {
        let old = UserDefaults.standard.string(forKey: PrefKey.overlaySize)
        defer { UserDefaults.standard.set(old, forKey: PrefKey.overlaySize) }
        var sizes: [NSSize] = []
        for setting in ["small", "medium", "large"] {
            UserDefaults.standard.set(setting, forKey: PrefKey.overlaySize)
            let before = items.count
            present(image)
            if items.count > before, let item = items.last {
                sizes.append(item.size)
                finish(item)
            }
        }
        return sizes
    }

    func simulateHoverForTesting() { items.forEach { $0.simulateHover() } }

    /// For the self-test: stacking, folding and unfolding. Cleans up after itself.
    func pinningCheckForTesting(_ image: CGImage) -> (outermost: Bool, folded: Bool, newestVisible: Bool, unfolded: Bool, pinnedStaysOnDismiss: Bool, pinnedWhenFullHidden: Bool) {
        let before = items.count
        func mine() -> [QuickAccessItem] { Array(items.suffix(items.count - before)) }

        // A new screenshot takes the corner slot; a pinned one moves beyond it.
        present(image)
        let first = items.last!
        first.pinned = true
        present(image)
        let layout = computeLayout()
        let a = layout.frames[ObjectIdentifier(items.last!)]!, b = layout.frames[ObjectIdentifier(first)]!
        let outermost = isTop ? b.maxY < a.minY : b.minY > a.maxY

        // X on a pinned preview does nothing but shake.
        first.dismissTapped()
        let pinnedStaysOnDismiss = items.contains { $0 === first }

        // A full stack folds everything, pinned or not, but keeps the newest screenshot in view.
        for _ in 0..<14 { present(image) }
        let full = computeLayout()
        let folded = !full.groupFrames.isEmpty && (full.groupItems.values.first?.count ?? 0) >= 2
        let newestVisible = !full.folded.contains(ObjectIdentifier(items.last!))

        // A preview that arrives already pinned while the stack is full goes into the group, not on top of it.
        present(image, pinned: true)
        let pinnedWhenFullHidden = items.last?.hiddenInGroup == true && items.last?.panel.isVisible == false

        for item in mine().dropFirst(3) { finish(item) }
        let unfolded = computeLayout().groupFrames.isEmpty
        for item in mine() { finish(item) }
        return (outermost, folded, newestVisible, unfolded, pinnedStaysOnDismiss, pinnedWhenFullHidden)
    }

    private var corner: String { UserDefaults.standard.string(forKey: PrefKey.overlayCorner) ?? "bottomLeft" }
    private var isRight: Bool { corner.hasSuffix("Right") }
    private var isTop: Bool { corner.hasPrefix("top") }

    // MARK: Layout

    private func rect(size: NSSize, offset: CGFloat, in visible: NSRect) -> NSRect {
        let x = isRight ? visible.maxX - margin - size.width : visible.minX + margin
        let y = isTop ? visible.maxY - offset - size.height : visible.minY + offset
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    /// Previews that are not pinned sit in the corner (newest outermost). Pinned previews stack beyond them, so a new
    /// screenshot always lands in the usual spot and the pinned ones slide away from it. If the stack would run past the
    /// top of the screen, the pinned previews fold into one group tile.
    private func computeLayout() -> Layout {
        var layout = Layout()
        var screens: [NSScreen] = []
        for item in items where !screens.contains(where: { $0 === item.screen }) { screens.append(item.screen) }

        for screen in screens {
            let visible = screen.visibleFrame
            let mine = items.filter { $0.screen === screen }
            let normal = mine.filter { !$0.pinned }
            let pinned = mine.filter { $0.pinned }.sorted { $0.pinOrder > $1.pinOrder } // newest pin nearest the corner
            let needed = mine.reduce(CGFloat(0)) { $0 + $1.size.height } + gap * CGFloat(max(0, mine.count - 1))
            // Out of room: everything folds into one group tile, except the screenshot just taken, which stays in view.
            let keep = (mine.last?.pinned == false) ? mine.last : nil
            let folded = mine.filter { $0 !== keep }
            let fold = folded.count >= 2 && needed > visible.height - 2 * margin

            var offset = margin
            if fold {
                if let keep {
                    layout.frames[ObjectIdentifier(keep)] = rect(size: keep.size, offset: offset, in: visible)
                    offset += keep.size.height + gap
                }
                let frame = rect(size: PinnedGroupTile.size, offset: offset, in: visible)
                layout.groupFrames[ObjectIdentifier(screen)] = frame
                layout.groupItems[ObjectIdentifier(screen)] = folded.filter { $0.pinned }.sorted { $0.pinOrder > $1.pinOrder }
                    + folded.filter { !$0.pinned }.reversed()
                for item in folded {
                    layout.frames[ObjectIdentifier(item)] = frame
                    layout.folded.insert(ObjectIdentifier(item))
                }
            } else {
                for item in normal {
                    layout.frames[ObjectIdentifier(item)] = rect(size: item.size, offset: offset, in: visible)
                    offset += item.size.height + gap
                }
                for item in pinned {
                    layout.frames[ObjectIdentifier(item)] = rect(size: item.size, offset: offset, in: visible)
                    offset += item.size.height + gap
                }
            }
        }
        return layout
    }

    private func relayout() { apply(computeLayout(), skipping: nil) }

    private func apply(_ layout: Layout, skipping: QuickAccessItem?) {
        items.forEach { $0.collapse(animated: false) } // a card that grew under the pointer goes back before the stack moves
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            for item in items where item !== skipping {
                let id = ObjectIdentifier(item)
                guard let frame = layout.frames[id] else { continue }
                if !layout.folded.contains(id) { item.restFrame = frame }
                let panel = item.panel
                if layout.folded.contains(id) {
                    if item.hiddenInGroup {
                        panel.setFrame(frame, display: false)
                    } else {
                        item.hiddenInGroup = true
                        item.setPlaying(false)
                        panel.animator().setFrame(frame, display: true)
                        panel.animator().alphaValue = 0
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            if item.hiddenInGroup { panel.orderOut(nil) }
                        }
                    }
                } else if item.hiddenInGroup {
                    item.hiddenInGroup = false
                    item.setPlaying(true)
                    panel.setFrame(frame, display: false)
                    panel.alphaValue = 0
                    panel.orderFrontRegardless()
                    panel.animator().alphaValue = 1
                } else {
                    panel.animator().setFrame(frame, display: true)
                }
            }

            for (id, frame) in layout.groupFrames {
                guard let screen = items.first(where: { ObjectIdentifier($0.screen) == id })?.screen else { continue }
                let pinned = layout.groupItems[id] ?? []
                if let tile = groups[id] {
                    tile.panel.animator().setFrame(frame, display: true)
                    tile.update(items: pinned)
                } else {
                    let tile = PinnedGroupTile()
                    tile.update(items: pinned)
                    tile.onClick = { [weak self] in self?.toggleMenu(on: screen) }
                    tile.panel.setFrame(frame, display: false)
                    tile.panel.alphaValue = 0
                    tile.panel.orderFrontRegardless()
                    tile.panel.animator().alphaValue = 1
                    groups[id] = tile
                }
            }
        }

        for (id, tile) in groups where layout.groupFrames[id] == nil {
            groups[id] = nil
            let panel = tile.panel
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 },
                                                 completionHandler: { Task { @MainActor in panel.orderOut(nil) } })
            // The completion handler can be skipped when another animation overlaps this one, so make sure it goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { panel.orderOut(nil) }
        }
        scheduleSettle()
        // After the current click finishes, so a list is never rebuilt under the button that was pressed.
        DispatchQueue.main.async { [weak self] in self?.refreshMenu(layout) }
    }

    /// Window animations that overlap (several previews closing at once) can leave a window part-way along its move.
    /// A moment after the last change, put everything exactly where the layout says, without animating.
    private var settleWork: DispatchWorkItem?

    private func scheduleSettle() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func settle() {
        let layout = computeLayout()
        func differs(_ a: NSRect, _ b: NSRect) -> Bool {
            abs(a.minX - b.minX) > 1 || abs(a.minY - b.minY) > 1 || abs(a.width - b.width) > 1 || abs(a.height - b.height) > 1
        }
        for item in items where !item.hiddenInGroup {
            if let frame = layout.frames[ObjectIdentifier(item)], differs(item.panel.frame, frame) {
                item.panel.setFrame(frame, display: true)
            }
        }
        for (id, frame) in layout.groupFrames {
            if let tile = groups[id], differs(tile.panel.frame, frame) { tile.panel.setFrame(frame, display: true) }
        }
    }

    // MARK: Pinning

    private func togglePin(_ item: QuickAccessItem) {
        item.pinned.toggle()
        relayout()
    }

    /// Discards every preview in the group without saving them.
    private func deleteAll(on screen: NSScreen) {
        for item in computeLayout().groupItems[ObjectIdentifier(screen)] ?? [] { finish(item) }
    }

    private func unpinAll(on screen: NSScreen) {
        for item in items where item.screen === screen { item.pinned = false }
        relayout()
    }


    private func toggleMenu(on screen: NSScreen) {
        if menu != nil { menu?.close(); return }
        guard let tile = groups[ObjectIdentifier(screen)] else { return }
        let menu = PinnedMenu(
            screen: screen,
            anchor: tile.panel.frame,
            ignoring: tile.panel,
            onTogglePin: { [weak self] item in self?.togglePin(item) },
            onUnpinAll: { [weak self] in self?.unpinAll(on: screen) },
            onDeleteAll: { [weak self] in self?.deleteAll(on: screen) },
            onClose: { [weak self] in self?.menu = nil; self?.menuScreen = nil }
        )
        self.menu = menu
        menuScreen = screen
        menu.show(items: computeLayout().groupItems[ObjectIdentifier(screen)] ?? [])
    }

    /// Keeps an open list in step with the pinned previews, and closes it when there is no group left to open it from.
    private func refreshMenu(_ layout: Layout) {
        guard let menu, let screen = menuScreen else { return }
        guard let frame = layout.groupFrames[ObjectIdentifier(screen)] else { menu.close(); return }
        let list = layout.groupItems[ObjectIdentifier(screen)] ?? []
        if list.isEmpty { menu.close() } else { menu.reload(items: list, anchor: frame) }
    }

    private func finish(_ item: QuickAccessItem) {
        guard let index = items.firstIndex(where: { $0 === item }) else { return }
        items.remove(at: index)

        let panel = item.panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                item.stopMedia()
            }
        })
        relayout()
    }
}
