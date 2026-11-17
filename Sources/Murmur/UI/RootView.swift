import MurmurCore
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
        case .dictations:
            DictationsView()
        case .voices:
            VoicesView()
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
                RecordButton()
                    .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 10, trailing: 6))
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }

            Section {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                    .frame(minHeight: 30)
                Label {
                    HStack {
                        Text("Dictation")
                        Spacer()
                        Text("\(model.dictations.items.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "text.bubble")
                }
                .tag(SidebarItem.dictations)
                .frame(minHeight: 30)
                Label {
                    HStack {
                        Text("Voices")
                        Spacer()
                        Text("\(model.voices.prints.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "person.wave.2")
                }
                .tag(SidebarItem.voices)
                .frame(minHeight: 30)
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

    var body: some View {
        let recording = model.recorder.isRecording
        Button {
            model.toggleMeeting()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: recording ? "stop.fill" : "record.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolEffect(.pulse, isActive: recording)
                if recording, let start = model.recorder.startedAt {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                    Spacer()
                    Text("Stop").fontWeight(.semibold)
                } else {
                    Text("Record Meeting").fontWeight(.semibold)
                    Spacer()
                    Text("⇧⌘R").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(recording ? .red : .accentColor)
        .controlSize(.large)
        .disabled(model.recorder.state == .finishing)
    }
}
