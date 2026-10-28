import AppKit

/// Name, version and contact details, read from the app's Info.plist (filled in by the build from Release.config).
enum AboutInfo {
    private static func string(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "" }

    static var name: String { string("CFBundleDisplayName").isEmpty ? string("CFBundleName") : string("CFBundleDisplayName") }
    static var version: String { "\(string("CFBundleShortVersionString")) (\(string("CFBundleVersion")))" }
    static var copyright: String { string("NSHumanReadableCopyright") }
}

/// Where the app keeps its things. The app used to be called "Framegrab"; anyone who has data under that name keeps it:
/// the history is moved to the new folder once, and an existing Pictures folder under the old name keeps being used
/// so a person's screenshots are not split between two folders.
enum AppFolders {
    private static let legacyName = "Framegrab"
    private static var fm: FileManager { FileManager.default }

    /// ~/Library/Application Support/<app name>, created if needed.
    static var supportFolder: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent(AboutInfo.name, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyName, isDirectory: true)
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }

    /// ~/Pictures/<app name>, unless ~/Pictures/<old name> already exists and the new one does not.
    static var defaultPicturesFolder: URL {
        let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        let current = pictures.appendingPathComponent(AboutInfo.name, isDirectory: true)
        let legacy = pictures.appendingPathComponent(legacyName, isDirectory: true)
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) { return legacy }
        return current
    }
}
