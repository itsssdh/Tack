import AppKit

/// While an editor window (photo or video) or the Settings window is open Tack becomes a normal app, so it appears in the Dock with its
/// own icon (the same one everywhere) and its windows stay reachable. When the last one closes it goes back to the menu bar only,
/// unless "Show in Dock" is on in Settings, which keeps it in the Dock all the time.
@MainActor
enum DockPresence {
    static var settingsOpen = false

    static func refresh() {
        let wanted: NSApplication.ActivationPolicy = (Prefs.showInDock || Editor.openCount + VideoEditor.openCount > 0 || settingsOpen) ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
        NSApp.applicationIconImage = nil // the app's own icon from the bundle
    }
}
