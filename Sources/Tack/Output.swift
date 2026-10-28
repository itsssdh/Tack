import AppKit
import Foundation

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayUnavailable
    case encodingFailed
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Tack needs Screen Recording permission to capture the screen."
        case .displayUnavailable:
            return "The display for this capture is no longer available."
        case .encodingFailed:
            return "The image could not be encoded in the chosen format."
        case .captureFailed(let detail):
            return "The capture failed: \(detail) If this keeps happening, check that Screen Recording is allowed for Tack in System Settings."
        }
    }
}

enum FileSaver {
    static func filename(ext: String) -> String {
        filename(template: Prefs.filenameTemplate, ext: ext)
    }

    static func filename(template: String, ext: String) -> String {
        let now = Date()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let date = df.string(from: now)
        df.dateFormat = "HH.mm.ss"
        let time = df.string(from: now)

        var name = template
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = "Screenshot" }
        return name + "." + ext
    }

    /// Never overwrites: appends " 2", " 3", ... if the name is taken.
    static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(i).\(ext)")
            i += 1
        }
        return url
    }

    @discardableResult
    @MainActor
    static func save(_ image: CGImage, kind: String = "screenshot") throws -> URL {
        let format = Prefs.imageFormat
        guard let data = format.encode(image, quality: Prefs.jpegQuality) else {
            throw CaptureError.encodingFailed
        }
        let folder = Prefs.screenshotFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, name: filename(ext: format.fileExtension))
        try data.write(to: url, options: .atomic)
        History.shared.add(url: url, kind: kind, image: image)
        return url
    }

    /// Writes encoded image data to a user-chosen location without ever replacing an existing file.
    @discardableResult
    @MainActor
    static func save(_ image: CGImage, as format: ImageFormat, to wanted: URL) throws -> URL {
        guard let data = format.encode(image, quality: Prefs.jpegQuality) else {
            throw CaptureError.encodingFailed
        }
        let folder = wanted.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, name: wanted.lastPathComponent)
        try data.write(to: url, options: .atomic)
        History.shared.add(url: url, kind: "screenshot", image: image)
        return url
    }
}

enum Clipboard {
    static func copy(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// `scale` is the pixel density of the display the picture came from, so it pastes at the right size.
    @MainActor
    static func copy(_ image: CGImage, scale: CGFloat? = nil) {
        let scale = scale ?? CaptureService.screenUnderMouse().backingScaleFactor
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: image, size: size)])
    }
}

@MainActor
enum CaptureOutput {
    /// Shows the bottom-left preview. The user then chooses Copy (clipboard only) or Save (clipboard + folder).
    static func deliver(_ image: CGImage) {
        Editor.lastCapture = image
        QuickAccess.shared.present(image)
        if Prefs.playSound {
            NSSound(named: NSSound.Name("Pop"))?.play()
        }
    }
}
