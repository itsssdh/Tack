import AppKit
import Carbon.HIToolbox

/// Turns off macOS's own screenshot shortcuts so Tack can answer them instead.
/// These live in the user's keyboard-shortcut preferences (com.apple.symbolichotkeys); writing them needs no special permission.
@MainActor
enum NativeScreenshots {
    nonisolated static let domain = "com.apple.symbolichotkeys"

    /// (id, ascii, key code, modifiers) of each built-in screenshot shortcut.
    private static let shortcuts: [(id: Int, ascii: Int, keyCode: Int, modifiers: Int)] = [
        (28, 51, 20, 1_179_648),   // ⇧⌘3  save screen
        (29, 51, 20, 1_441_792),   // ⌃⇧⌘3 copy screen
        (30, 52, 21, 1_179_648),   // ⇧⌘4  save selection
        (31, 52, 21, 1_441_792),   // ⌃⇧⌘4 copy selection
        (184, 53, 23, 1_179_648),  // ⇧⌘5  screenshot options
    ]

    /// True while at least one of Apple's screenshot shortcuts is still on.
    static var anyEnabled: Bool {
        let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain as CFString) as? [String: Any] ?? [:]
        return shortcuts.contains { s in
            guard let entry = all[String(s.id)] as? [String: Any] else { return true } // not listed means the default, which is on
            if let on = entry["enabled"] as? Bool { return on }
            if let on = entry["enabled"] as? Int { return on != 0 }
            if let text = entry["enabled"] as? String { return text != "0" && text.lowercased() != "false" } // written as text by older versions
            return true
        }
    }

    /// Turns off Apple's screenshot shortcuts and gives ⇧⌘3 / ⇧⌘4 / ⇧⌘5 to Tack. Returns an error message, or nil on success.
    static func replaceWithTack() -> String? {
        if let error = setApple(enabled: false) { return error }
        for action in [HotkeyAction.captureArea, .captureFullscreen, .captureWindow] {
            HotkeyManager.shared.resetShortcut(for: action)
        }
        return nil
    }

    /// Undoes `replaceWithTack`: Apple's shortcuts come back, and Tack's Area / Fullscreen / Window move to
    /// ⌃⇧4 / ⌃⇧3 / ⌃⇧5 so the two do not fight over the same keys. Returns an error message, or nil on success.
    static func restoreApple() -> String? {
        if let error = setApple(enabled: true) { return error }
        let ctrlShift = UInt32(controlKey | shiftKey)
        let moved: [(HotkeyAction, UInt32)] = [(.captureArea, 21), (.captureFullscreen, 20), (.captureWindow, 23)]
        for (action, keyCode) in moved {
            _ = HotkeyManager.shared.setShortcut(Shortcut(keyCode: keyCode, modifiers: ctrlShift), for: action)
        }
        return nil
    }

    /// Writes real booleans. (The `defaults write -dict-add` command stores "1" and "0" as strings, which macOS ignores.)
    static func setApple(enabled: Bool, in domain: String = NativeScreenshots.domain) -> String? {
        var all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain as CFString) as? [String: Any] ?? [:]
        for s in shortcuts {
            var entry = all[String(s.id)] as? [String: Any] ?? [:]
            if entry["value"] == nil {
                entry["value"] = ["parameters": [s.ascii, s.keyCode, s.modifiers], "type": "standard"] as [String: Any]
            }
            entry["enabled"] = enabled
            all[String(s.id)] = entry
        }
        CFPreferencesSetAppValue("AppleSymbolicHotKeys" as CFString, all as CFPropertyList, domain as CFString)
        guard CFPreferencesAppSynchronize(domain as CFString) else {
            return "macOS would not let Tack change its shortcut settings."
        }
        // Ask the system to re-read the shortcuts so no log out is needed. Older and newer systems may not have this tool.
        guard domain == Self.domain else { return nil } // a test domain has nothing to re-read
        let activate = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        if FileManager.default.isExecutableFile(atPath: activate) { _ = run(activate, ["-u"]) }
        return nil
    }

    private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
