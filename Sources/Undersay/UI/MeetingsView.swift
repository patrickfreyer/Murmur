import UndersayCore
import SwiftUI

/// All meetings as a gallery of cards, grouped by when they happened.
struct MeetingsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let meetings = model.meetings.meetings.filter { m in
            query.isEmpty || m.title.localizedCaseInsensitiveContains(query)
                || m.segments.contains { $0.text.localizedCaseInsensitiveContains(query) }
                || m.speakers.contains { $0.displayName.localizedCaseInsensitiveContains(query) }
        }
        Group {
            if model.meetings.meetings.isEmpty {
                ContentUnavailableView {
                    Label("No meetings yet", systemImage: "person.2.wave.2")
                } description: {
                    Text("Record a call or an in-person meeting. Undersay transcribes it on this Mac and tells you who said what.")
                } actions: {
                    Button {
                        model.startMeeting()
                    } label: {
                        Label("Record Meeting", systemImage: "record.circle").frame(minHeight: Theme.buttonHeight)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.xxl) {
                        ForEach(MeetingGroup.group(meetings)) { group in
                            VStack(alignment: .leading, spacing: Space.m) {
                                SectionHeader(group.title)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Space.l)],
                                          spacing: Space.l) {
                                    ForEach(group.meetings) { m in
                                        MeetingCard(meeting: m).depthOfField()
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, Space.xl)
                    .pageColumn(maxWidth: 1000)
                }
                .scrollEdgeEffectStyle(.soft, for: .all)
            }
        }
        .background { AmbientBackdrop(tint: .orange) }
        .navigationTitle("Meetings")
        .searchable(text: $query, placement: .toolbar, prompt: "Search meetings")
    }
}

struct MeetingGroup: Identifiable {
    let title: String
    let meetings: [Meeting]
    var id: String { title }

    static func group(_ meetings: [Meeting]) -> [MeetingGroup] {
        let cal = Calendar.current
        var out: [MeetingGroup] = []
        for m in meetings {
            let title: String
            if cal.isDateInToday(m.createdAt) {
                title = "Today"
            } else if cal.isDateInYesterday(m.createdAt) {
                title = "Yesterday"
            } else if let d = cal.dateComponents([.day], from: m.createdAt, to: .now).day, d < 7 {
                title = "This Week"
            } else {
                title = m.createdAt.formatted(.dateTime.month(.wide).year())
            }
            if let i = out.firstIndex(where: { $0.title == title }) {
                out[i] = MeetingGroup(title: title, meetings: out[i].meetings + [m])
            } else {
                out.append(MeetingGroup(title: title, meetings: [m]))
            }
        }
        return out
    }
}

struct MeetingCard: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    @State private var hovering = false

    var body: some View {
        Button {
            model.selection = .meeting(meeting.id)
        } label: {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text(meeting.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: Space.s)
                    status
                }
                Text(snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                HStack(spacing: Space.s) {
                    HStack(spacing: -7) {
                        ForEach(meeting.speakers.prefix(5)) { s in
                            Avatar(name: s.displayName, color: s.color(voices: model.voices.prints), size: 24,
                                   dashed: s.name == nil)
                                .overlay(Circle().stroke(.background, lineWidth: 1.5))
                        }
                    }
                    if meeting.speakers.count > 5 {
                        Text("+\(meeting.speakers.count - 5)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Label(meeting.createdAt.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                    Label(meeting.duration.humanDuration, systemImage: "waveform")
                }
                .labelStyle(CompactLabelStyle())
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(Space.l + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(radius: Radius.tile, elevation: hovering ? 1.2 : 0.6)
            .scaleEffect(hovering ? 1.01 : 1)
            .contentShape(.rect(cornerRadius: Radius.tile))
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteMeeting(meeting.id) }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch meeting.status {
        case .recording:
            Label("Live", systemImage: "record.circle.fill")
                .labelStyle(CompactLabelStyle())
                .font(.caption.weight(.bold))
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
        case .processing:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ready:
            if meeting.summary != nil {
                Image(systemName: "sparkles").foregroundStyle(.purple).help("Has a summary")
            }
        }
    }

    private var snippet: String {
        if let s = meeting.summary, !s.isEmpty {
            return s.components(separatedBy: "\n").first { !$0.isEmpty && !$0.hasPrefix("**") } ?? s
        }
        if meeting.status == .recording { return "Recording in progress…" }
        if meeting.status == .processing { return meeting.statusDetail ?? "Transcribing…" }
        return meeting.segments.prefix(3).map(\.text).joined(separator: " ")
    }
}
