import AppKit
import MurmurCore
import SwiftUI


struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Murmur", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.recorder.isRecording ? "Stop Meeting" : "Record Meeting") { model.toggleMeeting() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Dictate (hands-free)") { model.dictation.toggleHandsFree() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            MenuBarIcon().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.launch() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { for w in sender.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) } }
        return true
    }
}

struct MenuBarIcon: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.recorder.isRecording {
            Image(systemName: "record.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.red, .primary)
        } else if model.dictation.state != .idle {
            Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
        } else {
            Image(systemName: "waveform")
        }
    }
}
