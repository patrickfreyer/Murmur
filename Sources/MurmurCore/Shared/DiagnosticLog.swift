import Foundation

/// Small append-only log at ~/Library/Logs/Murmur.log, readable without Console.app.
/// Used for the input pipeline (permissions, event tap, fn events) where silent failures are common.
public enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "murmur.diagnostic-log")
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Murmur.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withTime, .withFractionalSeconds, .withColonSeparatorInTime]
        return f
    }()

    public static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: false, encoding: .utf8)
            }
        }
    }

    /// Keeps the file small: called once per launch.
    public static func rotate() {
        queue.async {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
                size > 1_000_000
            else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
