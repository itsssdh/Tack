import AppKit
import Sparkle

/// Checks for new versions of Tack (feed: the appcast on the project site) and installs them.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var updater: SPUUpdater { controller.updater }

    /// Settings > General > "Update automatically": download and install new versions without asking.
    var installsAutomatically: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            updater.automaticallyChecksForUpdates = true
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }
}
