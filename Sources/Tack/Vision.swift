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

/// Small window that shows what OCR / QR scanning found.
@MainActor
final class ScanResultWindow: NSObject {
    private static var open: [ScanResultWindow] = []
    private let window: NSWindow
    private let textView = NSTextView()
    private let codes: [String]

    static func show(_ result: ScanResult, copied: Bool = true) {
        let w = ScanResultWindow(result, copied: copied)
        open.append(w)
        w.window.centerOnPointerScreen()
        NSApp.activate(ignoringOtherApps: true)
        w.window.makeKeyAndOrderFront(nil)
    }

    private init(_ result: ScanResult, copied: Bool) {
        codes = result.codes
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Recognized Text"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        var body = ""
        if !result.codes.isEmpty {
            body += "QR / barcodes:\n" + result.codes.joined(separator: "\n") + "\n\n"
        }
        body += result.text.isEmpty ? (result.codes.isEmpty ? "No text or codes were found in this selection." : "") : result.text
        textView.string = body
        textView.font = .systemFont(ofSize: 14)
        textView.isEditable = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let copy = NSButton(title: "Copy All", target: self, action: #selector(copyAll))
        copy.bezelStyle = .rounded
        var buttons: [NSView] = [copy]
        if let first = result.codes.first, let url = URL(string: first), url.scheme?.hasPrefix("http") == true {
            let open = NSButton(title: "Open Link", target: self, action: #selector(openLink))
            open.bezelStyle = .rounded
            buttons.append(open)
        }
        let note = NSTextField(labelWithString: (copied && !result.isEmpty) ? "Already copied to the clipboard." : "")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        let bar = NSStackView(views: [note] + buttons)
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scroll)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        window.contentView = root
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                ScanResultWindow.open.removeAll { $0 === self }
            }
        }
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func openLink() {
        if let first = codes.first, let url = URL(string: first) { NSWorkspace.shared.open(url) }
    }
}


/// What happens after a scan. A QR code that holds a link (or an email, phone number...) opens straight away,
/// with no window and nothing copied. Anything else shows the recognized text as before.
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
        if !result.codes.isEmpty {
            // A code with plain text or settings (for example Wi-Fi): nothing to open, so just show it. Not copied.
            ScanResultWindow.show(ScanResult(text: "", codes: result.codes), copied: false)
            return
        }
        if !result.text.isEmpty { Clipboard.copy(text: result.text) }
        ScanResultWindow.show(result, copied: !result.text.isEmpty)
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
