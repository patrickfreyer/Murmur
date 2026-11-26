import AppKit
import UndersayCore
import ScreenCaptureKit
import SwiftUI

/// Development aid for README screenshots.
///
///   UNDERSAY_SNAPSHOT=<dir>   capture each screen of the running app.
///   UNDERSAY_SCK=1            capture with ScreenCaptureKit (pixel-perfect, renders Liquid Glass;
///                           needs Screen Recording permission for Undersay). Without it, a quick
///                           layout-only render is used that skips glass and the sidebar.
@MainActor
enum Snapshots {
    static func runIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["UNDERSAY_SNAPSHOT"] else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let useSCK = env["UNDERSAY_SCK"] != nil
        Task { @MainActor in
            if useSCK, !CGPreflightScreenCaptureAccess() {
                DiagnosticLog.write("snapshots: requesting Screen Recording permission")
                CGRequestScreenCaptureAccess()
                try? await Task.sleep(for: .seconds(1))
                exit(3)
            }
            try? await Task.sleep(for: .seconds(2.5))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { exit(4) }
            window.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 920), display: true)
            if useSCK {
                // Make sure the window is on the Space being captured, even over a full-screen app.
                window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
                window.level = .floating
                window.orderFrontRegardless()
            }
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)

            var shots: [(String, SidebarItem)] = [
                ("home", .home), ("meetings", .meetings), ("dictations", .dictations), ("voices", .voices),
                ("stats", .stats),
            ]
            // Prefer a meeting whose speakers were recognised automatically (shows the voice-print magic).
            let ready = model.meetings.meetings.filter { $0.status == .ready }
            if let m = ready.first(where: { $0.speakers.contains { $0.name != nil && !$0.isConfirmed } }) ?? ready.first {
                shots.append(("meeting", .meeting(m.id)))
            }
            for (name, item) in shots {
                model.selection = item
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1.4))
                await capture(window, name: name, dir: out, sck: useSCK)
            }

            if useSCK {
                // The dictation pill, locked, over whatever is on screen.
                let levels: [Float] = (0..<30).map { i in Float(0.25 + 0.6 * abs(sin(Double(i) * 0.55))) }
                let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes")
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }
                for (name, state) in [("hud-hold", DictationController.State.listening(handsFree: false)),
                                      ("hud-locked", .listening(handsFree: true))] {
                    model.dictation.preview(state, levels: levels, appIcon: icon)
                    try? await Task.sleep(for: .seconds(1.2))
                    if let panel = NSApp.windows.first(where: { $0 is FloatingPanel && $0.isVisible }) {
                        await capture(panel, name: name, dir: out, sck: true)
                    }
                }
                model.dictation.preview(.idle, levels: levels, appIcon: nil)
            }
            DiagnosticLog.write("snapshots: done → \(out.path)")
            exit(0)
        }
    }

    static func capture(_ window: NSWindow, name: String, dir: URL, sck: Bool) async {
        let url = dir.appending(path: "\(name).png")
        if sck {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let pid = ProcessInfo.processInfo.processIdentifier
                let mine = content.windows.filter { $0.owningApplication?.processID == pid }
                guard let target = mine.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
                    ?? mine.filter({ $0.frame.width > 600 }).max(by: { $0.frame.width < $1.frame.width })
                else {
                    DiagnosticLog.write("snapshots: \(name) no SC window; want \(window.windowNumber), have \(mine.map { "\($0.windowID) \($0.frame)" })")
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: target)
                let config = SCStreamConfiguration()
                config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
                config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                config.shouldBeOpaque = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: url)
            } catch {
                DiagnosticLog.write("snapshots: capture \(name) failed: \(error.localizedDescription)")
            }
            return
        }
        guard let view = window.contentView?.superview ?? window.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
