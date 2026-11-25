import AppKit
import MurmurCore
import SwiftUI
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    let meetingID: UUID
    @State private var title = ""
    @State private var assigning: Speaker?
    @State private var confirmDelete = false
    @State private var filter = ""

    private var meeting: Meeting? { model.meetings.meeting(meetingID) }

    var body: some View {
        if let meeting {
            content(meeting)
                .navigationTitle(meeting.title)
                .navigationSubtitle(subtitle(meeting))
                .toolbar { toolbar(meeting) }
                .safeAreaInset(edge: .bottom) {
                    if meeting.status == .ready { PlayerBar(meetingID: meetingID) }
                }
                .sheet(item: $assigning) { speaker in
                    SpeakerAssignSheet(meetingID: meetingID, speaker: speaker)
                }
                .confirmationDialog("Delete “\(meeting.title)”?", isPresented: $confirmDelete) {
                    Button("Move to Trash", role: .destructive) { model.deleteMeeting(meetingID) }
                } message: {
                    Text("The transcript and audio are moved to the Trash.")
                }
                .onAppear { title = meeting.title }
        }
    }

    private func subtitle(_ m: Meeting) -> String {
        var parts = [m.createdAt.formatted(date: .abbreviated, time: .shortened), m.duration.humanDuration]
        if let app = m.sourceApp { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        switch meeting.status {
        case .processing, .recording:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(meeting.statusDetail ?? "Processing…").font(.title3)
                Text("Runs on the Neural Engine — about a minute per hour of audio.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Transcription didn't finish", systemImage: "exclamationmark.triangle")
            } description: {
                Text(meeting.statusDetail ?? "")
            } actions: {
                Button("Retry") { model.reprocess(meetingID) }
                    .buttonStyle(.glassProminent).controlSize(.extraLarge)
            }
        case .ready:
            transcript(meeting)
        }
    }

    private func transcript(_ meeting: Meeting) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.s, pinnedViews: []) {
                    TextField("Title", text: $title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .textFieldStyle(.plain)
                        .onSubmit { model.meetings.update(meetingID) { $0.title = title } }

                    SpeakerStrip(meeting: meeting) { assigning = $0 }
                        .padding(.bottom, Space.s)
                    SummaryCard(meeting: meeting)
                        .padding(.bottom, Space.l)

                    if meeting.segments.isEmpty {
                        ContentUnavailableView(
                            "No speech detected", systemImage: "waveform.slash",
                            description: Text("The recording didn't contain recognisable speech."))
                    }
                    ForEach(visibleSegments(meeting)) { seg in
                        SegmentRow(meeting: meeting, segment: seg) { s in assigning = s }
                            .padding(.horizontal, -Space.m)
                            .depthOfField()
                            .id(seg.id)
                    }
                }
                .padding(.vertical, Space.xl)
                .pageColumn()
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .background { AmbientBackdrop(tint: meeting.speakers.first?.color(voices: model.voices.prints) ?? .accentColor) }
            .searchable(text: $filter, placement: .toolbar, prompt: "Find in transcript")
            .onChange(of: model.player.currentTime) {
                guard model.player.isPlaying, model.player.meetingID == meetingID,
                    let seg = meeting.segments.last(where: { $0.start <= model.player.currentTime })
                else { return }
                withAnimation(.smooth) { proxy.scrollTo(seg.id, anchor: .center) }
            }
        }
    }

    private func visibleSegments(_ m: Meeting) -> [TranscriptSegment] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return m.segments }
        return m.segments.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    @ToolbarContentBuilder
    private func toolbar(_ meeting: Meeting) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(meeting.plainText, forType: .string)
            } label: {
                Label("Copy transcript", systemImage: "doc.on.doc")
            }
            Menu {
                Button("Markdown (.md)") { export(meeting, ext: "md", text: meeting.markdown) }
                Button("Plain text (.txt)") { export(meeting, ext: "txt", text: meeting.plainText) }
                Button("Subtitles (.srt)") { export(meeting, ext: "srt", text: meeting.srt) }
                Divider()
                Button("Show audio in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.meetingFolder(meetingID)])
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            Menu {
                Button("Transcribe again", systemImage: "arrow.clockwise") { model.reprocess(meetingID) }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func export(_ meeting: Meeting, ext: String, text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.title).\(ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Speakers

struct SpeakerStrip: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    var onSelect: (Speaker) -> Void

    /// Chip geometry: 48 pt capsule, 36 pt avatar, 6 pt inset, so the avatar's circle is
    /// concentric with the capsule's rounded end.
    private let chipHeight: CGFloat = 48
    private let avatar: CGFloat = 36

    var body: some View {
        let total = max(1, meeting.speakers.map(\.talkTime).reduce(0, +))
        let inset = (chipHeight - avatar) / 2
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: Space.m) {
                HStack(spacing: Space.s + 2) {
                    ForEach(meeting.speakers) { s in
                        let color = s.color(voices: model.voices.prints)
                        Button {
                            onSelect(s)
                        } label: {
                            HStack(spacing: Space.s + 2) {
                                Avatar(name: s.displayName, color: color, size: avatar, dashed: s.name == nil)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: Space.xs) {
                                        Text(s.displayName).font(.callout.weight(.semibold))
                                        if s.name != nil, !s.isConfirmed {
                                            Image(systemName: "sparkles").font(.caption2).foregroundStyle(.secondary)
                                                .help("Recognised by voice — tap to confirm")
                                        }
                                    }
                                    Text("\(Int(s.talkTime / total * 100))% · \(s.track == .mic ? "mic" : "call")")
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .padding(.leading, inset)
                            .padding(.trailing, Space.l + 2)
                            .frame(height: chipHeight)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(color.opacity(s.name == nil ? 0 : 0.08)).interactive(), in: .capsule)
                    }
                }
                .padding(.vertical, Space.xs)
            }
        }
        .scrollClipDisabled()
    }
}

struct SegmentRow: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    let segment: TranscriptSegment
    var onAssign: (Speaker) -> Void

    private let avatarSize: CGFloat = 36

    var body: some View {
        let speaker = meeting.speaker(segment.speakerID)
        let color = speaker?.color(voices: model.voices.prints) ?? .gray
        let playingHere = model.player.meetingID == meeting.id && model.player.isPlaying
        let active = playingHere && (segment.start...segment.end).contains(model.player.currentTime)
        HStack(alignment: .firstTextBaseline, spacing: Space.m + 2) {
            Button {
                if let speaker { onAssign(speaker) }
            } label: {
                Avatar(name: speaker?.displayName ?? "?", color: color, size: avatarSize, dashed: speaker?.name == nil)
                    .frame(width: avatarSize, height: Theme.touchTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // Centre the avatar on the name line rather than the paragraph's top edge.
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

            VStack(alignment: .leading, spacing: Space.xs + 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Button {
                        if let speaker { onAssign(speaker) }
                    } label: {
                        Text(speaker?.displayName ?? "Unknown").font(.callout.weight(.semibold))
                            .foregroundStyle(color)
                    }
                    .buttonStyle(.plain)
                    Button {
                        model.player.play(meeting: meeting.id, from: segment.start)
                    } label: {
                        Label(segment.start.clock, systemImage: "play.fill")
                            .labelStyle(TimestampLabelStyle())
                    }
                    .buttonStyle(.plain)
                    .help("Play from here")
                }
                Text(segment.text)
                    .font(.system(size: 15.5))
                    .lineSpacing(3.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.m)
        .padding(.horizontal, Space.m)
        .background {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(color.opacity(active ? 0.12 : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .strokeBorder(color.opacity(active ? 0.25 : 0), lineWidth: 0.75)
                }
        }
        .focus(active, dimmed: playingHere)
    }
}

/// Small capsule timestamp with a play glyph that appears on hover/press.
struct TimestampLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 7, weight: .bold))
            configuration.title.font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.s)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

struct SpeakerAssignSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meetingID: UUID
    let speaker: Speaker
    @State private var name = ""

    var body: some View {
        let meeting = model.meetings.meeting(meetingID)
        let sample = meeting?.segments.filter { $0.speakerID == speaker.id }.max { ($0.end - $0.start) < ($1.end - $1.start) }
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Avatar(name: speaker.displayName, color: speaker.color(voices: model.voices.prints), size: 52,
                       dashed: speaker.name == nil)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Who is this?").font(.title2.weight(.semibold))
                    Group {
                        if let score = speaker.matchScore, !speaker.isConfirmed {
                            Text("Recognised as \(speaker.displayName) (\(Int(score * 100))% match)")
                        } else {
                            Text("Murmur will remember this voice for future meetings.")
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let sample {
                    Button {
                        model.player.play(meeting: meetingID, from: sample.start, until: min(sample.end, sample.start + 8))
                    } label: {
                        Label("Listen", systemImage: "play.fill").frame(minHeight: 30)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            }

            if let sample {
                Text("“\(sample.text.prefix(180))\(sample.text.count > 180 ? "…" : "")”")
                    .font(.callout).italic().foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
            }

            if speaker.name != nil, !speaker.isConfirmed {
                Button {
                    model.assign(name: speaker.displayName, speakerID: speaker.id, meetingID: meetingID)
                    dismiss()
                } label: {
                    Label("Yes, that's \(speaker.displayName)", systemImage: "checkmark").frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }

            let suggestions = suggestionNames
            if !suggestions.isEmpty {
                Text("Known voices").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                FlowLayout(spacing: 8) {
                    ForEach(suggestions, id: \.self) { n in
                        Button {
                            model.assign(name: n, speakerID: speaker.id, meetingID: meetingID)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Avatar(name: n, color: color(for: n), size: 24)
                                Text(n)
                            }
                            .padding(.trailing, 6)
                            .frame(minHeight: 34)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("New name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.extraLarge)
                    .onSubmit(save)
                Button("Save", action: save)
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                if speaker.isConfirmed {
                    Button("Forget name in this meeting", role: .destructive) {
                        SpeakerNaming.clear(speaker.id, in: meetingID, store: model.meetings)
                        dismiss()
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("Done") { dismiss() }.controlSize(.large).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var suggestionNames: [String] {
        var names = [model.meName]
        names += model.voices.prints.sorted { $0.updatedAt > $1.updatedAt }.map(\.name)
        // Names already used in this meeting by other speakers go last.
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted && $0 != speaker.name }
    }

    private func color(for name: String) -> Color {
        if let p = model.voices.print(named: name) { return Theme.color(p.colorIndex) }
        return .accentColor
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        model.assign(name: n, speakerID: speaker.id, meetingID: meetingID)
        dismiss()
    }
}

struct SummaryCard: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting

    var body: some View {
        let busy = model.summarizing.contains(meeting.id)
        if meeting.summary != nil || busy || Summarizer.isAvailable {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Summary", systemImage: "sparkles").font(.headline)
                    Spacer()
                    if busy {
                        ProgressView().controlSize(.small)
                    } else if Summarizer.isAvailable {
                        Button(meeting.summary == nil ? "Summarize" : "Regenerate") {
                            Task { await model.summarize(meeting.id) }
                        }
                        .buttonStyle(.glass)
                    }
                }
                if let summary = meeting.summary {
                    SummaryText(markdown: summary)
                } else if busy {
                    Text("Writing notes with Apple Intelligence, on device…").foregroundStyle(.secondary)
                }
            }
            .padding(Space.xl)
            .background {
                LinearGradient(colors: [.purple.opacity(0.10), .blue.opacity(0.05), .clear], startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                    .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
            }
            .surface(radius: Radius.card, elevation: 0.7)
        }
    }
}

struct PlayerBar: View {
    @Environment(AppModel.self) private var model
    let meetingID: UUID

    var body: some View {
        let player = model.player
        let mine = player.meetingID == meetingID
        HStack(spacing: Space.m) {
            Button {
                player.toggle(meeting: meetingID)
            } label: {
                Image(systemName: mine && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            Text((mine ? player.currentTime : 0).clock).monospacedDigit().foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { mine ? player.currentTime : 0 },
                    set: { player.load(meetingID); player.seek($0) }),
                in: 0...max(1, mine ? player.duration : (model.meetings.meeting(meetingID)?.duration ?? 1)))
            Text((model.meetings.meeting(meetingID)?.duration ?? 0).clock).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.leading, 6)
        .padding(.trailing, Space.xl)
        .frame(height: 52)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.10), radius: 16, y: 8)
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.l)
        .frame(maxWidth: 760)
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 {
                x = 0
                y += row + spacing
                row = 0
            }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

/// Renders the summary's small Markdown dialect: paragraphs, **headings**, bullets and checkboxes.
struct SummaryText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let t):
                    Text(t)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .padding(.top, Space.s)
                case .paragraph(let t):
                    Text(inline(t)).fixedSize(horizontal: false, vertical: true)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Circle().fill(.secondary).frame(width: 4.5, height: 4.5)
                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                        Text(inline(t)).fixedSize(horizontal: false, vertical: true)
                    }
                case .task(let t, let done):
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(done ? Color.green : Color.secondary)
                        Text(inline(t)).strikethrough(done).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    enum Block { case heading(String), paragraph(String), bullet(String), task(String, Bool) }

    private var blocks: [Block] {
        markdown.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
                return .heading(String(line.dropFirst(2).dropLast(2)))
            }
            if line.hasPrefix("- [ ] ") { return .task(String(line.dropFirst(6)), false) }
            if line.lowercased().hasPrefix("- [x] ") { return .task(String(line.dropFirst(6)), true) }
            if line.hasPrefix("- ") || line.hasPrefix("• ") { return .bullet(String(line.dropFirst(2))) }
            if line.hasPrefix("#") { return .heading(line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) }
            return .paragraph(line)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
