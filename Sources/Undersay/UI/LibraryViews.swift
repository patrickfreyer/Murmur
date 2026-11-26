import AppKit
import UndersayCore
import SwiftUI

struct DictationsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var confirmClear = false

    var body: some View {
        let items = model.dictations.items.filter {
            query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)
        }
        Group {
            if model.dictations.items.isEmpty {
                ContentUnavailableView(
                    "No dictations yet", systemImage: "text.bubble",
                    description: Text("Hold fn anywhere and start talking. Everything you dictate is kept here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.xxl, pinnedViews: .sectionHeaders) {
                        ForEach(DictationDay.group(items)) { day in
                            Section {
                                DictationTimeline(items: day.items)
                            } header: {
                                DayHeader(day: day)
                            }
                        }
                    }
                    .padding(.vertical, Space.xl)
                    .pageColumn(maxWidth: 820)
                }
                .scrollEdgeEffectStyle(.soft, for: .all)
            }
        }
        .background { AmbientBackdrop(tint: .teal) }
        .navigationTitle("Dictation")
        .searchable(text: $query, placement: .toolbar)
        .toolbar {
            if !model.dictations.items.isEmpty {
                Button("Clear history", systemImage: "trash") { confirmClear = true }
            }
        }
        .confirmationDialog("Clear all dictation history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.dictations.clear() }
        }
    }
}

struct DictationDay: Identifiable {
    let id: Date
    let items: [Dictation]

    var title: String {
        let cal = Calendar.current
        if cal.isDateInToday(id) { return "Today" }
        if cal.isDateInYesterday(id) { return "Yesterday" }
        return id.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func group(_ items: [Dictation]) -> [DictationDay] {
        let cal = Calendar.current
        var days: [Date: [Dictation]] = [:]
        for d in items { days[cal.startOfDay(for: d.createdAt), default: []].append(d) }
        return days.keys.sorted(by: >).map { DictationDay(id: $0, items: days[$0]!) }
    }
}

private struct DayHeader: View {
    let day: DictationDay

    var body: some View {
        let words = day.items.reduce(0) { $0 + $1.text.split(separator: " ").count }
        HStack(spacing: Space.s) {
            Text(day.title).font(.headline)
            Text("\(day.items.count) dictation\(day.items.count == 1 ? "" : "s") · \(words) words")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, Space.s)
    }
}

/// Vertical timeline: time on the left, the app's icon as the node on a continuous rail,
/// and the dictated text in a card.
struct DictationTimeline: View {
    let items: [Dictation]
    var compact = false

    static let timeWidth: CGFloat = 46
    static let node: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? Space.m : Space.l) {
            ForEach(items) { d in
                DictationRow(dictation: d, showTime: true)
                    .depthOfField()
            }
        }
        .background(alignment: .topLeading) {
            // The rail runs through the centre of every node.
            Rectangle()
                .fill(LinearGradient(colors: [.secondary.opacity(0.35), .secondary.opacity(0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 1.5)
                .padding(.top, Self.node / 2 + Space.l)
                .padding(.bottom, Space.l)
                .offset(x: Self.timeWidth + Space.m + Self.node / 2 - 0.75)
        }
    }
}

struct DictationRow: View {
    @Environment(AppModel.self) private var model
    let dictation: Dictation
    var showTime = true
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            if showTime {
                Text(dictation.createdAt, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: DictationTimeline.timeWidth, alignment: .trailing)
                    .padding(.top, Space.l + 7)
            }
            AppIconNode(bundleID: dictation.appBundleID, appName: dictation.appName, size: DictationTimeline.node)
                .padding(.top, Space.l)
            card
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copy() }
            Button("Delete", systemImage: "trash", role: .destructive) { model.dictations.delete(dictation.id) }
        }
    }

    private var card: some View {
        HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(dictation.text)
                    .font(.system(size: 15))
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.xs + 2) {
                    if let app = dictation.appName { Text(app).fontWeight(.medium) }
                    Text("·")
                    Label("\(String(format: "%.1f", dictation.duration)) s", systemImage: "waveform")
                    Text("·")
                    Label("\(Int(dictation.processingTime * 1000)) ms", systemImage: "bolt.fill")
                }
                .labelStyle(CompactLabelStyle())
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Copy")
        }
        .padding(.vertical, Space.m + 2)
        .padding(.leading, Space.l + 2)
        .padding(.trailing, Space.m)
        .surface(radius: Radius.tile, elevation: 0.5)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dictation.text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .semibold))
            configuration.title
        }
    }
}

/// The target app's real icon, framed like a timeline node.
struct AppIconNode: View {
    var bundleID: String?
    var appName: String?
    var size: CGFloat

    var body: some View {
        Group {
            if let icon = AppIcons.icon(bundleID: bundleID, name: appName) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "text.cursor")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.quaternary, in: .rect(cornerRadius: size * 0.24, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
        // A halo in the page colour separates the node from the rail behind it.
        .background(Circle().fill(.background).frame(width: size + 6, height: size + 6).opacity(0.0001))
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleID: String?, name: String?) -> NSImage? {
        let key = bundleID ?? name ?? ""
        guard !key.isEmpty else { return nil }
        if let hit = cache[key] { return hit }
        var url: URL?
        if let bundleID { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
        if url == nil, let name {
            url = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.bundleURL
            if url == nil {
                for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                            NSHomeDirectory() + "/Applications"] {
                    let candidate = URL(fileURLWithPath: dir).appending(path: "\(name).app")
                    if FileManager.default.fileExists(atPath: candidate.path) { url = candidate; break }
                }
            }
        }
        guard let url else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[key] = icon
        return icon
    }
}

struct VoicesView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: VoicePrint?
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Card {
                    HStack(alignment: .center, spacing: Space.l) {
                        IconBadge(symbol: "person.wave.2.fill", tint: .accentColor)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Voice prints stay on this Mac").font(.headline)
                            Text("Name a speaker once in any transcript and Undersay recognises them in every meeting after — and in older ones too. Your own voice is learned quietly from your dictations.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if model.voices.prints.isEmpty {
                    ContentUnavailableView(
                        "No voices yet", systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Tap a speaker in a meeting transcript to name them."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Space.l)], spacing: Space.l) {
                        ForEach(model.voices.prints.sorted { ($0.isMe ? 0 : 1, $0.name) < ($1.isMe ? 0 : 1, $1.name) }) { p in
                            voiceCard(p)
                        }
                    }
                }
            }
            .padding(.vertical, Space.xl)
            .pageColumn(maxWidth: 980)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background { AmbientBackdrop(tint: .indigo) }
        .navigationTitle("Voices")
        .alert("Rename voice", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let r = renaming {
                    model.voices.rename(r.id, to: newName)
                    renameInMeetings(r.id, to: newName)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func voiceCard(_ p: VoicePrint) -> some View {
        let meetings = model.meetings.meetings.filter { $0.speakers.contains { $0.voicePrintID == p.id } }.count
        let color = Theme.color(p.colorIndex)
        let strength = min(5, max(1, (p.sampleCount + 1) / 2))
        return VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .center, spacing: Space.m + 2) {
                FaceAvatar(name: p.name, color: color, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.s) {
                        Text(p.name).font(.title3.weight(.semibold)).lineLimit(1)
                        if p.isMe {
                            Text("You").font(.caption2.weight(.bold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18), in: .capsule)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(meetings == 0 ? "Not in a meeting yet" : "In \(meetings) meeting\(meetings == 1 ? "" : "s")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        newName = p.name
                        renaming = p
                    }
                    if !p.isMe {
                        Button("This is me", systemImage: "person.crop.circle") { model.voices.setMe(p.id) }
                    }
                    Divider()
                    Button("Forget voice", systemImage: "trash", role: .destructive) { model.voices.delete(p.id) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 32, height: 32)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .menuIndicator(.hidden)
            }

            // Voice signature in an inset well: corner radius = card radius − inset.
            VoiceSignature(embedding: p.centroid, color: color)
                .frame(height: 30)
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s + 2)
                .background(.quaternary.opacity(0.45),
                            in: .rect(cornerRadius: Radius.inner(Radius.card, inset: Space.xl - Space.s), style: .continuous))
                .help("Voice signature, learned on this Mac")

            HStack(spacing: Space.xs + 1) {
                ForEach(0..<5, id: \.self) { i in
                    Circle().fill(i < strength ? color : Color.secondary.opacity(0.25)).frame(width: 6, height: 6)
                }
                Text("\(p.sampleCount) sample\(p.sampleCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, Space.xs)
                Spacer()
                Text(p.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    .help("Last updated")
            }
            .help("Recognition gets more reliable with more samples")
        }
        .padding(Space.xl)
        .surface(radius: Radius.card, elevation: 0.7)
    }

    private func renameInMeetings(_ id: UUID, to name: String) {
        for m in model.meetings.meetings where m.speakers.contains(where: { $0.voicePrintID == id }) {
            model.meetings.update(m.id) { m in
                for i in m.speakers.indices where m.speakers[i].voicePrintID == id { m.speakers[i].name = name }
            }
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform").font(.title3).foregroundStyle(Color.accentColor)
                Text("Undersay").font(.headline)
                Spacer()
                statusText.font(.caption).foregroundStyle(.secondary)
            }

            Button {
                model.toggleMeeting()
            } label: {
                HStack {
                    Image(systemName: model.recorder.isRecording ? "stop.fill" : "record.circle")
                    if model.recorder.isRecording, let s = model.recorder.startedAt {
                        Text("Stop recording")
                        Spacer()
                        Text(timerInterval: s...Date.distantFuture, countsDown: false).monospacedDigit()
                    } else {
                        Text("Record meeting")
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(model.recorder.isRecording ? .red : .accentColor)
            .controlSize(.large)

            Button {
                model.dictation.toggleHandsFree()
            } label: {
                HStack {
                    Image(systemName: "mic.fill")
                    Text("Dictate hands-free")
                    Spacer()
                    Text("fn fn").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            if let last = model.dictations.items.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last dictation").font(.caption).foregroundStyle(.secondary)
                    Text(last.text).lineLimit(3).font(.callout)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                .onTapGesture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(last.text, forType: .string)
                }
            }

            Divider()
            HStack {
                Button("Open Undersay") {
                    NSApp.activate()
                    openWindow(id: "main")
                }
                Spacer()
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder
    private var statusText: some View {
        switch model.modelStatus {
        case .ready: Text(model.fnMonitorRunning ? "fn ready" : "Needs permission")
        case .loading(_, let f): Text("Loading \(Int(f * 100))%")
        case .failed: Text("Model error")
        case .idle: Text("Starting…")
        }
    }
}
