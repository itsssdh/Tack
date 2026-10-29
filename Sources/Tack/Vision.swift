import AppKit
import Vision
import CoreImage

struct ScanResult {
    var text: String
    var codes: [String]
    var isEmpty: Bool { text.isEmpty && codes.isEmpty }
}

enum Scanner {
    /// Reads text and QR/bar codes from an image. Runs off the main thread.
    static func scan(_ image: CGImage, wantText: Bool = true, wantCodes: Bool = true) async -> ScanResult {
        await Task.detached(priority: .userInitiated) {
            var text = ""
            var codes: [String] = []
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            var requests: [VNRequest] = []

            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = true
            if wantText { requests.append(textRequest) }

            let codeRequest = VNDetectBarcodesRequest()
            if wantCodes { requests.append(codeRequest) }

            do { try handler.perform(requests) } catch { return ScanResult(text: "", codes: []) }

            if wantText {
                let lines = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                text = lines.joined(separator: "\n")
            }
            if wantCodes {
                codes = (codeRequest.results ?? []).compactMap { $0.payloadStringValue }
            }
            return ScanResult(text: text, codes: codes)
        }.value
    }
}

extension Scanner {
    /// The first text recognition after a restart can take many seconds while macOS prepares its recognition model
    /// (about 25 s on a test Mac), and every scan waits behind it. Reading a small picture now, in the background, means
    /// the first real capture is quick.
    @MainActor
    static func warmUp() {
        let size = NSSize(width: 260, height: 70)
        let picture = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("Tack reads text" as NSString).draw(
                at: NSPoint(x: 12, y: 18),
                withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black]
            )
            return true
        }
        guard let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        Task.detached(priority: .utility) { _ = await scan(image, wantText: true, wantCodes: false) }
    }
}

/// What happens after a scan. A QR code that holds a link (or an email, phone number...) opens straight away,
/// with no card and nothing copied. Anything else shows up as a text preview, like a screenshot, with Copy.
@MainActor
enum ScanHandler {
    static func handle(_ result: ScanResult) {
        let urls = result.codes.compactMap(openableURL)
        if !urls.isEmpty {
            var seen = Set<URL>()
            for url in urls where seen.insert(url).inserted && seen.count <= 3 {
                NSWorkspace.shared.open(url)
            }
            return
        }
        if result.isEmpty {
            Alerts.show(title: "No text found", message: "Tack did not find any text or QR code in that selection. Try a larger area, or one with clearer text.")
            return
        }
        // A code with plain text or settings (for example Wi-Fi) is shown above any other text.
        var parts: [String] = []
        if !result.codes.isEmpty { parts.append(result.codes.joined(separator: "\n")) }
        if !result.text.isEmpty { parts.append(result.text) }
        QuickAccess.shared.presentText(parts.joined(separator: "\n\n"))
    }

    /// Only link-like payloads are opened. Anything that could run code or read local files is refused.
    nonisolated static func openableURL(_ payload: String) -> URL? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") || text.lowercased().hasPrefix("http") else { return nil }
        var candidate = text
        if candidate.lowercased().hasPrefix("www.") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else { return nil }
        let allowed: Set<String> = ["http", "https", "mailto", "tel", "sms", "facetime", "facetime-audio", "webcal", "maps"]
        return allowed.contains(scheme) ? url : nil
    }
}

extension ImageOps {
    /// Cuts the subject out of the picture and makes everything else transparent. Nil if no subject was found.
    static func removeBackground(_ image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first, !result.allInstances.isEmpty,
              let buffer = try? result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(ci, from: ci.extent)
    }
}
