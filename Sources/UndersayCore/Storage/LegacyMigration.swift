import Foundation

/// One-time move of data from the app's previous name (Murmur) to Undersay.
public enum LegacyMigration {
    static let oldBundleID = "com.patrickfreyer.murmur"
    static let doneKey = "migratedFromMurmur"
    /// Settings worth carrying over.
    static let keys = [
        "asrModel", "meName", "learnMyVoice", "suppressGlobe", "echoCancellation", "captureSystemAudio",
        "autoSummarize", "matchThreshold", "soundEffects", "smartFormatting",
    ]

    /// Call before anything reads the library or settings.
    public static func run(defaults: UserDefaults = .standard) {
        guard ProcessInfo.processInfo.environment["UNDERSAY_HOME"] == nil,
            !defaults.bool(forKey: doneKey)
        else { return }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appending(path: "Murmur", directoryHint: .isDirectory)
        let new = support.appending(path: "Undersay", directoryHint: .isDirectory)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            do {
                try fm.moveItem(at: old, to: new)
                DiagnosticLog.write("migration: moved library from Murmur to Undersay")
            } catch {
                DiagnosticLog.write("migration: could not move library: \(error.localizedDescription)")
            }
        }
        if let legacy = UserDefaults(suiteName: oldBundleID) {
            for key in keys where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}
