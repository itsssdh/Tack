import AppKit
import CoreImage

// MARK: Tools

enum AnnotationKind {
    case arrow, line, rectangle, filledRect, ellipse, freehand, highlighter
    case text, counter, blur, pixelate, redact, spotlight
}

enum EditorTool: Int, CaseIterable {
    case select, arrow, line, rectangle, filledRect, ellipse, freehand, highlighter
    case text, counter, blur, pixelate, redact, spotlight, crop, eraser

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .filledRect: return "rectangle.fill"
        case .ellipse: return "circle"
        case .freehand: return "scribble"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .blur: return "drop"
        case .pixelate: return "square.grid.3x3"
        case .redact: return "eye.slash"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        case .eraser: return "eraser"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select and move (Delete removes)"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle outline"
        case .filledRect: return "Filled rectangle"
        case .ellipse: return "Ellipse"
        case .freehand: return "Freehand pen"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .counter: return "Numbered counter"
        case .blur: return "Blur (not secure, use Redact for secrets)"
        case .pixelate: return "Pixelate (not secure, use Redact for secrets)"
        case .redact: return "Redact (solid black box, fully opaque)"
        case .spotlight: return "Spotlight (dims everything outside)"
        case .crop: return "Crop"
        case .eraser: return "Eraser (click an annotation to remove it)"
        }
    }

    var kind: AnnotationKind? {
        switch self {
        case .arrow: return .arrow
        case .line: return .line
        case .rectangle: return .rectangle
        case .filledRect: return .filledRect
        case .ellipse: return .ellipse
        case .freehand: return .freehand
        case .highlighter: return .highlighter
        case .blur: return .blur
        case .pixelate: return .pixelate
        case .redact: return .redact
        case .spotlight: return .spotlight
        case .select, .text, .counter, .crop, .eraser: return nil
        }
    }
}

// MARK: Drawing helpers

enum Gfx {
    /// Draws an image upright into a context whose y axis points down.
    static func draw(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    static func bitmap(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Runs `body` with a y-down NSGraphicsContext on a new bitmap and returns the result.
    static func render(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = bitmap(width: width, height: height) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

/// Blur and pixelate are computed from the original pixels and cached so dragging stays smooth.
final class EffectCache: @unchecked Sendable {
    static let shared = EffectCache()
    private var store: [String: CGImage] = [:]
    private let lock = NSLock()
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func image(key: String, make: () -> CGImage?) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let hit = store[key] { return hit }
        guard let made = make() else { return nil }
        if store.count > 150 { store.removeAll() }
        store[key] = made
        return made
    }

    func render(_ ci: CIImage, from extent: CGRect) -> CGImage? {
        context.createCGImage(ci, from: extent)
    }
}

// MARK: Annotation

/// All coordinates are image pixels with the origin at the top-left.
struct Annotation {
    let id = UUID()
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var lineWidth: CGFloat
    var fontSize: CGFloat = 0
    var text: String = ""
    var number: Int = 0

    init(kind: AnnotationKind, start: CGPoint, end: CGPoint, color: NSColor, lineWidth: CGFloat) {
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
    }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: color]
    }

    private var counterRadius: CGFloat { max(fontSize, lineWidth * 5) * 0.75 }

    var bounds: CGRect {
        switch kind {
        case .text:
            return CGRect(origin: start, size: (text as NSString).size(withAttributes: textAttributes))
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .arrow, .line:
            return rect.insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        case .freehand, .highlighter:
            guard let first = points.first else { return rect }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            let pad = kind == .highlighter ? lineWidth * 2 : lineWidth
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -pad, dy: -pad)
        case .rectangle, .filledRect, .ellipse, .blur, .pixelate, .redact, .spotlight:
            return rect
        }
    }

    mutating func move(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        for i in points.indices { points[i].x += dx; points[i].y += dy }
    }

    func hit(_ p: CGPoint, tolerance t: CGFloat) -> Bool {
        switch kind {
        case .arrow, .line:
            return Annotation.distance(from: p, toSegmentFrom: start, to: end) <= t
        case .freehand, .highlighter:
            if points.count < 2 { return bounds.contains(p) }
            for i in 1..<points.count where Annotation.distance(from: p, toSegmentFrom: points[i - 1], to: points[i]) <= t + lineWidth {
                return true
            }
            return false
        default:
            return bounds.insetBy(dx: -t / 2, dy: -t / 2).contains(p)
        }
    }

    private static func distance(from p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Draws into the current NSGraphicsContext, which must be y-down, in image pixels.
    func draw(base: CGImage) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        switch kind {
        case .rectangle:
            let path = NSBezierPath(rect: rect)
            path.lineWidth = lineWidth
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        case .filledRect:
            color.setFill()
            NSBezierPath(rect: rect).fill()
        case .ellipse:
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = lineWidth
            color.setStroke()
            path.stroke()
        case .line:
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
        case .arrow:
            drawArrow()
        case .freehand, .highlighter:
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: points[0])
            for p in points.dropFirst() { path.line(to: p) }
            path.lineJoinStyle = .round
            if kind == .highlighter {
                path.lineWidth = lineWidth * 4
                path.lineCapStyle = .butt
                color.withAlphaComponent(0.4).setStroke()
            } else {
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                color.setStroke()
            }
            path.stroke()
        case .text:
            (text as NSString).draw(at: start, withAttributes: textAttributes)
        case .counter:
            let r = counterRadius
            let circle = CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()
            let label = "\(number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.15, weight: .bold),
                .foregroundColor: Annotation.contrastingText(for: color),
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2), withAttributes: attrs)
        case .redact:
            // Fully opaque and pixel-aligned so no edge pixel stays partly visible.
            NSColor.black.setFill()
            NSBezierPath(rect: rect.integral).fill()
        case .blur, .pixelate:
            drawEffect(base: base, ctx: ctx)
        case .spotlight:
            let full = CGRect(x: 0, y: 0, width: CGFloat(base.width), height: CGFloat(base.height))
            let path = NSBezierPath(rect: full)
            path.append(NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10))
            path.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.6).setFill()
            path.fill()
        }
    }

    private static func contrastingText(for color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let luma = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luma > 0.6 ? .black : .white
    }

    private func drawEffect(base: CGImage, ctx: CGContext) {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard r.width >= 2, r.height >= 2 else { return }
        let strength = max(6, lineWidth * (kind == .blur ? 3 : 3.5))
        let key = "\(kind)-\(ObjectIdentifier(base as AnyObject).hashValue)-\(r.minX),\(r.minY),\(r.width),\(r.height)-\(strength)"
        let isBlur = kind == .blur
        let result = EffectCache.shared.image(key: key) {
            guard let crop = base.cropping(to: r) else { return nil }
            let ci = CIImage(cgImage: crop)
            let out: CIImage
            if isBlur {
                out = ci.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: strength])
                    .cropped(to: ci.extent)
            } else {
                out = ci.applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: strength,
                    kCIInputCenterKey: CIVector(x: 0, y: 0),
                ]).cropped(to: ci.extent)
            }
            return EffectCache.shared.render(out, from: ci.extent)
        }
        if let result { Gfx.draw(result, in: r, ctx: ctx) }
    }

    private func drawArrow() {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let angle = atan2(dy, dx)
        let headLength = min(length * 0.6, max(lineWidth * 4.5, 16))
        let halfWidth = headLength * 0.5
        let cosA = cos(angle)
        let sinA = sin(angle)

        let base = CGPoint(x: end.x - cosA * headLength * 0.8, y: end.y - sinA * headLength * 0.8)
        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: base)
        line.lineWidth = lineWidth
        line.lineCapStyle = .round
        color.setStroke()
        line.stroke()

        let left = CGPoint(x: end.x - cosA * headLength + sinA * halfWidth, y: end.y - sinA * headLength - cosA * halfWidth)
        let right = CGPoint(x: end.x - cosA * headLength - sinA * halfWidth, y: end.y - sinA * headLength + cosA * halfWidth)
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: left)
        head.line(to: right)
        head.close()
        color.setFill()
        head.fill()
    }
}

// MARK: Backdrop (background behind the screenshot)

enum Backdrop: String, CaseIterable {
    case none, white, black, gray, ocean, sunset, lavender, mint, forest

    var title: String {
        switch self {
        case .none: return "No background"
        case .white: return "White"
        case .black: return "Black"
        case .gray: return "Gray"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        case .lavender: return "Lavender"
        case .mint: return "Mint"
        case .forest: return "Forest"
        }
    }

    var colors: [NSColor] {
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        switch self {
        case .none: return []
        case .white: return [c(0xFFFFFF)]
        case .black: return [c(0x111111)]
        case .gray: return [c(0xE5E7EB)]
        case .ocean: return [c(0x2563EB), c(0x06B6D4)]
        case .sunset: return [c(0xF97316), c(0xEC4899)]
        case .lavender: return [c(0x8B5CF6), c(0xEC4899)]
        case .mint: return [c(0x34D399), c(0x3B82F6)]
        case .forest: return [c(0x065F46), c(0x84CC16)]
        }
    }

    func fill(_ rect: CGRect, ctx: CGContext) {
        let cols = colors
        guard let first = cols.first else { return }
        if cols.count == 1 {
            ctx.setFillColor(first.cgColor)
            ctx.fill(rect)
            return
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        guard let gradient = CGGradient(colorsSpace: space, colors: cols.map { $0.cgColor } as CFArray, locations: nil) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
}

struct DocStyle {
    var backdrop: Backdrop = .none
    var padding: CGFloat = 0   // pixels, only used when there is a backdrop
    var rounded = true
    var shadow = true
    var unit: CGFloat = 2

    var effectivePadding: CGFloat { backdrop == .none ? 0 : padding }
    var cornerRadius: CGFloat { backdrop == .none ? 0 : (rounded ? 12 * unit : 0) }
}

struct EditState {
    var base: CGImage
    var annotations: [Annotation] = []
}

enum DocRenderer {
    static func size(of state: EditState, style: DocStyle) -> CGSize {
        let pad = style.effectivePadding
        return CGSize(width: CGFloat(state.base.width) + 2 * pad, height: CGFloat(state.base.height) + 2 * pad)
    }

    /// Draws background, image and annotations into the current y-down graphics context.
    static func draw(state: EditState, style: DocStyle, ctx: CGContext) {
        let pad = style.effectivePadding
        let w = CGFloat(state.base.width)
        let h = CGFloat(state.base.height)
        let doc = CGRect(x: 0, y: 0, width: w + 2 * pad, height: h + 2 * pad)
        let imageRect = CGRect(x: pad, y: pad, width: w, height: h)
        let radius = style.cornerRadius

        style.backdrop.fill(doc, ctx: ctx)

        let shape = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if style.backdrop != .none && style.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 30 * style.unit, color: CGColor(gray: 0, alpha: 0.5))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(shape)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        Gfx.draw(state.base, in: imageRect, ctx: ctx)
        ctx.translateBy(x: pad, y: pad)
        for a in state.annotations { a.draw(base: state.base) }
        ctx.restoreGState()
    }

    static func render(state: EditState, style: DocStyle) -> CGImage? {
        if state.annotations.isEmpty && style.backdrop == .none { return state.base }
        let size = size(of: state, style: style)
        return Gfx.render(width: Int(size.width), height: Int(size.height)) { ctx in
            draw(state: state, style: style, ctx: ctx)
        }
    }

    /// Bakes annotations into the pixels (no background). Used before rotate / crop / resize.
    static func flatten(_ state: EditState) -> CGImage {
        if state.annotations.isEmpty { return state.base }
        return render(state: state, style: DocStyle()) ?? state.base
    }
}

// MARK: Pixel operations

enum ImageOps {
    static func transformed(_ image: CGImage, _ t: CGAffineTransform, newSize: CGSize) -> CGImage? {
        guard let ctx = Gfx.bitmap(width: Int(newSize.width), height: Int(newSize.height)) else { return nil }
        ctx.interpolationQuality = .high
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    static func rotateRight(_ img: CGImage) -> CGImage? {
        transformed(img, CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(img.width)),
                    newSize: CGSize(width: img.height, height: img.width))
    }

    static func rotateLeft(_ img: CGImage) -> CGImage? {
        transformed(img, CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(img.height), ty: 0),
                    newSize: CGSize(width: img.height, height: img.width))
    }

    static func flipHorizontal(_ img: CGImage) -> CGImage? {
        transformed(img, CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(img.width), ty: 0),
                    newSize: CGSize(width: img.width, height: img.height))
    }

    static func flipVertical(_ img: CGImage) -> CGImage? {
        transformed(img, CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(img.height)),
                    newSize: CGSize(width: img.width, height: img.height))
    }

    static func resized(_ img: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = Gfx.bitmap(width: width, height: height) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Puts `other` below or to the right of `img`, scaled to match the shared edge.
    static func combined(_ img: CGImage, with other: CGImage, below: Bool) -> CGImage? {
        let w1 = CGFloat(img.width), h1 = CGFloat(img.height)
        var w2 = CGFloat(other.width), h2 = CGFloat(other.height)
        if below {
            let s = w1 / w2; w2 = w1; h2 = (h2 * s).rounded()
        } else {
            let s = h1 / h2; h2 = h1; w2 = (w2 * s).rounded()
        }
        let total = below ? CGSize(width: w1, height: h1 + h2) : CGSize(width: w1 + w2, height: h1)
        return Gfx.render(width: Int(total.width), height: Int(total.height)) { ctx in
            Gfx.draw(img, in: CGRect(x: 0, y: 0, width: w1, height: h1), ctx: ctx)
            let origin = below ? CGPoint(x: 0, y: h1) : CGPoint(x: w1, y: 0)
            Gfx.draw(other, in: CGRect(origin: origin, size: CGSize(width: w2, height: h2)), ctx: ctx)
        }
    }
}
