#if FRAMEGRAB_TESTING
import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

/// Run with:  : --selftest
/// Checks the parts of Tack that do not need a screen or permissions.
@MainActor
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "PASS  " : "FAIL  ") + name + (ok || detail.isEmpty ? "" : "  (\(detail))"))
        if !ok { failures += 1 }
    }

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        Task {
            if CommandLine.arguments.contains("--selftest-showcase") {
                await runShowcase()
            } else if CommandLine.arguments.contains("--selftest-ui") {
                await runUI()
            } else if CommandLine.arguments.contains("--selftest-apple-roundtrip") {
                await runAppleRoundTrip()
            } else if CommandLine.arguments.contains("--selftest-demo4") {
                await runDemo4()
            } else if CommandLine.arguments.contains("--selftest-demo3") {
                await runDemo3()
            } else if CommandLine.arguments.contains("--selftest-demo2") {
                await runDemo2()
            } else if CommandLine.arguments.contains("--selftest-demo") {
                await runDemo()
            } else if CommandLine.arguments.contains("--selftest-capture") {
                await runCapture()
            } else if CommandLine.arguments.contains("--selftest-live") {
                await runLive()
            } else {
                await runAll()
            }
            print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
            exit(failures == 0 ? 0 : 1)
        }
    }

    // MARK: helpers

    private static func solid(_ w: Int, _ h: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> CGImage {
        Gfx.render(width: w, height: h) { ctx in
            ctx.setFillColor(CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }!
    }

    /// RGBA of one pixel, (0,0) = top-left.
    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let i = (y * image.width + x) * 4
        return Array(data[i..<i + 4])
    }

    // MARK: checks

    private static func runAll() async {
        // 1. Never overwrite
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fg-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data([1]).write(to: dir.appendingPathComponent("a.png"))
        let u2 = FileSaver.uniqueURL(in: dir, name: "a.png")
        try? Data([1]).write(to: u2)
        let u3 = FileSaver.uniqueURL(in: dir, name: "a.png")
        check("files are never overwritten", u2.lastPathComponent == "a 2.png" && u3.lastPathComponent == "a 3.png", "\(u2.lastPathComponent), \(u3.lastPathComponent)")
        try? FileManager.default.removeItem(at: dir)

        // Editor canvas: eraser, zoom, backdrop, cut-out
        do {
            let base = solid(400, 300, 255, 255, 255)
            let canvas = EditorCanvas(image: base, unit: 1, style: DocStyle())
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.titled], backing: .buffered, defer: true)
            host.contentView = canvas
            canvas.layoutSubtreeIfNeeded()

            // Without a running event loop the undo manager would lump every step into one undo, so group by hand.
            let um = canvas.undoManager!
            um.groupsByEvent = false
            func step(_ body: () -> Void) { um.beginUndoGrouping(); body(); um.endUndoGrouping() }

            var box = Annotation(kind: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 120, y: 120), color: .systemRed, lineWidth: 4)
            box.color = .systemRed
            var st = canvas.state
            st.annotations = [box]
            step { canvas.setState(st, actionName: "Add") }

            func mouse(_ type: NSEvent.EventType, at imagePoint: CGPoint) -> NSEvent {
                let p = canvas.convert(canvas.toView(imagePoint), to: nil)
                return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            canvas.tool = .eraser
            step {
                canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 20, y: 70)))
                canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 20, y: 70)))
            }
            check("editor: eraser removes the annotation it touches", canvas.annotations.isEmpty)
            canvas.undo()
            check("editor: erasing is one undo step", canvas.annotations.count == 1)

            canvas.tool = .eraser
            step {
                canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 300, y: 250)))
                canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 300, y: 250)))
            }
            check("editor: eraser on empty space changes nothing", canvas.annotations.count == 1)

            let fit = canvas.zoomPercent
            canvas.zoomIn()
            let bigger = canvas.zoomPercent
            canvas.zoomOut()
            canvas.zoomOut()
            let smaller = canvas.zoomPercent
            check("editor: zoom in and out step through the zoom levels", bigger > fit && smaller < fit, "fit \(fit) in \(bigger) out \(smaller)")
            for _ in 0..<20 { canvas.zoomIn() }
            check("editor: zoom stops at 400%", canvas.zoomPercent == 400, "\(canvas.zoomPercent)")
            for _ in 0..<20 { canvas.zoomOut() }
            check("editor: zoom stops at 10%", canvas.zoomPercent == 10, "\(canvas.zoomPercent)")
            canvas.zoomToFit()
            check("editor: zoom to fit returns to the fitted size", canvas.zoomPercent == fit)

            canvas.currentColor = .systemRed
            check("editor: highlighter is yellow while red is selected", canvas.highlighterColor == .systemYellow)
            canvas.currentColor = .systemBlue
            check("editor: highlighter follows the chosen color", canvas.highlighterColor == .systemBlue)

            var style = DocStyle()
            style.backdrop = .ocean
            style.padding = 48
            let withBackdrop = DocRenderer.size(of: EditState(base: base), style: style)
            style.backdrop = .none
            let without = DocRenderer.size(of: EditState(base: base), style: style)
            check("editor: removing the backdrop removes its padding", withBackdrop.width == 496 && without.width == 400, "\(withBackdrop.width) / \(without.width)")

            // Cut-out must not crash on a plain picture, and keeps the size when it finds a subject.
            let cut = ImageOps.removeBackground(solid(200, 200, 30, 120, 220))
            check("editor: cut-out copes with a picture that has no subject", cut == nil || (cut!.width == 200 && cut!.height == 200))
        }

        // 2. Redaction is fully opaque, including the edges
        let white = solid(120, 90, 255, 255, 255)
        var a = Annotation(kind: .redact, start: CGPoint(x: 10.4, y: 10.6), end: CGPoint(x: 70.3, y: 50.2), color: .black, lineWidth: 4)
        a.color = .black
        var state = EditState(base: white)
        state.annotations = [a]
        let out = DocRenderer.render(state: state, style: DocStyle())!
        var allBlack = true
        let r = a.rect.integral
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) where pixel(out, x, y) != [0, 0, 0, 255] { allBlack = false }
        }
        check("redaction is solid black and opaque", allBlack)
        check("pixels outside a redaction are untouched", pixel(out, 100, 80) == [255, 255, 255, 255])

        // 3. Blur / pixelate really change the pixels under them
        let stripes = Gfx.render(width: 100, height: 100) { ctx in
            for i in 0..<20 {
                ctx.setFillColor(i % 2 == 0 ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: i * 5, y: 0, width: 5, height: 100))
            }
        }!
        for kind in [AnnotationKind.blur, .pixelate] {
            var s = EditState(base: stripes)
            s.annotations = [Annotation(kind: kind, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100), color: .black, lineWidth: 6)]
            let o = DocRenderer.render(state: s, style: DocStyle())!
            check("\(kind) changes the pixels", pixel(o, 2, 50) != pixel(stripes, 2, 50) || pixel(o, 7, 50) != pixel(stripes, 7, 50))
        }

        // 4. Rotate / flip
        var wide = Gfx.bitmap(width: 4, height: 2)!
        wide.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        wide.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        wide.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        wide.fill(CGRect(x: 0, y: 1, width: 1, height: 1)) // CG origin bottom-left => top-left pixel
        let marked = wide.makeImage()!
        check("marker starts at top-left", pixel(marked, 0, 0) == [255, 0, 0, 255])
        let rr = ImageOps.rotateRight(marked)!
        check("rotate right swaps size and moves top-left to top-right", rr.width == 2 && rr.height == 4 && pixel(rr, 1, 0) == [255, 0, 0, 255])
        let rl = ImageOps.rotateLeft(marked)!
        check("rotate left moves top-left to bottom-left", rl.width == 2 && pixel(rl, 0, 3) == [255, 0, 0, 255])
        check("flip horizontal moves top-left to top-right", pixel(ImageOps.flipHorizontal(marked)!, 3, 0) == [255, 0, 0, 255])
        check("flip vertical moves top-left to bottom-left", pixel(ImageOps.flipVertical(marked)!, 0, 1) == [255, 0, 0, 255])
        wide = Gfx.bitmap(width: 1, height: 1)!

        // 5. Background and padding
        var style = DocStyle()
        style.backdrop = .ocean
        style.padding = 40
        let framed = DocRenderer.render(state: EditState(base: white), style: style)!
        check("background adds padding on every side", framed.width == 120 + 80 && framed.height == 90 + 80)

        // 6. Formats
        for f in ImageFormat.allCases {
            check("\(f.label) encodes", f.encode(white, quality: 0.8)?.isEmpty == false)
        }

        // 9. OCR and QR
        let textImage = Gfx.render(width: 700, height: 160) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 700, height: 160))
            ("Hello Tack" as NSString).draw(at: CGPoint(x: 30, y: 40), withAttributes: [
                .font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.black,
            ])
        }!
        let ocr = await Scanner.scan(textImage, wantText: true, wantCodes: false)
        check("OCR reads text", ocr.text.lowercased().contains("tack"), "got “\(ocr.text)”")

        if let qrFilter = CIFilter(name: "CIQRCodeGenerator") {
            qrFilter.setValue(Data("https://example.com/framegrab".utf8), forKey: "inputMessage")
            if let ci = qrFilter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
               let cg = CIContext().createCGImage(ci, from: ci.extent) {
                let padded = Gfx.render(width: cg.width + 80, height: cg.height + 80) { ctx in
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: cg.width + 80, height: cg.height + 80))
                    Gfx.draw(cg, in: CGRect(x: 40, y: 40, width: cg.width, height: cg.height), ctx: ctx)
                }!
                let qr = await Scanner.scan(padded, wantText: false, wantCodes: true)
                check("QR code is read", qr.codes.contains("https://example.com/framegrab"), "got \(qr.codes)")
            }
        }

        await runVideo()

        // Apple's screenshot shortcuts are written as real booleans (macOS ignores strings)
        do {
            let testDomain = "com.local.framegrab.selftest"
            func flag(_ id: String) -> CFTypeRef? {
                let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, testDomain as CFString) as? [String: Any]
                return (all?[id] as? [String: Any])?["enabled"] as CFTypeRef?
            }
            _ = NativeScreenshots.setApple(enabled: false, in: testDomain)
            let off = flag("30")
            _ = NativeScreenshots.setApple(enabled: true, in: testDomain)
            let on = flag("30")
            check("shortcut flags are booleans", off.map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true && on.map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true)
            check("turning shortcuts off then on round-trips", (off as? Bool) == false && (on as? Bool) == true)
            CFPreferencesSetAppValue("AppleSymbolicHotKeys" as CFString, nil, testDomain as CFString)
            CFPreferencesAppSynchronize(testDomain as CFString)
        }

        // A floating window that was never shown has window number -1; looking for capture UI must not trap on it
        let hidden = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        hidden.level = .floating
        hidden.isReleasedWhenClosed = false
        _ = CaptureService.chromeWindowIDs([hidden])
        check("capture UI lookup survives windows that are not on screen", true)

        // Settings window opens at a usable size
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.showSettings()
            let f = delegate.settingsFrame ?? .zero
            check("settings window has its full size", f.width >= 780 && f.height >= 580, "\(f)")
            NSApp.windows.first { $0.title == "Tack Settings" }?.orderOut(nil)
        }

        // Every preview size setting leaves room for the corner buttons and the Copy / Save pair
        if NSScreen.main != nil {
            let shapes: [CGImage] = [solid(1200, 700, 90, 90, 200), solid(60, 40, 90, 90, 200), solid(1600, 120, 90, 90, 200), solid(120, 1600, 90, 90, 200)]
            var tooSmall: [String] = []
            for shape in shapes {
                for size in QuickAccess.shared.cardSizesForTesting(shape) where size.width < 150 || size.height < 150 {
                    tooSmall.append("\(size)")
                }
            }
            check("previews are never smaller than the buttons need", tooSmall.isEmpty, tooSmall.joined(separator: ", "))
        }

        // Pinning a saved file from the history window adds one pinned preview, and only one
        do {
            let png = FileManager.default.temporaryDirectory.appendingPathComponent("fg-pin-\(UUID().uuidString).png")
            if let data = NSBitmapImageRep(cgImage: solid(400, 250, 30, 160, 90)).representation(using: .png, properties: [:]) {
                try? data.write(to: png)
                let before = QuickAccess.shared.itemCountForTesting
                QuickAccess.shared.pinFile(png)
                QuickAccess.shared.pinFile(png)
                check("history: pinning a file adds exactly one preview", QuickAccess.shared.itemCountForTesting == before + 1, "\(QuickAccess.shared.itemCountForTesting - before)")
                QuickAccess.shared.removeLastForTesting()
                try? FileManager.default.removeItem(at: png)
            }
        }

        // Pressing Done in the photo editor: the editor closes and the result comes back as a preview
        do {
            let before = QuickAccess.shared.itemCountForTesting
            Editor.open(solid(500, 300, 200, 60, 60))
            try? await Task.sleep(nanoseconds: 500_000_000)
            Editor.firstForTesting?.doneForTesting()
            try? await Task.sleep(nanoseconds: 600_000_000)
            check("editor: Done closes the editor", Editor.openCount == 0)
            check("editor: Done brings the picture back as a preview", QuickAccess.shared.itemCountForTesting == before + 1)
            QuickAccess.shared.removeLastForTesting()
        }

        // The video trimmer: dragging a handle trims and shows the frame under it
        do {
            let clipURL = FileManager.default.temporaryDirectory.appendingPathComponent("fg-trim-\(UUID().uuidString).mp4")
            if await makeClip(at: clipURL, seconds: 4, fps: 10, size: CGSize(width: 320, height: 180)) {
                VideoEditor.open(clipURL)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let editor = VideoEditor.firstForTesting {
                    let timeline = editor.timelineForTesting
                    func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
                        let p = timeline.convert(NSPoint(x: x, y: timeline.bounds.midY), to: nil)
                        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: timeline.window?.windowNumber ?? 0,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    }
                    // The end handle sits at the right end of the track (inset 14); drag it to the middle.
                    let track = timeline.bounds.width - 28
                    timeline.mouseDown(with: event(.leftMouseDown, x: 14 + track))
                    timeline.mouseDragged(with: event(.leftMouseDragged, x: 14 + track / 2))
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    let mid = editor.stateForTesting
                    timeline.mouseUp(with: event(.leftMouseUp, x: 14 + track / 2))
                    check("trimmer: dragging the end handle moves the end", abs(mid.trimEnd - 2) < 0.25 && mid.trimStart == 0, "\(mid)")
                    check("trimmer: the picture follows the handle", abs(mid.playerTime - 2) < 0.3, "player at \(mid.playerTime)")
                    // And the start handle
                    timeline.mouseDown(with: event(.leftMouseDown, x: 14))
                    timeline.mouseDragged(with: event(.leftMouseDragged, x: 14 + track / 4))
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    let start = editor.stateForTesting
                    timeline.mouseUp(with: event(.leftMouseUp, x: 14 + track / 4))
                    check("trimmer: dragging the start handle moves the start", abs(start.trimStart - 1) < 0.25, "\(start)")
                    check("trimmer: the picture follows the start handle", abs(start.playerTime - 1) < 0.3, "player at \(start.playerTime)")
                    editor.forceClose()
                } else {
                    check("trimmer opens", false)
                }
                try? FileManager.default.removeItem(at: clipURL)
            }
        }

        // Pictures of the whole of each Settings pane (written next to the other images when a folder is given)
        if let folder = CommandLine.arguments.last(where: { $0.hasPrefix("/") && !$0.hasSuffix(".png") && !$0.hasSuffix(".txt") }) {
            for pane in SettingsPane.allCases {
                if let image = SettingsView.renderForTesting(pane, height: 1100), let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("pane-\(pane.rawValue).png"))
                }
            }
        }

        // The menu bar menu
        if let delegate = NSApp.delegate as? AppDelegate {
            let menu = NSMenu()
            delegate.menuNeedsUpdate(menu)
            let titles = menu.items.filter { !$0.isSeparatorItem }.map { $0.title }
            print("menu bar menu:", titles)
            check("menu bar menu has the everyday actions", ["Area", "Window", "Fullscreen", "Record Screen…", "Recent", "Settings…", "Quit"].allSatisfy(titles.contains))
            check("menu bar menu has no More submenu", !titles.contains("More"))
        }

        // The round buttons on a preview are really round
        do {
            QuickAccess.shared.present(solid(600, 400, 80, 120, 200))
            try? await Task.sleep(nanoseconds: 400_000_000)
            let sizes = QuickAccess.shared.buttonSizesForTesting()
            print("preview round buttons:", sizes)
            check("preview has three round buttons", sizes.count == 3, "\(sizes.count)")
            check("round buttons are square", sizes.allSatisfy { abs($0.width - $0.height) < 0.5 }, "\(sizes)")
            QuickAccess.shared.removeLastForTesting()
        }

        // Pinned previews
        if NSScreen.main != nil {
            let r = QuickAccess.shared.pinningCheckForTesting(Gfx.render(width: 400, height: 300) { $0.setFillColor(CGColor(gray: 0.5, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 400, height: 300)) }!)
            check("a pinned preview sits beyond a new screenshot", r.outermost)
            check("dismissing a pinned preview does nothing", r.pinnedStaysOnDismiss)
            check("a full stack folds into one group", r.folded)
            check("the newest screenshot stays in view when folded", r.newestVisible)
            check("previews unfold when there is room again", r.unfolded)
            check("a preview pinned while the stack is full goes into the group", r.pinnedWhenFullHidden)
        }

        // QR payloads: only safe, link-like ones open automatically
        let urlCases: [(String, String?)] = [
            ("https://example.com/framegrab", "https://example.com/framegrab"),
            ("  http://example.com  ", "http://example.com"),
            ("www.example.com/menu", "https://www.example.com/menu"),
            ("mailto:me@example.com", "mailto:me@example.com"),
            ("tel:+15551234567", "tel:+15551234567"),
            ("WIFI:T:WPA;S:Cafe;P:secret;;", nil),
            ("hello world", nil),
            ("javascript:alert(1)", nil),
            ("file:///etc/passwd", nil),
            ("", nil),
        ]
        for (input, want) in urlCases {
            let got = ScanHandler.openableURL(input)?.absoluteString
            check("QR payload “\(input.trimmingCharacters(in: .whitespaces))” \(want == nil ? "is not opened" : "opens")", got == want, "got \(got ?? "nil")")
        }

        // 10. History search text and persistence format
        let item = HistoryItem(path: "/tmp/x.png", date: Date(), kind: "screenshot", text: "invoice 42")
        let data = try? JSONEncoder().encode([item])
        let back = data.flatMap { try? JSONDecoder().decode([HistoryItem].self, from: $0) }
        check("history items survive saving", back?.first?.text == "invoice 42")
    }

    // MARK: video pipeline (synthetic clip, no permissions needed)

    private static func makeClip(at url: URL, seconds: Int, fps: Int = 10, size: CGSize = CGSize(width: 320, height: 180)) async -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 5_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb else { return false }
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) {
                    let o = y * bpr + x * 4
                    base[o] = UInt8((x + i * 8) % 256); base[o + 1] = UInt8(y % 256); base[o + 2] = UInt8(i * 6 % 256); base[o + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    private static func runVideo() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fg-video-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("clip.mp4")
        let made = await makeClip(at: clip, seconds: 4)
        check("synthetic test video is created", made)
        guard made else { return }

        // GIF
        let gif = dir.appendingPathComponent("out.gif")
        do {
            try await GIFConverter.convert(video: clip, to: gif, fps: 5, maxWidth: 200)
            let size = (try? FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? Int) ?? 0
            let src = CGImageSourceCreateWithURL(gif as CFURL, nil)
            let frames = src.map { CGImageSourceGetCount($0) } ?? 0
            check("GIF export makes an animated GIF", size > 0 && frames >= 15, "frames=\(frames)")
        } catch {
            check("GIF export", false, error.localizedDescription)
        }

        // Trim export
        let asset = AVURLAsset(url: clip)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            check("export session is created", false)
            return
        }
        let out = dir.appendingPathComponent("edited.mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), end: CMTime(seconds: 3, preferredTimescale: 600))
        await session.export()
        check("trimmed video exports", session.status == .completed, session.error?.localizedDescription ?? "")
        if session.status == .completed {
            let dur = (try? await AVURLAsset(url: out).load(.duration).seconds) ?? 0
            check("trim keeps about 2 seconds", abs(dur - 2) < 0.4, "duration=\(dur)")
        }
    }

    // MARK: live checks (need Screen Recording permission; run through `open` so the app itself is asked)

    /// Turns Apple's screenshot shortcuts back on for a few seconds (so a real key press can be tried), then off again.
    private static func runAppleRoundTrip() async {
        let start = NativeScreenshots.anyEnabled
        print("roundtrip: start state anyEnabled =", start)
        print("roundtrip: restore ->", NativeScreenshots.restoreApple() ?? "ok", "anyEnabled =", NativeScreenshots.anyEnabled)
        try? await Task.sleep(nanoseconds: 9_000_000_000)
        print("roundtrip: replace ->", NativeScreenshots.replaceWithTack() ?? "ok", "anyEnabled =", NativeScreenshots.anyEnabled)
        let area = HotkeyManager.shared.shortcut(for: .captureArea).display
        print("roundtrip: Tack area shortcut is now", area)
    }


    /// Fourth demo: delete everything in the group and report where the remaining windows end up.
    private static func runDemo4() async {
        let img = Gfx.render(width: 800, height: 500) { ctx in ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 500)) }!
        for _ in 0..<12 { QuickAccess.shared.present(img); try? await Task.sleep(nanoseconds: 120_000_000) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        print("before:", QuickAccess.shared.debugFramesForTesting())
        QuickAccess.shared.deleteAllForTesting()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        print("after:", QuickAccess.shared.debugFramesForTesting())
    }

    /// Third demo: only the group list, with logging.
    private static func runDemo3() async {
        func picture(_ w: Int, _ h: Int, _ r: UInt8) -> CGImage {
            Gfx.render(width: w, height: h) { ctx in
                ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: 0.4, blue: 0.7, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }!
        }
        let marker = CommandLine.arguments.last(where: { $0.hasSuffix(".txt") }) ?? "/tmp/framegrab-demo.txt"
        func mark(_ text: String) { try? text.write(toFile: marker, atomically: true, encoding: .utf8); print("demo:", text) }
        for i in 0..<9 { QuickAccess.shared.present(picture(800, 500, UInt8(40 + i * 20))); try? await Task.sleep(nanoseconds: 150_000_000) }
        QuickAccess.shared.pinNewestForTesting(3)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        QuickAccess.shared.openGroupMenuForTesting()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        mark("menu")
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        QuickAccess.shared.openGroupMenuForTesting()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        mark("closed")
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        mark("done")
    }

    /// Second demo: the group list, a GIF preview, the recording setup bar in both formats and the countdown.
    private static func runDemo2() async {
        func picture(_ w: Int, _ h: Int, _ r: UInt8) -> CGImage {
            Gfx.render(width: w, height: h) { ctx in
                ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: 0.4, blue: 0.7, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
                ctx.fill(CGRect(x: w / 8, y: h / 3, width: w * 3 / 4, height: max(2, h / 12)))
            }!
        }
        let marker = CommandLine.arguments.last(where: { $0.hasSuffix(".txt") }) ?? "/tmp/framegrab-demo.txt"
        func mark(_ text: String) { try? text.write(toFile: marker, atomically: true, encoding: .utf8); print("demo:", text) }
        guard let screen = NSScreen.screens.first else { return }

        // The list of folded previews, with some pinned
        for i in 0..<9 { QuickAccess.shared.present(picture(800, 500, UInt8(40 + i * 20))); try? await Task.sleep(nanoseconds: 150_000_000) }
        QuickAccess.shared.pinNewestForTesting(3)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        QuickAccess.shared.openGroupMenuForTesting()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        mark("menu")
        try? await Task.sleep(nanoseconds: 9_000_000_000)
        QuickAccess.shared.openGroupMenuForTesting() // close

        // A GIF preview
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("fg-demo2-\(UUID().uuidString).mp4")
        let gif = clip.deletingPathExtension().appendingPathExtension("gif")
        if await makeClip(at: clip, seconds: 3, fps: 10, size: CGSize(width: 480, height: 300)) {
            try? await GIFConverter.convert(video: clip, to: gif, fps: 8, maxWidth: 320)
            QuickAccess.shared.presentMedia(gif, isGIF: true, scale: 1, showingActions: true)
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        mark("gif")
        try? await Task.sleep(nanoseconds: 9_000_000_000)

        // The setup bar, in MP4 and then GIF
        UserDefaults.standard.set("mp4", forKey: PrefKey.recFormat)
        Task { _ = await RecordingSetup.ask(on: screen, summary: "Recording 800 × 600", allowWebcam: true) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        mark("setup-mp4")
        try? await Task.sleep(nanoseconds: 9_000_000_000)
        EscapeCatcher.shared.fire()
        try? await Task.sleep(nanoseconds: 500_000_000)
        UserDefaults.standard.set("gif", forKey: PrefKey.recFormat)
        Task { _ = await RecordingSetup.ask(on: screen, summary: "Recording 800 × 600", allowWebcam: true) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        mark("setup-gif")
        try? await Task.sleep(nanoseconds: 9_000_000_000)
        EscapeCatcher.shared.fire()
        UserDefaults.standard.set("mp4", forKey: PrefKey.recFormat)
        try? await Task.sleep(nanoseconds: 500_000_000)

        // The countdown, with the app in the background
        Task { await CountdownHUD.run(seconds: 5, on: screen) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        mark("countdown")
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        mark("done")
    }

    /// Puts previews, a pinned stack and a video preview on screen for a while so each window can be photographed.
    private static func runDemo() async {
        func picture(_ w: Int, _ h: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> CGImage {
            Gfx.render(width: w, height: h) { ctx in
                ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
                ctx.fill(CGRect(x: w / 8, y: h / 3, width: w * 3 / 4, height: max(2, h / 12)))
            }!
        }
        let marker = CommandLine.arguments.last(where: { $0.hasSuffix(".txt") }) ?? "/tmp/framegrab-demo.txt"
        func mark(_ text: String) { try? text.write(toFile: marker, atomically: true, encoding: .utf8); print("demo:", text) }

        // 1. Different shapes, with Copy / Save showing on the newest
        QuickAccess.shared.present(picture(60, 40, 220, 90, 60))
        try? await Task.sleep(nanoseconds: 500_000_000)
        QuickAccess.shared.present(picture(1600, 200, 60, 140, 90))
        try? await Task.sleep(nanoseconds: 500_000_000)
        QuickAccess.shared.present(picture(300, 900, 90, 70, 180))
        try? await Task.sleep(nanoseconds: 500_000_000)
        QuickAccess.shared.present(picture(1200, 700, 40, 120, 220), showingActions: true)
        try? await Task.sleep(nanoseconds: 800_000_000)
        QuickAccess.shared.simulateHoverForTesting()
        mark("shapes")
        try? await Task.sleep(nanoseconds: 14_000_000_000)

        // 2. Pin two, add a new one
        QuickAccess.shared.pinNewestForTesting(2)
        QuickAccess.shared.present(picture(900, 600, 200, 160, 40), showingActions: true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        mark("pinned")
        try? await Task.sleep(nanoseconds: 12_000_000_000)

        // 3. Fill the screen so everything folds into the group, then open its list
        for i in 0..<8 { QuickAccess.shared.present(picture(800, 500, UInt8(30 + i * 20), 100, 160)); try? await Task.sleep(nanoseconds: 200_000_000) }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        mark("folded")
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        QuickAccess.shared.openGroupMenuForTesting()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        mark("menu")
        try? await Task.sleep(nanoseconds: 12_000_000_000)

        // 4. A video preview
        QuickAccess.shared.openGroupMenuForTesting()
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("fg-demo-\(UUID().uuidString).mp4")
        if await makeClip(at: clip, seconds: 4, fps: 10, size: CGSize(width: 640, height: 360)) {
            QuickAccess.shared.presentMedia(clip, isGIF: false, scale: 1, showingActions: true)
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        mark("video")
        try? await Task.sleep(nanoseconds: 12_000_000_000)

        // 5. The video trimmer and the photo editor
        VideoEditor.open(clip)
        Editor.open(picture(1000, 600, 70, 100, 150))
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        mark("editors dock=\(NSApp.activationPolicy() == .regular)")
        try? await Task.sleep(nanoseconds: 14_000_000_000)
        mark("done")
    }

    /// Quick check of the screenshot paths (fullscreen with Tack's own windows open, area, window).
    private static func runCapture() async {
        print("capture: preflight", CGPreflightScreenCaptureAccess())
        guard CGPreflightScreenCaptureAccess() else { return }
        do {
            // Open some of our own windows so the capture has to deal with them.
            (NSApp.delegate as? AppDelegate)?.showSettings()
            QuickAccess.shared.present(solid(300, 200, 40, 120, 220))
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            print("capture: asking for shareable content")
            let content = try await CaptureService.shareable()
            print("capture: windows", content.windows.count)
            guard let screen = NSScreen.screens.first else { return }
            let display = try CaptureService.display(for: screen, in: content)
            let full = try await CaptureService.grab(display: display, content: content, sourceRect: nil)
            check("capture: fullscreen grab works with our windows open", full.width > 0, "\(full.width)x\(full.height)")
            let area = try await CaptureService.grabRegion(screen: screen, rect: CGRect(x: 100, y: 100, width: 300, height: 200), content: content)
            check("capture: area grab works", area.width > 0, "\(area.width)x\(area.height)")
            if let w = CaptureService.windowCandidatesForTesting(content).first {
                let img = try await CaptureService.grab(window: w)
                check("capture: window grab works", img.width > 0)
            }
            if let png = NSBitmapImageRep(cgImage: full).representation(using: .png, properties: [:]) {
                let out = CommandLine.arguments.last(where: { $0.hasSuffix(".png") }) ?? "/tmp/framegrab-capture.png"
                try? png.write(to: URL(fileURLWithPath: out))
                print("capture: wrote", out)
            }
        } catch {
            check("capture: pipeline", false, error.localizedDescription)
        }
    }

    private static func runLive() async {
        guard CGPreflightScreenCaptureAccess() else {
            print("SKIP  Screen Recording is not allowed for Tack yet")
            return
        }
        do {
            let content = try await CaptureService.shareable()
            guard let screen = NSScreen.main else { return }
            let image = try await CaptureService.grabRegion(screen: screen, rect: CGRect(x: 100, y: 100, width: 300, height: 200), content: content)
            check("live: area capture returns an image", image.width > 0 && image.height > 0, "\(image.width)x\(image.height)")

            let display = try CaptureService.display(for: screen, in: content)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = screen.backingScaleFactor
            let session = RecordingSession(
                filter: filter,
                pixelSize: CGSize(width: 640 * scale, height: 400 * scale),
                sourceRect: CGRect(x: 0, y: 0, width: 640, height: 400),
                options: RecordingOptions(fps: 30, cursor: true, systemAudio: false, microphone: false)
            )
            session.onFailure = { print("live: recorder reported:", $0) }
            try await session.start()
            // Make the screen change so frames are produced.
            let wiggle = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            wiggle.orderFrontRegardless()
            for i in 0..<12 {
                wiggle.setFrameOrigin(NSPoint(x: 50 + i * 20, y: 80))
                try? await Task.sleep(nanoseconds: 150_000_000)
                if i == 5 { session.setPaused(true) }
                if i == 8 { session.setPaused(false) }
            }
            let ok = await session.stop()
            wiggle.orderOut(nil)
            check("live: recording finishes", ok)
            if ok {
                let asset = AVURLAsset(url: session.tempURL)
                let dur = (try? await asset.load(.duration).seconds) ?? 0
                let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                check("live: recording has a video track", tracks.count == 1)
                check("live: pause is cut out (about 1.2s of 1.8s)", dur > 0.6 && dur < 1.7, "duration=\(dur)")
                try await GIFConverter.convert(video: session.tempURL, to: session.tempURL.deletingPathExtension().appendingPathExtension("gif"), fps: 10, maxWidth: 320)
                check("live: recording converts to GIF", true)
                try? FileManager.default.removeItem(at: session.tempURL)
                try? FileManager.default.removeItem(at: session.tempURL.deletingPathExtension().appendingPathExtension("gif"))
            }
        } catch {
            check("live: capture pipeline", false, error.localizedDescription)
        }

        // Dock presence of the editor
        let sample = solid(300, 200, 255, 255, 255)
        check("editor: app starts menu-bar only", NSApp.activationPolicy() == .accessory)
        Editor.open(sample)
        check("editor: gets a Dock icon while open", NSApp.activationPolicy() == .regular)
        Editor.closeAllWithoutAsking()
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("editor: Dock icon goes away when closed", Editor.openCount == 0 && NSApp.activationPolicy() == .accessory)

        // Opening windows from the menu bar menu while another app is in front
        func tryOpening(_ name: String, _ action: HotkeyAction) async {
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
            try? await Task.sleep(nanoseconds: 800_000_000)
            let delegate = NSApp.delegate as? AppDelegate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { delegate?.perform(action) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let front = NSApp.isActive && (NSApp.keyWindow != nil)
            check("menu: \(name) comes to the front from the menu bar", front, "active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none") visible=\(NSApp.windows.filter { $0.isVisible }.map { $0.title })")
            NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }.forEach { $0.close() }
        }
        await tryOpening("Settings", .openSettings)
        await tryOpening("History", .showHistory)

        // Desktop switch while the picker is open: it must survive, refresh, and still cancel with Esc.
        var returned = false
        var gotNil = false
        Task {
            let r = await CaptureService.shared.pickTarget(allowSwitch: true)
            gotNil = (r == nil)
            returned = true
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        check("live: picker is open", !returned)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        check("live: picker survives a desktop switch", !returned)
        EscapeCatcher.shared.fire() // what the global Esc key does
        try? await Task.sleep(nanoseconds: 800_000_000)
        check("live: Esc closes the picker after a desktop switch", returned && gotNil)
    }

    /// Opens the editor and a preview with a sample image, then saves a picture of the screen so the layout can be inspected.
    private static func runUI() async {
        guard CGPreflightScreenCaptureAccess() else { print("SKIP no permission"); return }
        let sample = Gfx.render(width: 1200, height: 700) { ctx in
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(srgbRed: 0.95, green: 0.95, blue: 1, alpha: 1), CGColor(srgbRed: 0.8, green: 0.9, blue: 1, alpha: 1)] as CFArray, locations: nil)!
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 1200, y: 700), options: [])
            ("Tack sample screenshot" as NSString).draw(at: CGPoint(x: 60, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: NSColor.darkGray])
            ("Secret: 1234-5678" as NSString).draw(at: CGPoint(x: 60, y: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        }!
        if let screen = NSScreen.main {
            let frozen = Gfx.render(width: Int(screen.frame.width), height: Int(screen.frame.height)) { ctx in
                ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 4000))
                ("Selection overlay test" as NSString).draw(at: CGPoint(x: 100, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 60), .foregroundColor: NSColor.white])
            }!
            let view = SelectionView(screen: screen, frozen: frozen, targets: [], mode: .area, allowSwitch: true, onResult: { _ in })
            let panel = SelectionPanel(screen: screen, view: view)
            panel.orderFrontRegardless()
        }
        if let screen = NSScreen.main { Task { _ = await RecordingSetup.ask(on: screen, summary: "Recording 800 × 600", allowWebcam: true) } }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let base = CommandLine.arguments.last(where: { $0.hasSuffix(".png") }) ?? "/tmp/framegrab-ui.png"
        var n = 0
        for w in NSApp.windows where w.isVisible && w.contentView != nil {
            guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: base.replacingOccurrences(of: ".png", with: "-\(n).png"))
                try? data.write(to: url)
                print("saved \(url.path)  title=\(w.title) size=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
                n += 1
            }
        }
    }

    // MARK: visual showcase (real screenshots of Tack's own windows, glass included)

    private static func snap(_ name: String, dir: String, rect: CGRect? = nil) async {
        do {
            let content = try await CaptureService.shareable()
            guard let screen = NSScreen.main, let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }
            let scale = screen.backingScaleFactor
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.captureResolution = .best
            var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if let r = rect {
                let px = CGRect(x: r.minX * scale, y: (screen.frame.height - r.maxY) * scale, width: r.width * scale, height: r.height * scale)
                image = image.cropping(to: px) ?? image
            }
            if let data = ImageFormat.png.encode(image, quality: 1) {
                try data.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
                print("saved \(name)")
            }
        } catch {
            print("FAIL snap \(name): \(error)")
        }
    }

    /// Captures one of Tack's own windows by itself (nothing else on the screen is included).
    private static func snapWindow(_ name: String, dir: String, window: NSWindow) async {
        for attempt in 1...4 {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    print("FAIL snapWindow \(name): window not found"); return
                }
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let filter = SCContentFilter(desktopIndependentWindow: target)
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * scale)
                config.height = Int(window.frame.height * scale)
                config.captureResolution = .best
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                if let data = ImageFormat.png.encode(image, quality: 1) {
                    try data.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
                    print("saved \(name)")
                }
                return
            } catch {
                if attempt == 4 {
                    // Fall back to drawing the window's own contents (no blur, but fine for ordinary controls).
                    if let view = window.contentView?.superview ?? window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        if let data = rep.representation(using: .png, properties: [:]) {
                            try? data.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
                            print("saved \(name) (fallback)")
                            return
                        }
                    }
                    print("FAIL snapWindow \(name): \(error)")
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    private static func runShowcase() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.main else { print("SKIP"); return }
        let dir = CommandLine.arguments.last ?? "/tmp"
        let f = screen.frame

        // A colorful backdrop so glass has something to refract, and so your own screen is not captured.
        let backdrop = NSWindow(contentRect: f, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = .normal
        backdrop.isReleasedWhenClosed = false
        let art = Gfx.render(width: Int(f.width), height: Int(f.height)) { ctx in
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
                CGColor(srgbRed: 0.10, green: 0.14, blue: 0.35, alpha: 1), CGColor(srgbRed: 0.55, green: 0.25, blue: 0.75, alpha: 1), CGColor(srgbRed: 0.98, green: 0.55, blue: 0.35, alpha: 1),
            ] as CFArray, locations: [0, 0.55, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: f.width, y: f.height), options: [])
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.12))
            for i in 0..<9 { ctx.fill(CGRect(x: CGFloat(i) * f.width / 9, y: 0, width: 4, height: f.height)) }
            ("Sample desktop" as NSString).draw(at: CGPoint(x: 80, y: 80), withAttributes: [.font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        }!
        backdrop.contentView = NSImageView(image: NSImage(cgImage: art, size: f.size))
        backdrop.setFrame(f, display: true)
        backdrop.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 600_000_000)

        let sample = Gfx.render(width: 1200, height: 700) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.97, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 700))
            ("Tack" as NSString).draw(at: CGPoint(x: 60, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 80, weight: .bold), .foregroundColor: NSColor.darkGray])
        }!

        // 1. Screenshot preview, hovered
        QuickAccess.shared.present(sample)
        try? await Task.sleep(nanoseconds: 900_000_000)
        QuickAccess.shared.simulateHoverForTesting()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await snap("1-preview", dir: dir, rect: CGRect(x: 0, y: 0, width: 520, height: 330))

        // 2. Recording setup bar
        Task { _ = await RecordingSetup.ask(on: screen, summary: "Recording 1280 × 720", allowWebcam: true) }
        try? await Task.sleep(nanoseconds: 900_000_000)
        await snap("2-setup", dir: dir, rect: CGRect(x: f.midX - 380, y: 40, width: 760, height: 190))
        EscapeCatcher.shared.fire()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // 3. Recording controls
        let hud = RecordingHUD(screen: screen)
        hud.show()
        let clock = RecordingClock()
        hud.startTimer(clock: clock)
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        await snap("3-hud", dir: dir, rect: CGRect(x: f.midX - 200, y: 0, width: 400, height: 130))
        hud.close()

        // 5. Area selection overlay
        let frozen = Gfx.render(width: Int(f.width), height: Int(f.height)) { ctx in Gfx.draw(art, in: CGRect(x: 0, y: 0, width: f.width, height: f.height), ctx: ctx) }!
        let view = SelectionView(screen: screen, frozen: frozen, targets: [], mode: .area, allowSwitch: true, onResult: { _ in })
        let panel = SelectionPanel(screen: screen, view: view)
        panel.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 900_000_000)
        await snap("5-selection", dir: dir, rect: CGRect(x: f.midX - 300, y: 0, width: 600, height: 160))
        panel.orderOut(nil)

        // 6. Editor window
        Editor.open(sample)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if let w = NSApp.windows.first(where: { $0.styleMask.contains(.fullSizeContentView) && $0.isVisible }) {
            await snapWindow("6-editor", dir: dir, window: w)
        }
        Editor.closeAllWithoutAsking()

        // 7. Settings window
        (NSApp.delegate as? AppDelegate)?.showSettings()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if let w = NSApp.windows.first(where: { $0.title == "Tack Settings" && $0.isVisible }) {
            await snapWindow("7-settings", dir: dir, window: w)
            w.close()
        }

        // 8. History window
        HistoryWindow.show()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if let w = NSApp.windows.first(where: { $0.title == "Capture History" && $0.isVisible }) {
            await snapWindow("8-history", dir: dir, window: w)
            w.close()
        }

        // 9. Video editor
        let clipURL = FileManager.default.temporaryDirectory.appendingPathComponent("fg-showcase-\(UUID().uuidString).mp4")
        if await makeClip(at: clipURL, seconds: 6, fps: 10, size: CGSize(width: 640, height: 360)) {
            VideoEditor.open(clipURL)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let w = NSApp.windows.first(where: { $0.title == clipURL.lastPathComponent && $0.isVisible }) {
                await snapWindow("9-video", dir: dir, window: w)
                w.close()
            }
            try? FileManager.default.removeItem(at: clipURL)
        }
        backdrop.orderOut(nil)
    }
}
#endif
