import AppKit
import Foundation

enum PrefKey {
    static let screenshotFolder = "screenshotFolder"
    static let imageFormat = "imageFormat"
    static let jpegQuality = "jpegQuality"
    static let filenameTemplate = "filenameTemplate"
    static let playSound = "playSound"
    static let showCursor = "showCursor"
    static let fixedWidth = "fixedWidth"
    static let fixedHeight = "fixedHeight"
    static let aspectRatio = "aspectRatio"
    static let appearance = "appearance"
    static let lastRegion = "lastRegion"
    // Annotation
    static let annSize = "annSize"
    static let annBackground = "annBackground"
    static let annPadding = "annPadding"
    static let annRounded = "annRounded"
    static let annShadow = "annShadow"
    static let savedColors = "savedColors"
    // Overlay
    static let overlayCorner = "overlayCorner"
    static let overlaySize = "overlaySize"
    // Recording
    static let recFormat = "recFormat"
    static let recFPS = "recFPS"
    static let recSystemAudio = "recSystemAudio"
    static let recMic = "recMic"
    static let recCursor = "recCursor"
    static let recClicks = "recClicks"
    static let recWebcam = "recWebcam"
    static let recCountdown = "recCountdown"
    static let recFolder = "recFolder"
    static let gifFPS = "gifFPS"
    static let gifWidth = "gifWidth"
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg, tiff, heic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .heic: return "HEIC"
        }
    }

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }

    private var uti: CFString {
        switch self {
        case .png: return "public.png" as CFString
        case .jpeg: return "public.jpeg" as CFString
        case .tiff: return "public.tiff" as CFString
        case .heic: return "public.heic" as CFString
        }
    }

    func encode(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, uti, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if self == .jpeg || self == .heic {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // JPEG has no transparency: put the image on white so transparent areas do not turn black.
        let source = self == .jpeg ? ImageFormat.flattenedOnWhite(image) : image
        CGImageDestinationAddImage(dest, source, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? (data as Data) : nil
    }
}

extension ImageFormat {
    static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }
}

struct SavedRegion: Codable {
    var displayID: UInt32
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    /// Rect in the screen's own coordinates (origin bottom-left, points).
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

enum Prefs {
    static let defaults = UserDefaults.standard

    static func registerDefaults() {
        defaults.register(defaults: [
            PrefKey.imageFormat: ImageFormat.png.rawValue,
            PrefKey.jpegQuality: 0.9,
            PrefKey.filenameTemplate: "Screenshot {date} at {time}",
            PrefKey.playSound: true,
            PrefKey.showCursor: false,
            PrefKey.fixedWidth: 0,
            PrefKey.fixedHeight: 0,
            PrefKey.aspectRatio: "none",
            PrefKey.appearance: "system",
            PrefKey.annSize: 1,
            PrefKey.annBackground: "none",
            PrefKey.annPadding: 48,
            PrefKey.annRounded: true,
            PrefKey.annShadow: true,
            PrefKey.overlayCorner: "bottomLeft",
            PrefKey.overlaySize: "medium",
            PrefKey.recFormat: "mp4",
            PrefKey.recFPS: 30,
            PrefKey.recSystemAudio: true,
            PrefKey.recMic: false,
            PrefKey.recCursor: true,
            PrefKey.recClicks: true,
            PrefKey.recWebcam: false,
            PrefKey.recCountdown: 3,
            PrefKey.gifFPS: 12,
            PrefKey.gifWidth: 800,
        ])
    }

    static var screenshotFolder: URL {
        if let path = defaults.string(forKey: PrefKey.screenshotFolder), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return AppFolders.defaultPicturesFolder
    }

    static var imageFormat: ImageFormat {
        ImageFormat(rawValue: defaults.string(forKey: PrefKey.imageFormat) ?? "") ?? .png
    }

    static var jpegQuality: Double { defaults.double(forKey: PrefKey.jpegQuality) }
    static var filenameTemplate: String { defaults.string(forKey: PrefKey.filenameTemplate) ?? "Screenshot {date} at {time}" }
    static var playSound: Bool { defaults.bool(forKey: PrefKey.playSound) }
    static var showCursor: Bool { defaults.bool(forKey: PrefKey.showCursor) }

    /// Recordings and GIFs go to the same folder as screenshots (Pictures/<app name>) unless a different one is chosen.
    static var recordingFolder: URL {
        if let path = defaults.string(forKey: PrefKey.recFolder), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return screenshotFolder
    }

    /// Fixed capture size in points; nil when off.
    static var fixedSize: CGSize? {
        let w = defaults.integer(forKey: PrefKey.fixedWidth)
        let h = defaults.integer(forKey: PrefKey.fixedHeight)
        return (w > 0 && h > 0) ? CGSize(width: w, height: h) : nil
    }

    /// width / height, nil when no lock.
    static var aspectRatio: CGFloat? {
        let s = defaults.string(forKey: PrefKey.aspectRatio) ?? "none"
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return nil }
        return CGFloat(parts[0] / parts[1])
    }

    static var lastRegion: SavedRegion? {
        get {
            guard let data = defaults.data(forKey: PrefKey.lastRegion) else { return nil }
            return try? JSONDecoder().decode(SavedRegion.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: PrefKey.lastRegion)
            } else {
                defaults.removeObject(forKey: PrefKey.lastRegion)
            }
        }
    }

    @MainActor
    static func applyAppearance() {
        switch defaults.string(forKey: PrefKey.appearance) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    static func resetAll() {
        // Resetting settings must not forget which questions were already asked.
        let keep = ["askedToReplaceAppleScreenshots"]
        let saved = keep.compactMap { key in defaults.object(forKey: key).map { (key, $0) } }
        if let id = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: id)
        }
        saved.forEach { defaults.set($1, forKey: $0) }
        registerDefaults()
    }
}
