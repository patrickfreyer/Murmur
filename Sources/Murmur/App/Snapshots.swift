import AppKit
import MurmurCore
import SwiftUI

/// MURMUR_SNAPSHOT=<dir> renders each screen of the running app to PNGs (development aid; the app
/// captures only its own windows, so no Screen Recording permission is needed).
@MainActor
enum Snapshots {
    static func runIfRequested(_ model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["MURMUR_SNAPSHOT"] else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            var shots: [(String, SidebarItem)] = [("home", .home), ("dictations", .dictations), ("voices", .voices)]
            if let m = model.meetings.meetings.first(where: { $0.status == .ready }) { shots.append(("meeting", .meeting(m.id))) }
            for (name, item) in shots {
                model.selection = item
                try? await Task.sleep(for: .seconds(1.2))
                capture(name, out)
            }
            exit(0)
        }
    }

    static func capture(_ name: String, _ dir: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
            let view = window.contentView?.superview ?? window.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
    }
}
