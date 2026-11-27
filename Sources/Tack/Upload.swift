import AppKit
import Foundation
import Security
import UniformTypeIdentifiers

// Uploads are off until the user turns them on in Settings > Uploads, and nothing is sent unless they click the
// upload button on a preview (or have switched on automatic uploads). Tack itself never talks to a host on its own.

enum UploadHost: String, CaseIterable {
    case olrite, custom

    var label: String { self == .olrite ? "olrite.lol" : "Custom" }
}

/// Where one upload goes and how it is described to that host.
struct UploadTarget {
    var url: URL
    /// Name of the form field the file travels in.
    var field = "file"
    /// Where the link is in the host's JSON reply, as a dotted path ("url" or "data.link").
    var linkKey = "url"
    /// Header that carries the API key, when there is one.
    var keyHeader = "X-API-Key"
    var apiKey: String?
    /// Largest file the host takes, if it says so. Checked before sending so a big recording is not uploaded for nothing.
    var maxBytes: Int64?
}

enum UploadError: LocalizedError {
    case notSetUp
    /// The file is over the host's limit. `size` and `limit` are known when Tack checked before sending; when the host
    /// turned the file away, they are usually not, and `detail` is what the host said.
    case tooLarge(size: Int64?, limit: Int64?, detail: String?)
    case server(String)
    case noLink

    /// The heading of the alert that shows this error.
    var alertTitle: String {
        if case .tooLarge = self { return "File too large" }
        return "Upload failed"
    }

    var errorDescription: String? {
        func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        switch self {
        case .notSetUp:
            return "Uploads are not set up yet. Choose a host in Settings > Uploads."
        case .tooLarge(let size, let limit, let detail):
            var text: String
            switch (size, limit) {
            case let (size?, limit?): text = "This file is \(bytes(size)), but the host only accepts files up to \(bytes(limit))."
            case let (nil, limit?): text = "This file is larger than the host accepts (up to \(bytes(limit)))."
            default: text = "This file is larger than the host accepts."
            }
            if let detail, !detail.isEmpty { text += "\n\nThe host says: \(detail)" }
            return text
        case .server(let message):
            return message
        case .noLink:
            return "The host accepted the file but did not send back a link."
        }
    }
}

enum UploadSettings {
    static let keychainAccount = "uploadAPIKey"

    static var isEnabled: Bool { Prefs.defaults.bool(forKey: PrefKey.uploadsEnabled) }

    static var host: UploadHost { UploadHost(rawValue: Prefs.defaults.string(forKey: PrefKey.uploadHost) ?? "") ?? .olrite }

    /// The chosen host as an upload target, or nil while it is not filled in (a custom host needs an https address).
    static func target() -> UploadTarget? {
        let d = Prefs.defaults
        let key = Keychain.read(keychainAccount).flatMap { $0.isEmpty ? nil : $0 }
        switch host {
        case .olrite:
            return UploadTarget(url: URL(string: "https://olrite.lol/api/upload")!, field: "file", linkKey: "url", keyHeader: "X-API-Key", apiKey: key, maxBytes: 300 * 1024 * 1024)
        case .custom:
            let raw = (d.string(forKey: PrefKey.uploadURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
            func text(_ k: String, _ fallback: String) -> String {
                let v = (d.string(forKey: k) ?? "").trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? fallback : v
            }
            return UploadTarget(url: url, field: text(PrefKey.uploadField, "file"), linkKey: text(PrefKey.uploadLinkKey, "url"), keyHeader: text(PrefKey.uploadKeyHeader, "X-API-Key"), apiKey: key, maxBytes: nil)
        }
    }

    /// Whether a fresh capture of this kind is uploaded the moment it is taken.
    static func autoUploads(_ media: PreviewMedia) -> Bool {
        guard isEnabled else { return false }
        switch media {
        case .image: return Prefs.defaults.bool(forKey: PrefKey.uploadAutoShots)
        case .video, .gif: return Prefs.defaults.bool(forKey: PrefKey.uploadAutoRecordings)
        case .text: return false
        }
    }
}

/// The API key lives in the macOS Keychain, not in the preferences file.
enum Keychain {
    private static let service = "com.itsssdh.tack.uploads"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty value removes the item.
    static func write(_ value: String, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query(account)
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Reading the host's answer.
enum UploadReply {
    /// The link from a reply: JSON with the link at `linkKey`, or just the link as plain text.
    static func link(from data: Data, status: Int, linkKey: String) throws -> URL {
        let ok = (200..<300).contains(status)
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if ok, object["success"] as? Bool != false {
                guard let text = value(at: linkKey, in: object) as? String, let url = web(text) else { throw UploadError.noLink }
                return url
            }
            let message = (object["error"] as? String) ?? (object["message"] as? String)
            if status == 413 || saysTooLarge(code: object["code"] as? String, message: message) {
                throw UploadError.tooLarge(size: nil, limit: nil, detail: message)
            }
            throw UploadError.server(message ?? "The host answered with status \(status).")
        }
        if ok, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), let url = web(text) { return url }
        if status == 413 { throw UploadError.tooLarge(size: nil, limit: nil, detail: nil) } // "Payload Too Large"
        throw ok ? UploadError.noLink : UploadError.server("The host answered with status \(status).")
    }

    /// Whether a host's error is about the file being too big, going by its error code or its wording.
    static func saysTooLarge(code: String?, message: String?) -> Bool {
        let code = (code ?? "").lowercased()
        if code.contains("large") || code.contains("too_big") || code.contains("size") { return true }
        let text = (message ?? "").lowercased()
        return ["too large", "too big", "exceeds", "file size", "maximum size", "max size", "size limit"].contains { text.contains($0) }
    }

    static func value(at path: String, in object: [String: Any]) -> Any? {
        var current: Any? = object
        for part in path.split(separator: ".") { current = (current as? [String: Any])?[String(part)] }
        return current
    }

    private static func web(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return nil }
        return url
    }
}

enum Uploader {
    /// A multipart/form-data body written to a file, so a large recording is streamed from disk and never held in memory.
    static func writeMultipartBody(file: URL, field: String, boundary: String, to body: URL) throws {
        let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let cleanField = field.replacingOccurrences(of: "\"", with: "")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        let out = try FileHandle(forWritingTo: body)
        defer { try? out.close() }
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(cleanField)\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { out.write(chunk) }
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
    }

    /// Sends one file and returns the link the host gives back. Cancelling the surrounding Task stops the transfer.
    /// `progress` reports 0...1 while the file is going out.
    static func upload(file: URL, to target: UploadTarget, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        if let limit = target.maxBytes,
           let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value, size > limit {
            throw UploadError.tooLarge(size: size, limit: limit, detail: nil)
        }
        let boundary = "TackBoundary-" + UUID().uuidString
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("tack-upload-\(UUID().uuidString)")
        try writeMultipartBody(file: file, field: target.field, boundary: boundary, to: body)
        defer { try? FileManager.default.removeItem(at: body) }

        var request = URLRequest(url: target.url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Tack/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1")", forHTTPHeaderField: "User-Agent")
        if let key = target.apiKey, !key.isEmpty { request.setValue(key, forHTTPHeaderField: target.keyHeader) }

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body, delegate: ProgressReporter(progress))
        return try UploadReply.link(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, linkKey: target.linkKey)
    }
}

private final class ProgressReporter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

/// A short message that floats near the top of the screen, like "Link copied".
@MainActor
enum UploadToast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    /// Takes the message away now, for example when "Uploading…" is replaced by an error.
    static func hide() {
        hideWork?.cancel()
        let p = panel
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p?.animator().alphaValue = 0 }, completionHandler: { Task { @MainActor in p?.orderOut(nil) } })
    }

    static func show(_ text: String, symbol: String = "link") {
        hideWork?.cancel()
        panel?.orderOut(nil)
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .white
        let stack = NSStackView(views: [icon, glassLabel(text, size: 14, weight: .semibold, color: .white)])
        stack.spacing = 8
        let insets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 18)
        let surface = Glass.surface(stack, cornerRadius: 20, insets: insets)
        let size = Glass.fittingSize(of: stack, insets: insets)
        let p = Glass.floatingPanel(surface: surface, size: size, centerX: screen.frame.midX, bottom: screen.visibleFrame.maxY - size.height - 18, level: .statusBar)
        p.ignoresMouseEvents = true
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: { Task { @MainActor in p.orderOut(nil) } })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}
