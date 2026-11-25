import AppKit
import MurmurCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Transcription", systemImage: "waveform") { TranscriptionSettings() }
            Tab("Meetings", systemImage: "person.2.wave.2") { MeetingSettings() }
            Tab("Permissions", systemImage: "lock.shield") { PermissionSettings() }
        }
        .frame(width: 560, height: 440)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("You") {
                TextField("Your name", text: $model.meName)
                Toggle("Learn my voice from dictations", isOn: $model.learnMyVoice)
                Text("Used to label you in meeting transcripts. The voice print never leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dictation") {
                LabeledContent("Push to talk", value: "Hold fn")
                LabeledContent("Hands-free", value: "Double-tap fn, tap again to finish")
                LabeledContent("Cancel", value: "Esc")
                Toggle("Stop fn from opening emoji / Apple dictation", isOn: $model.suppressGlobeAction)
            }
            Section {
                Toggle("Open at login", isOn: $model.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranscriptionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Speech model") {
                Picker("Model", selection: $model.asrModel) {
                    ForEach(ASRModelChoice.allCases) { m in
                        VStack(alignment: .leading) {
                            Text(m.title)
                            Text(m.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(m)
                    }
                }
                .pickerStyle(.radioGroup)
                switch model.modelStatus {
                case .ready: Label("Loaded on the Neural Engine", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .loading(let t, let f): ProgressView(t, value: f)
                case .failed(let e): Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                case .idle: EmptyView()
                }
            }
            Section("Storage") {
                LabeledContent("Library", value: Paths.root.path(percentEncoded: false))
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct MeetingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Recording") {
                Toggle("Record call audio (system audio)", isOn: $model.captureSystemAudio)
                Text("No headphones? Call audio that leaks from the speakers into your mic is recognised by voice and removed from the transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("After the meeting") {
                Toggle("Summarize with Apple Intelligence", isOn: $model.autoSummarize)
                    .disabled(!Summarizer.isAvailable)
                if let reason = Summarizer.unavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Voice recognition") {
                Slider(value: $model.matchThreshold, in: 0.45...0.8, step: 0.01) {
                    Text("Match strictness")
                } minimumValueLabel: {
                    Text("Loose")
                } maximumValueLabel: {
                    Text("Strict")
                }
                Text("Stricter avoids mislabelling similar voices; looser recognises people on worse audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                SetupCard()
                LabeledContent("fn key listener", value: model.fnMonitorRunning ? "Running" : "Not running")
                LabeledContent("System audio", value: "Asked the first time you record a meeting")
            }
        }
        .formStyle(.grouped)
    }
}
