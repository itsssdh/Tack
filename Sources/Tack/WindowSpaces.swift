import AppKit

// macOS has no public way to say "put this window on a normal desktop". A new window takes the desktop that is showing when it is made,
// even a full-screen app's, and keeps it, so every later opening would pull you back into that app. These are the same system calls
// other window managers use; each is looked up when needed, and if one is missing or refuses, the window simply stays where it is.
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray?
@_silgen_name("CGSSpaceGetType") private func CGSSpaceGetType(_ connection: Int32, _ space: Int) -> Int32
@_silgen_name("CGSMoveWindowsToManagedSpace") private func CGSMoveWindowsToManagedSpace(_ connection: Int32, _ windows: CFArray, _ space: Int)

@MainActor
enum WindowSpaces {
    private static let desktopType: Int32 = 0

    /// Puts the window on a normal desktop: the one you are on, or, from a full-screen app, the first desktop on that screen
    /// (macOS then takes you there when the window is shown). Returns false when it could not tell or move anything.
    @discardableResult
    static func placeOnDesktop(_ window: NSWindow) -> Bool {
        guard window.windowNumber > 0 else { return false }
        let connection = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]], !displays.isEmpty else { return false }

        // The display the window is on (it was centered on the screen with the pointer).
        let display = displays.first { ($0["Display Identifier"] as? String) == identifier(of: window.screen ?? NSScreen.main) } ?? displays[0]
        let spaces = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["ManagedSpaceID"] as? Int }
        guard let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int else { return false }

        let target = CGSSpaceGetType(connection, current) == desktopType ? current : spaces.first { CGSSpaceGetType(connection, $0) == desktopType }
        guard let target else { return false }
        CGSMoveWindowsToManagedSpace(connection, [window.windowNumber] as CFArray, target)
        return true
    }

    /// The identifier macOS uses for a display in its list of desktops.
    private static func identifier(of screen: NSScreen?) -> String? {
        guard let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) as String? else { return nil }
        return text
    }
}
