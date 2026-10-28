import AppKit
import AVFoundation
import CoreGraphics

enum Permissions {
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        open("Privacy_ScreenCapture")
    }

    static func openMicrophoneSettings() {
        open("Privacy_Microphone")
    }

    static func openCameraSettings() {
        open("Privacy_Camera")
    }


    private static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Returns true if capture can proceed. Otherwise explains what to do.
    @MainActor
    static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        Alerts.screenRecordingNeeded()
        return false
    }
}

@MainActor
enum Alerts {
    static func show(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func show(_ error: Error) {
        show(title: "Capture failed", message: error.localizedDescription)
    }

    static func microphoneNeeded() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Microphone permission needed"
        alert.informativeText = "The recording will continue without your voice. To include it, turn on Tack in System Settings > Privacy & Security > Microphone, then record again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Continue Without Microphone")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openMicrophoneSettings()
        }
    }

    static func screenRecordingNeeded() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Tack needs Screen Recording access to take screenshots. In System Settings > Privacy & Security > Screen Recording, press the + button, choose Tack from Applications and turn it on, then quit and reopen Tack."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openScreenRecordingSettings()
        }
    }
}
