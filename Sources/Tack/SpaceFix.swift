import AppKit
import ObjectiveC

/// Keeps Tack's windows with you when another app is in full screen.
///
/// A normal window belongs to the desktop it first opened on. Showing it later while a full-screen app is in front makes macOS
/// switch you back to that desktop, and a window made by a library (the updater's, or a standard alert) can only be marked
/// otherwise by catching it as it is shown. So every window that can take the keyboard is marked, just before it is ordered
/// in, to open on whichever desktop is active, full-screen ones included. Windows that already chose (the editors, the
/// capture overlay) are left alone.
@MainActor
enum SpaceFix {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        swap(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.tack_makeKeyAndOrderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFront(_:)), #selector(NSWindow.tack_orderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFrontRegardless), #selector(NSWindow.tack_orderFrontRegardless))
        swap(NSApplication.self, #selector(NSApplication.runModal(for:)), #selector(NSApplication.tack_runModal(for:)))
        swap(NSAlert.self, #selector(NSAlert.runModal), #selector(NSAlert.tack_runModal))
        swap(NSWindow.self, #selector(NSWindow.orderOut(_:)), #selector(NSWindow.tack_orderOut(_:)))
        swap(NSWindow.self, #selector(NSWindow.close), #selector(NSWindow.tack_close))
    }

    /// The updater's own windows ("Checking for updates", the new-version window, the download and install progress).
    static func isUpdaterWindow(_ window: NSWindow) -> Bool {
        guard let controller = window.windowController else { return false }
        return NSStringFromClass(type(of: controller)).hasPrefix("SU")
    }

    /// While Settings is open on the active desktop, an updater window goes onto it as a sheet instead of opening on its own,
    /// so there is nothing to switch away to. Returns true when it did, so the window is not also ordered in by itself.
    static func attachAsSheet(_ window: NSWindow) -> Bool {
        guard isUpdaterWindow(window), window.sheetParent == nil,
              let host = (NSApp.delegate as? AppDelegate)?.sheetHost, window !== host else { return false }
        if host.sheets.contains(window) { return true }
        host.beginSheet(window, completionHandler: nil) // if another sheet is showing, this one waits its turn
        return true
    }

    /// An updater window that was shown as a sheet has to be ended as one before it can go away.
    static func detach(_ window: NSWindow) {
        if let parent = window.sheetParent { parent.endSheet(window) }
    }

    static func prepare(_ window: NSWindow) {
        guard window.canBecomeKey else { return }
        guard window.collectionBehavior.isDisjoint(with: [.canJoinAllSpaces, .moveToActiveSpace]) else { return }
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
    }

    private static func swap(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(type, original), let b = class_getInstanceMethod(type, replacement) else { return }
        method_exchangeImplementations(a, b)
    }
}

extension NSWindow {
    // After the swap these names run the original code, so each one marks the window and then carries on as normal.
    @objc func tack_makeKeyAndOrderFront(_ sender: Any?) {
        if SpaceFix.attachAsSheet(self) { return }
        SpaceFix.prepare(self)
        tack_makeKeyAndOrderFront(sender)
    }
    @objc func tack_orderFront(_ sender: Any?) {
        if SpaceFix.attachAsSheet(self) { return }
        SpaceFix.prepare(self)
        tack_orderFront(sender)
    }
    @objc func tack_orderFrontRegardless() {
        if SpaceFix.attachAsSheet(self) { return }
        SpaceFix.prepare(self)
        tack_orderFrontRegardless()
    }
    @objc func tack_orderOut(_ sender: Any?) { SpaceFix.detach(self); tack_orderOut(sender) }
    @objc func tack_close() { SpaceFix.detach(self); tack_close() }
}

extension NSApplication {
    @objc func tack_runModal(for window: NSWindow) -> NSApplication.ModalResponse {
        SpaceFix.prepare(window)
        return tack_runModal(for: window)
    }
}

extension NSAlert {
    /// An alert shown while Settings is open on the active desktop (for example the updater's "You're up to date")
    /// slides down from the Settings window instead of opening a window of its own, so you are never taken to another desktop.
    /// It still waits for your answer and returns it, exactly like a normal alert.
    @objc func tack_runModal() -> NSApplication.ModalResponse {
        guard let host = (NSApp.delegate as? AppDelegate)?.sheetHost, host.attachedSheet == nil, window.sheetParent == nil else {
            return tack_runModal() // the original
        }
        beginSheetModal(for: host) { NSApp.stopModal(withCode: $0) }
        return NSApp.runModal(for: window)
    }
}
