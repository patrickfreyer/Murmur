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
            KeyboardCluster(fnActive: model.dictation.state != .idle)
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
            DictationTimeline(items: Array(model.dictations.items.prefix(4)), compact: true)
        }
    }
}

/// A slice of a MacBook keyboard (bottom-left corner) with a physically modelled fn key.
struct KeyboardCluster: View {
    var fnActive: Bool
    @Environment(\.colorScheme) private var scheme

    private let key: CGFloat = 58
    private let gap: CGFloat = 7

    var body: some View {
        let deck = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: gap) {
            HStack(spacing: gap) {
                KeyCap(width: key * 2.25, height: key, active: false) {
                    KeyLegend(bottomLeft: Text("shift"), topLeft: Text("⇧"))
                }
            }
            HStack(alignment: .bottom, spacing: gap) {
                KeyCap(width: key, height: key, active: fnActive, glow: true) {
                    KeyLegend(bottomLeft: Text(Image(systemName: "globe")), topRight: Text("fn"))
                }
                KeyCap(width: key, height: key, active: false) {
                    KeyLegend(bottomLeft: Text("control"), topRight: Text("⌃"))
                }
                KeyCap(width: key, height: key, active: false) {
                    KeyLegend(bottomLeft: Text("option"), topRight: Text("⌥"))
                }
                KeyCap(width: key * 1.3, height: key, active: false) {
                    KeyLegend(bottomLeft: Text("command"), topRight: Text("⌘"))
                }
            }
        }
        .padding(14)
        .background {
            // Anodised deck: space black in dark mode, silver in light mode.
            deck.fill(LinearGradient(
                colors: scheme == .dark
                    ? [Color(white: 0.17), Color(white: 0.12)]
                    : [Color(white: 0.86), Color(white: 0.78)],
                startPoint: .top, endPoint: .bottom))
                .overlay { deck.strokeBorder(.white.opacity(scheme == .dark ? 0.08 : 0.5), lineWidth: 0.75) }
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
        }
        // A window onto the keyboard's bottom-left corner: the deck is cropped at the top and right
        // (full-size keys run past the edge) and fades out, as if the keyboard continues.
        .frame(width: 236, height: 136, alignment: .bottomLeading)
        .clipShape(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 22, bottomTrailing: 0,
                                                             topTrailing: 0), style: .continuous))
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.6),
                                   .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
        }
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35),
                                   .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityLabel("fn key")
    }
}

struct KeyLegend: View {
    var bottomLeft: Text? = nil
    var topLeft: Text? = nil
    var topRight: Text? = nil

    var body: some View {
        ZStack {
            if let topLeft { topLeft.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
            if let topRight { topRight.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
            if let bottomLeft { bottomLeft.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
        }
        .font(.system(size: 10.5, weight: .regular))
        .foregroundStyle(Color(white: 0.84))
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
    }
}

/// One keycap: recessed well, dark skirt and a slightly domed cap that travels down when pressed.
struct KeyCap<Legend: View>: View {
    var width: CGFloat
    var height: CGFloat
    var active: Bool
    var glow = false
    @ViewBuilder var legend: Legend

    private let travel: CGFloat = 2

    var body: some View {
        let r: CGFloat = 7
        let cap = RoundedRectangle(cornerRadius: r, style: .continuous)
        ZStack(alignment: .top) {
            // Well around the key.
            RoundedRectangle(cornerRadius: r + 1.5, style: .continuous)
                .fill(.black.opacity(0.55))
                .padding(-1.5)
            // Skirt: the visible side of the cap below its top face.
            cap.fill(Color(white: 0.04)).offset(y: travel)
            // Cap top.
            cap.fill(LinearGradient(colors: [Color(white: active ? 0.20 : 0.235), Color(white: active ? 0.15 : 0.17)],
                                    startPoint: .top, endPoint: .bottom))
                .overlay {
                    cap.strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                }
                .overlay { legend }
                .overlay {
                    if glow {
                        cap.strokeBorder(Color.accentColor.opacity(active ? 0.9 : 0), lineWidth: 1.5)
                            .shadow(color: Color.accentColor.opacity(active ? 0.9 : 0), radius: 8)
                    }
                }
                .offset(y: active ? travel : 0)
        }
        .frame(width: width, height: height + travel, alignment: .top)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: active)
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
