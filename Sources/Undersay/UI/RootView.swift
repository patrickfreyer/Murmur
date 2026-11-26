import UndersayCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            NavigationStack {
                detail
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .today {
        case .today:
            TodayView()
        case .meetings:
            MeetingsView()
        case .dictations:
            DictationsView()
        case .people:
            VoicesView()
        case .stats:
            StatsView()
        case .coach:
            CoachView()
        case .automation(let id):
            if model.automations.contains(where: { $0.id == id }) {
                AutomationView(automationID: id).id(id)
            } else {
                ContentUnavailableView("Automation not found", systemImage: "bolt.slash")
            }
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

/// One navigation pattern: a record button, then plain sidebar rows grouped by purpose.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                SidebarHeader()
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                RecordButton()
                    .padding(.vertical, Space.xs)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
                Label("Today", systemImage: "sun.max").tag(SidebarItem.today)
            }

            Section("Library") {
                Label("Meetings", systemImage: "person.2.wave.2").tag(SidebarItem.meetings)
                    .badge(model.meetings.meetings.count)
                Label("Dictations", systemImage: "text.bubble").tag(SidebarItem.dictations)
                    .badge(model.dictations.items.count)
                Label("People", systemImage: "person.crop.circle").tag(SidebarItem.people)
                    .badge(model.voices.prints.count)
            }

            Section("Insights") {
                Label {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Coach")
                        if let focus = model.coachFocus, focus != .needData {
                            Text(focus.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "figure.mind.and.body")
                }
                .tag(SidebarItem.coach)
                Label("Statistics", systemImage: "chart.bar").tag(SidebarItem.stats)
            }

            Section("Automations") {
                ForEach(model.automations) { a in
                    Label {
                        HStack {
                            Text(a.name).lineLimit(1)
                            Spacer(minLength: 0)
                            StatusDot(automation: a)
                        }
                    } icon: {
                        Image(systemName: a.agent.symbol)
                    }
                    .tag(SidebarItem.automation(a.id))
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            if model.selection == .automation(a.id) { model.selection = .today }
                            model.automations.removeAll { $0.id == a.id }
                        }
                    }
                }
                Button {
                    let a = model.addAutomation(model.agents.first(where: \.installed)?.kind ?? .claudeCode)
                    model.selection = .automation(a.id)
                } label: {
                    Label("New automation", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 32)
        .task { await model.refreshAgents() }
    }
}

/// Green: last run worked. Orange: last run failed. Grey: off or never run. Pulsing while running.
struct StatusDot: View {
    @Environment(AppModel.self) private var model
    let automation: Automation

    var body: some View {
        let run = model.latestRun(of: automation.id)
        let color: Color = !automation.enabled ? .secondary.opacity(0.4)
            : run?.status == .failed ? .orange : run?.status == .done ? .green
            : run?.status == .running ? .accentColor : .secondary.opacity(0.4)
        Circle().fill(color).frame(width: 7, height: 7)
            .symbolEffect(.pulse, isActive: run?.status == .running)
            .help(run.map { "Last run \($0.startedAt.formatted(.relative(presentation: .named))): \($0.status.rawValue)" } ?? "Hasn't run yet")
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
