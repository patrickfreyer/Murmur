import AVFoundation
import MurmurCore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                if needsSetup { SetupCard() }
                ModelStatusCard()
                stats
                if !model.dictations.items.isEmpty { recentDictations }
            }
            .padding(28)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Murmur")
        .toolbarTitleDisplayMode(.inlineLarge)
    }

    private var needsSetup: Bool {
        !model.hasAccessibility || model.micStatus != .authorized || !model.fnMonitorRunning
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Hold \(Image(systemName: "globe")) fn and speak.")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Release to drop the text into any field, in any app. Double-tap fn for hands-free. Everything is transcribed on this Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button {
                        model.dictation.toggleHandsFree()
                    } label: {
                        Label("Try dictation", systemImage: "mic.fill").frame(minHeight: 30)
                    }
                    .buttonStyle(.glassProminent)
                    Button {
                        model.toggleMeeting()
                    } label: {
                        Label(model.recorder.isRecording ? "Stop meeting" : "Record a meeting",
                              systemImage: "person.2.wave.2").frame(minHeight: 30)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.extraLarge)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
            FnKeycap(active: model.dictation.state != .idle)
        }
        .padding(26)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.22), Color.purple.opacity(0.12), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 28)
        )
    }

    private var stats: some View {
        HStack(spacing: 14) {
            StatTile(value: "\(model.dictations.totalWords)", label: "words dictated", symbol: "text.word.spacing")
            StatTile(
                value: "\(model.meetings.meetings.count)", label: "meetings", symbol: "person.2.wave.2")
            StatTile(value: "\(model.voices.prints.count)", label: "known voices", symbol: "person.wave.2")
            StatTile(
                value: averageLatency, label: "avg. transcription", symbol: "bolt")
        }
    }

    private var averageLatency: String {
        let recent = model.dictations.items.prefix(20)
        guard !recent.isEmpty else { return "–" }
        let avg = recent.map(\.processingTime).reduce(0, +) / Double(recent.count)
        return "\(Int(avg * 1000)) ms"
    }

    private var recentDictations: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent dictations").font(.headline)
                Spacer()
                Button("Show all") { model.selection = .dictations }.buttonStyle(.borderless)
            }
            ForEach(model.dictations.items.prefix(4)) { d in
                DictationRow(dictation: d)
            }
        }
    }
}

struct FnKeycap: View {
    var active: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22)
                .fill(.background)
                .shadow(color: .black.opacity(active ? 0.05 : 0.18), radius: active ? 2 : 10, y: active ? 1 : 6)
            VStack(alignment: .leading) {
                Image(systemName: "globe").font(.system(size: 26, weight: .regular))
                Spacer()
                Text("fn").font(.system(size: 30, weight: .medium, design: .rounded))
            }
            .padding(16)
            .foregroundStyle(active ? Color.accentColor : .primary)
        }
        .frame(width: 112, height: 112)
        .scaleEffect(active ? 0.94 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: active)
    }
}

struct StatTile: View {
    var value: String
    var label: String
    var symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(value).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 20))
    }
}

struct ModelStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.modelStatus {
        case .ready:
            EmptyView()
        case .idle, .loading:
            Card {
                HStack(spacing: 14) {
                    Image(systemName: "cpu").font(.title2).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 6) {
                        if case .loading(let text, let fraction) = model.modelStatus {
                            Text(text).font(.headline)
                            ProgressView(value: fraction).progressViewStyle(.linear)
                        } else {
                            Text("Preparing…").font(.headline)
                        }
                        Text("One-time download. After this, transcription runs fully offline on the Neural Engine.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        case .failed(let message):
            Card {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title2)
                    VStack(alignment: .leading) {
                        Text("Speech model unavailable").font(.headline)
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Retry") { model.loadModels() }.buttonStyle(.glass).controlSize(.large)
                }
            }
        }
    }
}

struct SetupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Finish setup").font(.title3.weight(.semibold))
                PermissionRow(
                    title: "Microphone", detail: "To hear you.", symbol: "mic",
                    granted: model.micStatus == .authorized
                ) {
                    if model.micStatus == .notDetermined {
                        model.requestMicrophone()
                    } else {
                        model.openSettingsPane("Privacy_Microphone")
                    }
                }
                PermissionRow(
                    title: "Accessibility",
                    detail: "To notice the fn key and type into other apps.",
                    symbol: "accessibility", granted: model.hasAccessibility
                ) {
                    model.requestAccessibility()
                    model.openSettingsPane("Privacy_Accessibility")
                }
                PermissionRow(
                    title: "Globe key does nothing",
                    detail: "Keyboard → “Press 🌐 key to” → Do Nothing, so the emoji picker stays out of the way.",
                    symbol: "globe", granted: nil
                ) {
                    model.openKeyboardSettings()
                }
            }
        }
    }
}

struct PermissionRow: View {
    var title: String
    var detail: String
    var symbol: String
    var granted: Bool?
    var action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(.quaternary, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted == true {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            } else {
                Button(granted == nil ? "Open" : "Allow", action: action)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        }
    }
}
