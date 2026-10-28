import AppKit

/// Tack's own icon: a dark tile with white capture-frame corners and one orange dot.
/// Drawn in code; build_app.sh turns it into Tack.icns by running the app with --make-icon.
enum AppIcon {
    /// Draws into a context sized `size` x `size` pixels with the origin at the bottom-left.
    static func draw(in ctx: CGContext, size: CGFloat) {
        let s = size / 1024
        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 188, cornerHeight: 188, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.4))
        ctx.addPath(tilePath)
        ctx.setFillColor(rgb(0x16161B))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()
        let bg = CGGradient(colorsSpace: space, colors: [rgb(0x2A2A32), rgb(0x131318)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()

        ctx.addPath(tilePath)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
        ctx.setLineWidth(3)
        ctx.strokePath()

        // Capture frame: four rounded corner brackets
        let frame = CGRect(x: 262, y: 262, width: 500, height: 500)
        let arm: CGFloat = 150
        ctx.setStrokeColor(rgb(0xF4F4F8))
        ctx.setLineWidth(46)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (frame.minX, frame.maxY, 1, -1), (frame.maxX, frame.maxY, -1, -1),
            (frame.minX, frame.minY, 1, 1), (frame.maxX, frame.minY, -1, 1),
        ]
        for (x, y, dx, dy) in corners {
            ctx.move(to: CGPoint(x: x + dx * arm, y: y))
            ctx.addLine(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x, y: y + dy * arm))
            ctx.strokePath()
        }

        // The single accent: a shutter dot in the middle
        ctx.setFillColor(rgb(0xFF8A3D))
        ctx.fillEllipse(in: CGRect(x: 512 - 62, y: 512 - 62, width: 124, height: 124))
        ctx.restoreGState()
    }

    static func pngData(pixels: Int) -> Data? {
        guard let ctx = Gfx.bitmap(width: pixels, height: pixels) else { return nil }
        draw(in: ctx, size: CGFloat(pixels))
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Writes an .iconset folder that `iconutil` turns into an .icns file.
    static func writeIconset(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in sizes {
            guard let data = pngData(pixels: px) else { throw CaptureError.encodingFailed }
            try data.write(to: folder.appendingPathComponent(name + ".png"))
        }
    }
}
