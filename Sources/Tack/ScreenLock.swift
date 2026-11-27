import AppKit

/// Knows whether the Mac's screen is locked, and keeps Tack out of the way until it is unlocked.
/// The lock screen belongs to macOS: Tack's shortcuts do not reach it and it cannot be captured, so Tack waits.
/// A recording that is already running is left alone.
@MainActor
final class ScreenLock {
    static let shared = ScreenLock()

    private(set) var isLocked = false

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenLock.shared.didLock() }
        }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenLock.shared.didUnlock() }
        }
    }

    private func didLock() {
        isLocked = true
        CaptureService.shared.cancelSelection()
    }

    private func didUnlock() {
        isLocked = false
        QuickAccess.shared.healAfterSpaceChange()
        PinManager.shared.bringAllToFront()
    }
}
