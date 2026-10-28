// Draws the background of the installer window: swift dmg/background.swift out.png "<app name>" "<footer note>"
// The window is 660 x 400 points; the image is drawn at 2x and marked 144 dpi so Finder shows it sharp.
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: background.swift out.png name [note]"); exit(1) }
let out = args[1], name = args[2], note = args.count > 3 ? args[3] : ""

let size = NSSize(width: 660, height: 400)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1320, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Soft light gradient (Finder always draws the icon names in dark text)
NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.98, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.88, green: 0.91, blue: 0.97, alpha: 1)])!
    .draw(in: NSRect(origin: .zero, size: size), angle: -90)

// A faint glow behind the two icons
let glow = NSGradient(colors: [NSColor(srgbRed: 0.35, green: 0.5, blue: 1.0, alpha: 0.16), NSColor(srgbRed: 0.35, green: 0.5, blue: 1.0, alpha: 0)])!
glow.draw(fromCenter: NSPoint(x: 330, y: 215), radius: 0, toCenter: NSPoint(x: 330, y: 215), radius: 280, options: [])

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style]
    (s as NSString).draw(in: NSRect(x: 30, y: y, width: size == 12 ? 600 : 600, height: size + 10), withAttributes: attrs)
}
text(name, size: 30, weight: .bold, color: NSColor(srgbRed: 0.1, green: 0.12, blue: 0.2, alpha: 1), y: 332)
text("Drag \(name) into the Applications folder to install it", size: 14, weight: .regular, color: NSColor(srgbRed: 0.1, green: 0.12, blue: 0.2, alpha: 0.65), y: 303)

// Arrow between the two icons (app at x=180, Applications at x=480, both at y=200 from the top)
let arrow = NSBezierPath()
arrow.lineWidth = 5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 262, y: 200)); arrow.line(to: NSPoint(x: 398, y: 200))
arrow.move(to: NSPoint(x: 376, y: 222)); arrow.line(to: NSPoint(x: 398, y: 200)); arrow.line(to: NSPoint(x: 376, y: 178))
NSColor(srgbRed: 0.1, green: 0.12, blue: 0.2, alpha: 0.4).setStroke()
arrow.stroke()

if !note.isEmpty { text(note, size: 12, weight: .regular, color: NSColor(srgbRed: 0.1, green: 0.12, blue: 0.2, alpha: 0.5), y: 28) }

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
