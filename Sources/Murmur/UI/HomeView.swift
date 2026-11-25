import AVFoundation
import MurmurCore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                hero
                if needsSetup { SetupCard() }
                ModelStatusCard()
                stats
                if !model.dictations.items.isEmpty { recentDictations }
            }
            .padding(.vertical, Space.xl)
            .pageColumn(maxWidth: 940)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background { AmbientBackdrop() }
        .navigationTitle("Murmur")
        .toolbarTitleDisplayMode(.inlineLarge)
    }

    private var needsSetup: Bool {
        !model.hasAccessibility || model.micStatus != .authorized || !model.fnMonitorRunning
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: Space.xxl) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Hold \(Image(systemName: "globe")) fn and speak.")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("Release to drop the text into any field, in any app. Double-tap fn for hands-free. Everything is transcribed on this Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
                HStack(spacing: Space.m) {
                    Button {
                        model.dictation.toggleHandsFree()
                    } label: {
                        Label("Try dictation", systemImage: "mic.fill")
                            .frame(minWidth: 150, minHeight: Theme.buttonHeight)
                    }
                    .buttonStyle(.glassProminent)
                    Button {
                        model.toggleMeeting()
                    } label: {
                        Label(model.recorder.isRecording ? "Stop meeting" : "Record a meeting",
                              systemImage: model.recorder.isRecording ? "stop.fill" : "person.2.wave.2")
                            .frame(minWidth: 170, minHeight: Theme.buttonHeight)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
                .padding(.top, Space.s)
            }
            Spacer(minLength: 0)
            FnKeycap(active: model.dictation.state != .idle)
        }
        .padding(Space.xxl)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.hero, style: .continuous).fill(.thinMaterial)
                RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.20), Color.purple.opacity(0.10), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.03)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        }
        .shadow(color: Color.accentColor.opacity(0.12), radius: 30, y: 16)
    }

    private var stats: some View {
        HStack(spacing: Space.l) {
            StatTile(value: "\(model.dictations.totalWords)", label: "words dictated", symbol: "text.word.spacing")
            StatTile(value: "\(model.meetings.meetings.count)", label: "meetings", symbol: "person.2.wave.2")
            StatTile(value: "\(model.voices.prints.count)", label: "known voices", symbol: "person.wave.2")
            StatTile(value: averageLatency, label: "avg. transcription", symbol: "bolt")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var averageLatency: String {
        let recent = model.dictations.items.prefix(20)
        guard !recent.isEmpty else { return "–" }
        let avg = recent.map(\.processingTime).reduce(0, +) / Double(recent.count)
        return "\(Int(avg * 1000)) ms"
    }

    private var recentDictations: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Recent dictations") {
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
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(.background)
            // Key top: a slight gradient reads as a physical, convex cap.
            shape.fill(LinearGradient(colors: [.white.opacity(0.10), .black.opacity(0.06)],
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
            VStack(alignment: .leading) {
                Image(systemName: "globe").font(.system(size: 24, weight: .regular))
                Spacer()
                Text("fn").font(.system(size: 30, weight: .medium, design: .rounded))
            }
            .padding(Space.l + 2)
            .foregroundStyle(active ? Color.accentColor : .primary)
        }
        .frame(width: 116, height: 116)
        .shadow(color: .black.opacity(active ? 0.10 : 0.22), radius: active ? 3 : 14, y: active ? 2 : 9)
        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        .scaleEffect(active ? 0.95 : 1)
        .offset(y: active ? 3 : 0)
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: active)
    }
}

struct StatTile: View {
    var value: String
    var label: String
    var symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            IconBadge(symbol: symbol, size: 30)
            Spacer(minLength: Space.xs)
            Text(value).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(Space.l + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .surface(radius: Radius.tile, elevation: 0.6)
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
                HStack(alignment: .top, spacing: Space.l) {
                    IconBadge(symbol: "cpu", tint: .accentColor)
                    VStack(alignment: .leading, spacing: Space.s) {
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
                HStack(spacing: Space.l) {
                    IconBadge(symbol: "exclamationmark.triangle.fill", tint: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speech model unavailable").font(.headline)
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.loadModels()
                    } label: {
                        Text("Retry").frame(minWidth: 72, minHeight: Theme.buttonHeight)
                    }
                    .buttonStyle(.glass).controlSize(.large)
                }
            }
        }
    }
}

struct SetupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(padding: Space.xl) {
            VStack(alignment: .leading, spacing: Space.l) {
                Text("Finish setup").font(.title3.weight(.semibold))
                VStack(spacing: 0) {
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
                    Divider().padding(.leading, 40 + Space.l)
                    PermissionRow(
                        title: "Accessibility",
                        detail: model.hasAccessibility
                            ? "To notice the fn key and type into other apps."
                            : "To notice the fn key and type into other apps. Already switched on? Remove Murmur with −, then add it again.",
                        symbol: "accessibility", granted: model.hasAccessibility
                    ) {
                        model.requestAccessibility()
                        model.openSettingsPane("Privacy_Accessibility")
                    }
                    Divider().padding(.leading, 40 + Space.l)
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
}

struct PermissionRow: View {
    var title: String
    var detail: String
    var symbol: String
    var granted: Bool?
    var action: () -> Void

    var body: some View {
        HStack(spacing: Space.l) {
            IconBadge(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.l)
            Group {
                if granted == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                } else {
                    Button(action: action) {
                        Text(granted == nil ? "Open" : "Allow").frame(minWidth: 64, minHeight: 28)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, Space.m)
    }
}
