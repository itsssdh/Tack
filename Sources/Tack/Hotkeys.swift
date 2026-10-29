import AppKit
import Carbon.HIToolbox

enum HotkeyAction: String, CaseIterable, Identifiable {
    case captureArea
    case captureWindow
    case captureFullscreen
    case capturePrevious
    case captureText
    case capturePinned
    case recordScreen
    case openEditor
    case showHistory
    case openSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .captureFullscreen: return "Capture Fullscreen"
        case .capturePrevious: return "Capture Previous Area"
        case .captureText: return "Capture Text / QR (OCR)"
        case .capturePinned: return "Capture and Pin to Screen"
        case .recordScreen: return "Start / Stop Screen Recording"
        case .openEditor: return "Open Annotation Editor"
        case .showHistory: return "Show Capture History"
        case .openSettings: return "Open Settings"
        }
    }

    var defaultShortcut: Shortcut {
        let ctrlShift = UInt32(controlKey | shiftKey)
        let cmdShift = UInt32(cmdKey | shiftKey)
        switch self {
        case .captureArea: return Shortcut(keyCode: 21, modifiers: cmdShift)       // ⇧⌘4
        case .captureWindow: return Shortcut(keyCode: 23, modifiers: cmdShift)     // ⇧⌘5
        case .captureFullscreen: return Shortcut(keyCode: 20, modifiers: cmdShift) // ⇧⌘3
        case .capturePrevious: return Shortcut(keyCode: 35, modifiers: ctrlShift)  // P
        case .captureText: return Shortcut(keyCode: 17, modifiers: cmdShift)       // ⇧⌘T
        case .capturePinned: return Shortcut(keyCode: 40, modifiers: ctrlShift)    // K
        case .recordScreen: return Shortcut(keyCode: 22, modifiers: cmdShift)     // ⇧⌘6
        case .openEditor: return Shortcut(keyCode: 14, modifiers: ctrlShift)       // E
        case .showHistory: return Shortcut(keyCode: 4, modifiers: ctrlShift)       // H
        case .openSettings: return Shortcut(keyCode: 43, modifiers: ctrlShift)     // ,
        }
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier flags

    static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    var keyName: String { Shortcut.keyNames[keyCode] ?? "Key \(keyCode)" }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    /// Single character for showing the shortcut next to a menu item (letters, digits, punctuation only).
    var menuKeyEquivalent: String {
        let name = keyName
        return name.count == 1 ? name.lowercased() : ""
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
        return m
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

// C callback: must not capture context.
private let hotKeyHandler: EventHandlerUPP = { _, event, _ in
    var hkID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkID
    )
    if status == noErr {
        let id = hkID.id
        Task { @MainActor in
            HotkeyManager.shared.fire(id: id)
        }
    }
    return noErr
}

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onAction: ((HotkeyAction) -> Void)?

    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private let signature: OSType = 0x46474252 // 'FGBR'

    private func hotKeyID(for action: HotkeyAction) -> UInt32 {
        UInt32((HotkeyAction.allCases.firstIndex(of: action) ?? 0) + 1)
    }

    fileprivate func fire(id: UInt32) {
        if id == EscapeCatcher.hotKeyID { EscapeCatcher.shared.fire(); return }
        let index = Int(id) - 1
        guard index >= 0, index < HotkeyAction.allCases.count else { return }
        onAction?(HotkeyAction.allCases[index])
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
        handlerInstalled = true
    }

    // MARK: Storage

    func shortcut(for action: HotkeyAction) -> Shortcut {
        if let data = UserDefaults.standard.data(forKey: "shortcut.\(action.rawValue)"),
           let s = try? JSONDecoder().decode(Shortcut.self, from: data) {
            return s
        }
        return action.defaultShortcut
    }

    private func store(_ shortcut: Shortcut?, for action: HotkeyAction) {
        let key = "shortcut.\(action.rawValue)"
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: Registration

    func registerAll() {
        installHandlerIfNeeded()
        for action in HotkeyAction.allCases {
            _ = register(action, shortcut(for: action))
        }
    }

    @discardableResult
    private func register(_ action: HotkeyAction, _ shortcut: Shortcut) -> Bool {
        unregister(action)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: hotKeyID(for: action))
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            refs[action] = ref
            return true
        }
        return false
    }

    private func unregister(_ action: HotkeyAction) {
        if let ref = refs[action] {
            UnregisterEventHotKey(ref)
            refs[action] = nil
        }
    }

    /// Returns an error message, or nil on success.
    func setShortcut(_ new: Shortcut, for action: HotkeyAction) -> String? {
        for other in HotkeyAction.allCases where other != action {
            if shortcut(for: other) == new {
                return "Already used by “\(other.title)”."
            }
        }
        let old = shortcut(for: action)
        if register(action, new) {
            store(new, for: action)
            return nil
        }
        _ = register(action, old)
        return "That shortcut is taken by macOS or another app."
    }

    func resetShortcut(for action: HotkeyAction) {
        store(nil, for: action)
        _ = register(action, action.defaultShortcut)
    }

    func resetAll() {
        for action in HotkeyAction.allCases {
            resetShortcut(for: action)
        }
    }
}


/// While a capture overlay is open, Esc cancels it even after you have swiped to another desktop
/// (when the overlay is no longer the window that receives key presses).
@MainActor
final class EscapeCatcher {
    static let shared = EscapeCatcher()
    nonisolated static let hotKeyID: UInt32 = 999

    private var ref: EventHotKeyRef?
    private var handler: (() -> Void)?

    func begin(_ handler: @escaping () -> Void) {
        self.handler = handler
        guard ref == nil else { return }
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x46474252, id: Self.hotKeyID)
        if RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &newRef) == noErr {
            ref = newRef
        }
    }

    func end() {
        handler = nil
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    func fire() {
        handler?()
    }
}
