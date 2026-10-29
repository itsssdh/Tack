import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// Small observable box. Used instead of @State because @State needs a macro plugin that only ships with full Xcode.
final class Field<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, screenshots, recording, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .screenshots: return "Screenshots"
        case .recording: return "Recording"
        case .shortcuts: return "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .screenshots: return "viewfinder"
        case .recording: return "record.circle.fill"
        case .shortcuts: return "keyboard.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return Color(red: 0.55, green: 0.56, blue: 0.60)
        case .screenshots: return .blue
        case .recording: return .red
        case .shortcuts: return .indigo
        }
    }
}

/// A clear strip along the top of the window that drags it. The title bar is transparent and the content runs underneath it,
/// so without this the sidebar and panes swallow the mouse and the window cannot be moved.
private struct WindowDragArea: NSViewRepresentable {
    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The small colored rounded square next to each sidebar item, like System Settings.
private struct IconBadge: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
    }
}

struct SettingsView: View {
    @StateObject private var selection = Field(SettingsView.startingPane)

    /// General, unless a developer flag like `--settings-pane=recording` asks for another (used to photograph each pane).
    private static var startingPane: SettingsPane {
        #if FRAMEGRAB_TESTING
        for arg in CommandLine.arguments where arg.hasPrefix("--settings-pane=") {
            if let pane = SettingsPane(rawValue: String(arg.dropFirst("--settings-pane=".count))) { return pane }
        }
        #endif
        return .general
    }

    /// Sidebar order: General on its own, then headed groups.
    private static let groups: [(title: String?, panes: [SettingsPane])] = [
        (nil, [.general]),
        ("Capture", [.screenshots, .recording]),
        ("Controls", [.shortcuts]),
    ]

    /// The one accent color of the window: toggles, sliders and menus.
    private static let accent = settingsAccent

    var body: some View {
        // A plain fixed sidebar next to the pane. The system split view animates its sidebar open when the window
        // appears and fights the fixed window size, which showed as a push one way, a block, then a snap back.
        HStack(spacing: 0) {
            sidebar
                .frame(width: 224)
                .frame(maxHeight: .infinity)
                .background(SidebarBackground())

            Divider()

            VStack(spacing: 0) {
                header
                detail(for: selection.value)
                    .scrollContentBackground(.hidden)
                    .transaction { $0.animation = nil } // switching panes should be instant, not a cross-fade
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(Self.accent)
        .overlay(alignment: .top) {
            WindowDragArea().frame(height: 30)
        }
        .frame(width: 800, height: 600)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if let title = group.title {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 28)
                        .padding(.top, 22)
                        .padding(.bottom, 6)
                } else if index > 0 {
                    Spacer().frame(height: 10)
                }
                ForEach(group.panes) { pane in
                    SidebarRow(pane: pane, selected: selection.value == pane) { selection.value = pane }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 56) // room for the window buttons
        .padding(.horizontal, 12)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: selection.value.symbol, color: selection.value.color)
            Text(selection.value.title)
                .font(.system(size: 18, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    /// For the self-test: a picture of one whole pane, taller than the window, so nothing is hidden below the fold.
    @MainActor
    static func renderForTesting(_ pane: SettingsPane, height: CGFloat) -> NSImage? {
        let content = SettingsView().detailForRender(pane).frame(width: 576, height: height).background(Color(red: 0.16, green: 0.16, blue: 0.17)).tint(settingsAccent)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 576, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)) // off screen
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    @ViewBuilder
    fileprivate func detailForRender(_ pane: SettingsPane) -> some View { detail(for: pane) }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralTab()
        case .screenshots: ScreenshotsTab()
        case .recording: RecordingTab()
        case .shortcuts: ShortcutsTab()
        }
    }
}

/// One sidebar item: a colored badge and a title, with a soft rounded highlight when selected.
private struct SidebarRow: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @StateObject private var hovering = Field(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                IconBadge(symbol: pane.symbol, color: pane.color)
                Text(pane.title)
                    .font(.system(size: 14))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.12 : (hovering.value ? 0.06 : 0)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
    }
}

/// The sidebar's own material, a little different from the pane beside it.
private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .withinWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: Building blocks (rounded cards with rows, like Alcove's settings)

/// The one accent color of the window: toggles, sliders, menus and the ring around a chosen tile.
private let settingsAccent = Color(red: 0.43, green: 0.82, blue: 0.73)

/// A scrolling page of sections.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(.horizontal, 26)
                .padding(.top, 6)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A small grey heading above a card.
private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            .padding(.top, 14)
    }
}

/// A rounded box holding rows, separated by hairlines.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
    }
}

private struct CardDivider: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
}

/// Small grey explanation under a card.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One line in a card: a title (and optional smaller line under it) on the left, a control on the right.
private struct Row<Trailing: View>: View {
    let title: String
    var detail: String?
    var truncateDetail = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(truncateDetail ? 1 : nil)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: !truncateDetail)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 46)
    }
}

private struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Row(title: title, detail: detail) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

/// A title with a pop-up menu on the right.
private struct MenuRow<V: Hashable>: View {
    let title: String
    @Binding var selection: V
    let options: [(label: String, value: V)]

    var body: some View {
        Row(title: title) {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { Text(options[$0].label).tag(options[$0].value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

/// A full-width tappable line in the accent color (or red for something destructive).
private struct ActionRow: View {
    let title: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(destructive ? Color.red : settingsAccent)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small rounded value shown at the right of a title, like "3 s".
private struct ValuePill: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

/// A row of pictures to choose between. The chosen one gets a ring in the accent color and a bolder label.
private struct TileChoice<V: Hashable, Icon: View>: View {
    @Binding var selection: V
    let options: [(label: String, value: V)]
    @ViewBuilder var icon: (V) -> Icon

    var body: some View {
        HStack(spacing: 12) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let chosen = option.value == selection
                VStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.07))
                        icon(option.value)
                    }
                    .frame(height: 62)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(chosen ? settingsAccent : Color.primary.opacity(0.1), lineWidth: chosen ? 2.5 : 1)
                    )
                    Text(option.label)
                        .font(.system(size: 13, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Color.primary : Color.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { selection = option.value }
            }
        }
        .padding(14)
    }
}

/// A tiny screen with a small card in one corner, for choosing where previews appear.
private struct CornerDiagram: View {
    let corner: String
    let size: CGFloat

    var body: some View {
        ZStack(alignment: alignment) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.5)
                .frame(width: 58, height: 38)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.primary.opacity(0.65))
                .frame(width: size * 0.9, height: size * 0.65)
                .padding(5)
        }
        .frame(width: 58, height: 38)
    }

    private var alignment: Alignment {
        switch corner {
        case "bottomRight": return .bottomTrailing
        case "topLeft": return .topLeading
        case "topRight": return .topTrailing
        default: return .bottomLeading
        }
    }
}

// MARK: General

private struct GeneralTab: View {
    @AppStorage(PrefKey.appearance) private var appearance = "system"
    @AppStorage(PrefKey.playSound) private var playSound = true
    @StateObject private var screenOK = Field(Permissions.screenRecordingGranted)
    @StateObject private var micOK = Field(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    @StateObject private var cameraOK = Field(AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
    /// Read once, off the main thread: asking the system for the login item state is slow and the body runs often.
    @StateObject private var launchAtLogin = Field(false)
    @StateObject private var loginError = Field<String?>(nil)
    @StateObject private var autoUpdate = Field(Updater.shared.installsAutomatically)

    @StateObject private var showScreenHelp = Field(UserDefaults.standard.bool(forKey: "askedForScreenRecording"))

    /// macOS only lists an app under Microphone after the app has asked once, so ask first; open System Settings only if
    /// the question was already answered (there it can be changed).
    private func askForMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { micOK.value = granted }
            }
        } else {
            Permissions.openMicrophoneSettings()
        }
    }

    /// Same for the camera.
    private func askForCamera() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { cameraOK.value = granted }
            }
        } else {
            Permissions.openCameraSettings()
        }
    }

    /// Tack is not listed under Screen Recording until the person adds it, so open the list and say how.
    private func askForScreenRecording() {
        UserDefaults.standard.set(true, forKey: "askedForScreenRecording")
        showScreenHelp.value = true
        Permissions.openScreenRecordingSettings()
    }

    private func askToReset() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset all settings and shortcuts?"
        alert.informativeText = "This also removes Tack's Screen Recording, Microphone and Camera permissions, so macOS will ask again, and Tack restarts. Your saved screenshots and your history are not touched."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Prefs.resetAll()
        HotkeyManager.shared.resetAll()
        Prefs.applyAppearance()
        if let id = Bundle.main.bundleIdentifier {
            let tccutil = Process()
            tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            tccutil.arguments = ["reset", "All", id]
            try? tccutil.run()
            tccutil.waitUntilExit()
        }
        // macOS keeps reporting Screen Recording as granted to a running app, so start again to show the real state.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    var body: some View {
        SettingsPage {
            SectionTitle("Appearance")
            Card {
                TileChoice(
                    selection: Binding(get: { appearance }, set: { appearance = $0; Prefs.applyAppearance() }),
                    options: [("Match system", "system"), ("Light", "light"), ("Dark", "dark")]
                ) { value in
                    Image(systemName: value == "light" ? "sun.max.fill" : (value == "dark" ? "moon.fill" : "circle.lefthalf.filled"))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            SectionTitle("Behavior")
            Card {
                ToggleRow(title: "Launch at login", isOn: Binding(
                    get: { launchAtLogin.value },
                    set: { on in
                        do {
                            if on {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginError.value = nil
                        } catch {
                            loginError.value = "Could not change this: \(error.localizedDescription) (it works best when the app is in /Applications)."
                        }
                        launchAtLogin.value = SMAppService.mainApp.status == .enabled
                    }
                ))
                CardDivider()
                ToggleRow(title: "Play a sound after each capture", isOn: $playSound)
                CardDivider()
                ToggleRow(title: "Install updates automatically", isOn: Binding(
                    get: { autoUpdate.value },
                    set: { on in
                        Updater.shared.installsAutomatically = on
                        autoUpdate.value = on
                    }
                ))
                CardDivider()
                Row(title: "Check for updates", detail: "You have version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")") {
                    Button("Check Now") { Updater.shared.checkForUpdates() }
                }
            }
            if let message = loginError.value {
                Text(message).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 6)
            }

            SectionTitle("Permissions")
            Card {
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Needed for screenshots and recordings. Nothing leaves this Mac.",
                    granted: screenOK.value,
                    buttonTitle: showScreenHelp.value ? "Open Settings" : "Allow…",
                    open: askForScreenRecording
                )
                if showScreenHelp.value, !screenOK.value {
                    Text("In the list that opens, press the + button, choose Tack from Applications, then turn it on and confirm with your password or Touch ID.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
                CardDivider()
                PermissionRow(
                    title: "Microphone",
                    detail: "Only used when you record the microphone.",
                    granted: micOK.value,
                    buttonTitle: AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined ? "Allow…" : "Open Settings",
                    open: askForMicrophone
                )
                CardDivider()
                PermissionRow(
                    title: "Camera",
                    detail: "Only used when you turn on the webcam bubble in a recording.",
                    granted: cameraOK.value,
                    buttonTitle: AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined ? "Allow…" : "Open Settings",
                    open: askForCamera
                )
            }

            SectionTitle("Reset")
            Card {
                ActionRow(title: "Reset all settings and shortcuts…", destructive: true) { askToReset() }
            }
            Note("Your saved screenshots are not touched.")
        }
        .task {
            launchAtLogin.value = await Task.detached { SMAppService.mainApp.status == .enabled }.value
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenOK.value = Permissions.screenRecordingGranted
            micOK.value = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            cameraOK.value = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }
}

// MARK: Permission row

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    var buttonTitle = "Open Settings"
    let open: () -> Void

    var body: some View {
        Row(title: title, detail: detail) {
            HStack(spacing: 10) {
                Text(granted ? "Allowed" : "Not allowed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(granted ? Color.green : Color.orange)
                if !granted {
                    Button(buttonTitle, action: open)
                }
            }
            .fixedSize()
        }
    }
}

// MARK: Screenshots

private struct ScreenshotsTab: View {
    @AppStorage(PrefKey.showCursor) private var showCursor = false
    @AppStorage(PrefKey.aspectRatio) private var aspect = "none"
    @AppStorage(PrefKey.fixedWidth) private var fixedWidth = 0
    @AppStorage(PrefKey.fixedHeight) private var fixedHeight = 0
    @AppStorage(PrefKey.screenshotFolder) private var folder = ""
    @AppStorage(PrefKey.imageFormat) private var format = ImageFormat.png.rawValue
    @AppStorage(PrefKey.jpegQuality) private var quality = 0.9
    @AppStorage(PrefKey.filenameTemplate) private var template = "Screenshot {date} at {time}"
    @AppStorage(PrefKey.overlayCorner) private var corner = "bottomLeft"
    @AppStorage(PrefKey.overlaySize) private var previewSize = "medium"

    /// Width of a number box that fits its digits (about 8 pt each) with a little room to type in.
    private static func fieldWidth(for value: Int) -> CGFloat {
        CGFloat(max(1, String(value).count)) * 8 + 4
    }

    var body: some View {
        SettingsPage {
            SectionTitle("Save location")
            Card {
                Row(title: "Save screenshots to", detail: folder.isEmpty ? Prefs.screenshotFolder.path : folder, truncateDetail: true) {
                    HStack(spacing: 8) {
                        if !folder.isEmpty { Button("Reset") { folder = "" } }
                        Button("Choose…") { chooseFolder() }
                    }
                }
            }

            SectionTitle("Capture")
            Card {
                ToggleRow(title: "Include the mouse cursor", isOn: $showCursor)
                CardDivider()
                MenuRow(title: "Lock aspect ratio", selection: $aspect, options: [
                    ("Off", "none"), ("1:1", "1:1"), ("4:3", "4:3"), ("3:2", "3:2"),
                    ("16:9", "16:9"), ("16:10", "16:10"), ("9:16", "9:16"),
                ])
                CardDivider()
                Row(title: "Fixed size") {
                    // Plain fields inside one rounded box, so "0 × 0" reads as a single, evenly spaced control.
                    HStack(spacing: 6) {
                        TextField("Width", value: $fixedWidth, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: Self.fieldWidth(for: fixedWidth))
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", value: $fixedHeight, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.leading)
                            .frame(width: Self.fieldWidth(for: fixedHeight))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
                }
            }
            Note("Set both sizes above 0 to capture one exact size with a click. Hold Shift while dragging to keep a square.")

            SectionTitle("Saving")
            Card {
                MenuRow(title: "Format", selection: $format, options: ImageFormat.allCases.map { ($0.label, $0.rawValue) })
                if format == ImageFormat.jpeg.rawValue {
                    CardDivider()
                    VStack(spacing: 10) {
                        HStack {
                            Text("JPEG quality").font(.system(size: 14))
                            Spacer()
                            ValuePill("\(Int(quality * 100))%")
                        }
                        Slider(value: $quality, in: 0.3...1.0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                CardDivider()
                Row(title: "File name") {
                    TextField("", text: $template)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 260)
                }
            }
            Note("Use {date} and {time} in the name. Existing files are never overwritten.")

            SectionTitle("Preview corner")
            Card {
                TileChoice(selection: $corner, options: [
                    ("Bottom left", "bottomLeft"), ("Bottom right", "bottomRight"),
                    ("Top left", "topLeft"), ("Top right", "topRight"),
                ]) { value in
                    CornerDiagram(corner: value, size: 14)
                }
            }

            SectionTitle("Preview size")
            Card {
                TileChoice(selection: $previewSize, options: [("Small", "small"), ("Medium", "medium"), ("Large", "large")]) { value in
                    CornerDiagram(corner: corner, size: value == "small" ? 11 : (value == "large" ? 20 : 15))
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where screenshots are saved"
        panel.directoryURL = Prefs.screenshotFolder
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
        }
    }
}

// MARK: Recording

/// What goes into a recording (sound, microphone, webcam, cursor, clicks, MP4 or GIF) is chosen on the bar that appears
/// before each recording, so only the settings that bar does not have are here.
private struct RecordingTab: View {
    @AppStorage(PrefKey.recFPS) private var fps = 30
    @AppStorage(PrefKey.recCountdown) private var countdown = 3
    @AppStorage(PrefKey.recFolder) private var folder = ""
    @AppStorage(PrefKey.gifFPS) private var gifFPS = 12
    @AppStorage(PrefKey.gifWidth) private var gifWidth = 800

    var body: some View {
        SettingsPage {
            SectionTitle("Recording")
            Card {
                MenuRow(title: "Frame rate", selection: $fps, options: [("15", 15), ("30", 30), ("60", 60)])
                CardDivider()
                MenuRow(title: "Countdown", selection: $countdown, options: [("None", 0), ("3 seconds", 3), ("5 seconds", 5)])
            }

            SectionTitle("GIF")
            Card {
                MenuRow(title: "Frame rate", selection: $gifFPS, options: [("8", 8), ("12", 12), ("15", 15), ("20", 20)])
                CardDivider()
                MenuRow(title: "Maximum width", selection: $gifWidth, options: [("480", 480), ("800", 800), ("1200", 1200)])
            }

            SectionTitle("Saving")
            Card {
                Row(title: "Folder", detail: folder.isEmpty ? Prefs.recordingFolder.path : folder, truncateDetail: true) {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                    }
                }
            }
        }
    }
}

// MARK: Shortcuts

private struct ShortcutsTab: View {
    @StateObject private var refreshID = Field(UUID())
    /// Whether Apple's own screenshot shortcuts are on. Decides if the button replaces them or puts them back.
    @StateObject private var appleOn = Field(NativeScreenshots.anyEnabled)
    @StateObject private var replaceError = Field<String?>(nil)

    var body: some View {
        SettingsPage {
            // Offered at the top while Apple's shortcuts are on; once replaced, the way back moves to the bottom of the page.
            if appleOn.value {
                Card {
                    ActionRow(title: "Replace Apple’s screenshot shortcuts with Tack") {
                        change(NativeScreenshots.replaceWithTack(), nowOn: false)
                    }
                }
                Note("Turns off macOS’s built-in screenshot shortcuts (⇧⌘3, ⇧⌘4, ⇧⌘5 and the copy versions) so Tack answers them instead. No extra permission is needed. If an old shortcut still responds, log out and back in.")
                errorLine
            }

            SectionTitle("Global shortcuts")
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { CardDivider() }
                        ShortcutRow(action: action)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(minHeight: 46)
                    }
                }
                .id(refreshID.value)
            }

            Card {
                ActionRow(title: "Restore default shortcuts") {
                    HotkeyManager.shared.resetAll()
                    refreshID.value = UUID()
                }
            }
            .padding(.top, 14)

            if !appleOn.value {
                Card {
                    ActionRow(title: "Restore Apple’s screenshot shortcuts") {
                        change(NativeScreenshots.restoreApple(), nowOn: true)
                    }
                }
                .padding(.top, 6)
                Note("Turns macOS’s built-in screenshot shortcuts back on. Tack’s Area, Fullscreen and Window shortcuts move to ⌃⇧4, ⌃⇧3 and ⌃⇧5 so they do not clash; you can change them above.")
                errorLine
            }
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let message = replaceError.value {
            Text(message).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 6)
        }
    }

    private func change(_ error: String?, nowOn: Bool) {
        replaceError.value = error
        guard error == nil else { return }
        appleOn.value = nowOn
        refreshID.value = UUID()
    }
}

private struct ShortcutRow: View {
    let action: HotkeyAction
    @StateObject private var shortcut: Field<Shortcut>
    @StateObject private var recording = Field(false)
    @StateObject private var message = Field<String?>(nil)
    @StateObject private var monitor = Field<Any?>(nil)

    init(action: HotkeyAction) {
        self.action = action
        _shortcut = StateObject(wrappedValue: Field(HotkeyManager.shared.shortcut(for: action)))
    }

    var body: some View {
        HStack {
            Text(action.title)
            Spacer()
            if let text = message.value {
                Text(text).font(.caption).foregroundStyle(.red)
            }
            Button(recording.value ? "Press keys…" : shortcut.value.display) { toggleRecording() }
                .frame(width: 92)
            Button {
                HotkeyManager.shared.resetShortcut(for: action)
                shortcut.value = HotkeyManager.shared.shortcut(for: action)
                message.value = nil
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help("Restore default")
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if recording.value { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        recording.value = true
        message.value = nil
        let action = self.action
        let shortcut = self.shortcut
        let message = self.message
        let recording = self.recording
        let monitorBox = self.monitor
        monitorBox.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            func stop() {
                recording.value = false
                if let m = monitorBox.value {
                    NSEvent.removeMonitor(m)
                    monitorBox.value = nil
                }
            }
            if event.keyCode == 53 { // Esc cancels
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let mods = Shortcut.carbonModifiers(from: flags)
            if mods == 0 {
                message.value = "Include ⌃ ⌥ ⇧ or ⌘."
                return nil
            }
            let new = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
            if let error = HotkeyManager.shared.setShortcut(new, for: action) {
                message.value = error
            } else {
                shortcut.value = new
                message.value = nil
            }
            stop()
            return nil
        }
    }

    private func stopRecording() {
        recording.value = false
        if let m = monitor.value {
            NSEvent.removeMonitor(m)
            monitor.value = nil
        }
    }
}
