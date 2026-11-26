import UndersayCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar(search: search)
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } detail: {
            NavigationStack {
                detail
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search transcripts")
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .home {
        case .home:
            HomeView()
        case .meetings:
            MeetingsView()
        case .dictations:
            DictationsView()
        case .voices:
            VoicesView()
        case .stats:
            StatsView()
        case .coach:
            CoachView()
        case .meeting(let id):
            if model.recorder.meetingID == id {
                LiveMeetingView()
            } else if model.meetings.meeting(id) != nil {
                MeetingDetailView(meetingID: id).id(id)
            } else {
                ContentUnavailableView("Meeting not found", systemImage: "waveform.slash")
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    var search: String

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                // The app's own header doubles as Home, like a Finder favourite: icon, name, live status.
                SidebarHeader().tag(SidebarItem.home)
                RecordButton()
                    .padding(.vertical, Space.xs)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            }

            Section {
                // Same horizontal bleed as the Record button and the selection highlight, so all
                // three share one left and right edge.
                StatTiles()
                    .padding(.horizontal, -SidebarActionButtonStyle.bleed)
                    .padding(.bottom, Space.xs)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            }

            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.meetings) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(SidebarItem.meeting(meeting.id))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.deleteMeeting(meeting.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    model.deleteMeeting(meeting.id)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, Theme.touchTarget)
    }

    private var filtered: [Meeting] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.meetings.meetings }
        return model.meetings.meetings.filter { m in
            m.title.localizedCaseInsensitiveContains(q)
                || m.segments.contains { $0.text.localizedCaseInsensitiveContains(q) }
                || m.speakers.contains { $0.displayName.localizedCaseInsensitiveContains(q) }
        }
    }

    private var groups: [(title: String, meetings: [Meeting])] {
        let cal = Calendar.current
        var buckets: [(String, [Meeting])] = []
        for m in filtered {
            let title: String
            if cal.isDateInToday(m.createdAt) {
                title = "Today"
            } else if cal.isDateInYesterday(m.createdAt) {
                title = "Yesterday"
            } else if let days = cal.dateComponents([.day], from: m.createdAt, to: .now).day, days < 7 {
                title = "This Week"
            } else {
                title = m.createdAt.formatted(.dateTime.month(.wide).year())
            }
            if let i = buckets.firstIndex(where: { $0.0 == title }) {
                buckets[i].1.append(m)
            } else {
                buckets.append((title, [m]))
            }
        }
        return buckets.map { (title: $0.0, meetings: $0.1) }
    }
}

struct MeetingRow: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if meeting.status == .recording {
                    Circle().fill(.red).frame(width: 7, height: 7)
                }
                Text(meeting.title).lineLimit(1).font(.body.weight(.medium))
            }
            HStack(spacing: 6) {
                switch meeting.status {
                case .processing:
                    ProgressView().controlSize(.mini)
                    Text(meeting.statusDetail ?? "Processing…")
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Needs attention")
                case .recording:
                    Text("Recording")
                case .ready:
                    Text(meeting.createdAt.formatted(date: .omitted, time: .shortened))
                    Text("·")
                    Text(meeting.duration.humanDuration)
                    Spacer(minLength: 0)
                    SpeakerStack(speakers: Array(meeting.speakers.prefix(4)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

struct SpeakerStack: View {
    @Environment(AppModel.self) private var model
    var speakers: [Speaker]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(speakers) { s in
                Avatar(name: s.displayName, color: s.color(voices: model.voices.prints), size: 18, dashed: s.name == nil)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
            }
        }
    }
}

struct RecordButton: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private let radius: CGFloat = 8
    private let bleed: CGFloat = 8

    var body: some View {
        let recording = model.recorder.isRecording
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button {
            model.toggleMeeting()
        } label: {
            HStack(spacing: Space.s) {
                RecordGlyph(recording: recording, glow: hovering)
                    .frame(width: 20)
                if recording, let start = model.recorder.startedAt {
                    LiveBars(level: max(model.recorder.micLevel, model.recorder.systemLevel))
                        .frame(width: 22, height: 14)
                        .transition(.scale(scale: 0.4, anchor: .leading).combined(with: .opacity))
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    Text("Stop").transition(.opacity)
                } else {
                    Text("Record Meeting").transition(.opacity)
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        ForEach(["⇧", "⌘", "R"], id: \.self) { MiniKeycap(label: $0) }
                    }
                    .opacity(hovering ? 1 : 0.7)
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(recording ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, bleed)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background {
                ZStack {
                    // Resting: a quiet frosted row. Recording: the whole row turns into a live red control.
                    shape.fill(.primary.opacity(hovering ? 0.10 : 0.06))
                        .opacity(recording ? 0 : 1)
                    shape.fill(LinearGradient(colors: [Color(red: 0.98, green: 0.27, blue: 0.24),
                                                       Color(red: 0.82, green: 0.12, blue: 0.16)],
                                              startPoint: .top, endPoint: .bottom))
                        .overlay { shape.fill(LinearGradient(colors: [.white.opacity(0.22), .clear],
                                                             startPoint: .top, endPoint: .center)) }
                        .opacity(recording ? 1 : 0)
                    shape.strokeBorder(recording ? .black.opacity(0.15) : .primary.opacity(0.08), lineWidth: 0.5)
                }
            }
            .shadow(color: recording ? .red.opacity(0.35) : .clear, radius: 6, y: 2)
            .padding(.horizontal, -bleed)
            .contentShape(shape)
        }
        .buttonStyle(PressScaleStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: recording)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .disabled(model.recorder.state == .finishing)
        .help(recording ? "Stop and transcribe" : "Record a meeting (⇧⌘R)")
    }
}

/// Voice Memos-style record dot (glossy, with a soft halo) that becomes a stop square.
struct RecordGlyph: View {
    var recording: Bool
    var glow: Bool

    var body: some View {
        ZStack {
            if recording {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.42, blue: 0.38), Color(red: 0.86, green: 0.1, blue: 0.12)],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 9))
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                    .shadow(color: .red.opacity(glow ? 0.8 : 0.35), radius: glow ? 5 : 2.5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// Five bars that breathe with the room's loudness.
struct LiveBars: View {
    var level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    let wobble = 0.55 + 0.45 * sin(t * 7 + Double(i) * 1.3)
                    let h = (0.25 + 0.75 * Double(level)) * wobble
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: 2.5, height: max(3, 14 * h))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// Tiny keycap like the ones in macOS menus' shortcut column, but with a bit of depth.
struct MiniKeycap: View {
    var label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(minWidth: 16, minHeight: 16)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.primary.opacity(0.07))
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
            }
    }
}

/// A filled button shaped exactly like a selected sidebar row (same height, radius and insets),
/// with the subtle top highlight and contact shadow of a macOS default push button.
struct SidebarActionButtonStyle: ButtonStyle {
    var tint: Color
    /// Sidebar selection highlights sit this far outside the row's content.
    static let bleed: CGFloat = 8
    static let radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, Self.bleed)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background {
                shape.fill(tint.gradient)
                    .overlay {
                        shape.fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top,
                                                  endPoint: .center))
                    }
                    .overlay { shape.strokeBorder(.black.opacity(0.12), lineWidth: 0.5) }
                    .overlay(alignment: .top) {
                        shape.inset(by: 0.5).trim(from: 0, to: 1).stroke(.white.opacity(0.25), lineWidth: 0.5)
                            .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
                    }
                    .brightness(configuration.isPressed ? -0.08 : 0)
            }
            .shadow(color: tint.opacity(0.35), radius: 3, y: 1.5)
            .padding(.horizontal, -Self.bleed)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Reminders-style summary tiles at the top of the sidebar: each one is a live count and a way in.
struct StatTiles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let columns = [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s)]
        VStack(spacing: Space.s) {
        LazyVGrid(columns: columns, spacing: Space.s) {
            StatTileButton(title: "Meetings", value: "\(model.meetings.meetings.count)", symbol: "person.2.wave.2.fill",
                           tint: .orange, target: .meetings)
            StatTileButton(title: "Words", value: compact(model.dictations.totalWords), symbol: "text.bubble.fill",
                           tint: .blue, target: .dictations)
            StatTileButton(title: "Voices", value: "\(model.voices.prints.count)", symbol: "person.wave.2.fill",
                           tint: .purple, target: .voices)
            StatTileButton(title: "Statistics", value: averageLatency, symbol: "chart.bar.fill",
                           tint: .green, target: .stats)
        }
        CoachTile()
        }
    }

    private var averageLatency: String {
        let recent = model.dictations.items.prefix(20)
        guard !recent.isEmpty else { return "–" }
        return "\(Int(recent.map(\.processingTime).reduce(0, +) / Double(recent.count) * 1000))ms"
    }

    private func compact(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.0fk", Double(n) / 1000) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

struct StatTileButton: View {
    @Environment(AppModel.self) private var model
    var title: String
    var value: String
    var symbol: String
    var tint: Color
    var target: SidebarItem
    @State private var hovering = false

    var body: some View {
        let selected = model.selection == target
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button {
            model.selection = target
        } label: {
            VStack(alignment: .leading, spacing: Space.s - 2) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(selected ? AnyShapeStyle(.white.opacity(0.28)) : AnyShapeStyle(tint.gradient)))
                        .shadow(color: tint.opacity(selected ? 0 : 0.35), radius: 3, y: 1)
                    Spacer(minLength: 0)
                    Text(value)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                        .foregroundStyle(selected ? .white : .primary)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
            }
            .padding(Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(selected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.primary.opacity(hovering ? 0.09 : 0.055)))
                    .overlay { shape.strokeBorder(.primary.opacity(selected ? 0 : 0.06), lineWidth: 0.5) }
            }
            .contentShape(shape)
        }
        .buttonStyle(PressScaleStyle(scale: 0.96))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

struct SidebarHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.s + 2) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 1) {
                Text("Undersay").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                        .shadow(color: statusColor.opacity(0.7), radius: 2)
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.xs)
        .help("Home")
        .animation(.easeOut(duration: 0.2), value: status)
    }

    private var status: String {
        if model.recorder.isRecording { return "Recording a meeting" }
        switch model.dictation.state {
        case .listening(true): return "Dictating · locked"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        default: break
        }
        switch model.modelStatus {
        case .loading(_, let f): return "Loading model \(Int(f * 100))%"
        case .failed: return "Speech model unavailable"
        default: break
        }
        if !model.fnMonitorRunning { return "Needs Accessibility" }
        return "Hold fn to dictate"
    }

    private var statusColor: Color {
        if model.recorder.isRecording { return .red }
        if case .listening = model.dictation.state { return .accentColor }
        if case .failed = model.modelStatus { return .orange }
        if !model.fnMonitorRunning { return .orange }
        if case .ready = model.modelStatus { return .green }
        return .yellow
    }
}

/// Full-width tile under the stats grid: the Coach and this week's focus.
struct CoachTile: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let selected = model.selection == .coach
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let tint = Color.teal
        Button {
            model.selection = .coach
        } label: {
            HStack(spacing: Space.s + 2) {
                Image(systemName: "figure.mind.and.body")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(selected ? AnyShapeStyle(.white.opacity(0.28)) : AnyShapeStyle(tint.gradient)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Coach").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
                    Text(model.coachFocus?.title ?? "Communication tips")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? .white : .primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    .foregroundStyle(selected ? .white.opacity(0.8) : .secondary.opacity(0.6))
            }
            .padding(.horizontal, Space.s + 2)
            .padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(selected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.primary.opacity(hovering ? 0.09 : 0.055)))
                    .overlay { shape.strokeBorder(.primary.opacity(selected ? 0 : 0.06), lineWidth: 0.5) }
            }
            .contentShape(shape)
        }
        .buttonStyle(PressScaleStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
