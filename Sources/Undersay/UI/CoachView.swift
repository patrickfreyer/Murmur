import UndersayCore
import SwiftUI

/// Communication coaching: one habit to focus on, the numbers behind it, your commitments, a tone
/// check and on-demand feedback per meeting. The report is computed off the main thread, only
/// while this page is open.
struct CoachView: View {
    @Environment(AppModel.self) private var model
    @State private var report: Coach.Report?
    @State private var expanded: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                if let r = report {
                    focusHero(r)
                    metrics(r)
                    HStack(alignment: .top, spacing: Space.l) {
                        commitmentsCard(r, mine: true)
                        commitmentsCard(r, mine: false)
                    }
                    HStack(alignment: .top, spacing: Space.l) {
                        toneCard(r)
                        hedgesCard(r)
                    }
                    meetingsCard(r)
                    Text("Counts come straight from your transcripts and dictations. Tone uses Apple's on-device sentiment model, and feedback uses Apple Intelligence only when you ask for it. Nothing leaves your Mac.")
                        .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, Space.xs)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(.vertical, Space.xl)
            .pageColumn(maxWidth: 1000)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .background { AmbientBackdrop(tint: report.map { color($0.focus) } ?? .teal) }
        .navigationTitle("Coach")
        .task(id: "\(model.meetings.meetings.count)-\(model.dictations.items.count)-\(model.voices.prints.count)") {
            await refresh()
        }
    }

    private func refresh() async {
        let meetings = model.meetings.meetings, dictations = model.dictations.items
        let voices = model.voices.prints, me = model.meName
        let r = await Task.detached(priority: .userInitiated) {
            Coach.report(meetings: meetings, dictations: dictations, voices: voices, meName: me)
        }.value
        withAnimation(.smooth) { report = r }
        model.coachFocus = r.focus
    }

    private func color(_ f: Coach.Focus) -> Color {
        switch f {
        case .leaveRoom: .orange
        case .askMore: .blue
        case .letFinish: .pink
        case .beDirect: .purple
        case .slowDown: .teal
        case .keepItUp: .green
        case .needData: .gray
        }
    }

    // MARK: - Focus

    private func focusHero(_ r: Coach.Report) -> some View {
        let tint = color(r.focus)
        return HStack(alignment: .top, spacing: Space.xl) {
            Image(systemName: r.focus.symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(tint.gradient))
                .shadow(color: tint.opacity(0.45), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: Space.s) {
                Text("THIS WEEK'S FOCUS").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                Text(r.focus.title).font(.system(size: 30, weight: .bold, design: .rounded))
                if !r.evidence.isEmpty {
                    Text(r.evidence).font(.callout.weight(.medium)).foregroundStyle(tint)
                }
                Text(r.focus.tip).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [tint.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(.rect(cornerRadius: Radius.hero, style: .continuous))
        }
        .surface(radius: Radius.hero, elevation: 1)
    }

    // MARK: - Metrics

    private func metrics(_ r: Coach.Report) -> some View {
        let now = r.thisWeek.meetings > 0 ? r.thisWeek : nil
        return HStack(spacing: Space.l) {
            MetricTile(title: "Your airtime", value: now?.talkShare.map { "\(Int($0 * 100))%" },
                       delta: delta(now?.talkShare, r.lastWeek.talkShare), lowerIsBetter: true, symbol: "chart.pie.fill", tint: .orange)
            MetricTile(title: "Questions / meeting", value: now?.questionsPerMeeting.map { String(format: "%.1f", $0) },
                       delta: delta(now?.questionsPerMeeting, r.lastWeek.questionsPerMeeting), lowerIsBetter: false, symbol: "questionmark.bubble.fill", tint: .blue)
            MetricTile(title: "Cut-ins / meeting", value: now?.cutInsPerMeeting.map { String(format: "%.1f", $0) },
                       delta: delta(now?.cutInsPerMeeting, r.lastWeek.cutInsPerMeeting), lowerIsBetter: true, symbol: "hand.raised.fill", tint: .pink)
            MetricTile(title: "Hedges / 100 words", value: r.hedgesPer100.map { String(format: "%.1f", $0) },
                       delta: nil, lowerIsBetter: true, symbol: "text.word.spacing", tint: .purple)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func delta(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a - b
    }

    // MARK: - Commitments

    private func commitmentsCard(_ r: Coach.Report, mine: Bool) -> some View {
        let items = r.commitments.filter { $0.isYou == mine }.prefix(6)
        return CoachCard(title: mine ? "You said you'd…" : "Waiting on others", symbol: mine ? "checklist" : "hourglass",
                         tint: mine ? .green : .indigo) {
            if items.isEmpty {
                Text(mine ? "No promises found in recent meetings." : "Nobody owes you anything right now.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(items)) { c in
                let done = model.coachDone.contains(c.id)
                HStack(alignment: .top, spacing: Space.s + 2) {
                    if mine {
                        Button {
                            model.toggleCoachDone(c.id)
                        } label: {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17))
                                .foregroundStyle(done ? Color.green : Color.secondary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                    } else {
                        FaceAvatar(name: c.who, color: .indigo, size: 20)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mine ? c.text : "\(c.who): \(c.text)")
                            .font(.callout)
                            .strikethrough(done)
                            .foregroundStyle(done ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(c.meetingTitle + " · " + c.date.formatted(.dateTime.month().day())) {
                            model.selection = .meeting(c.meetingID)
                        }
                        .buttonStyle(.plain)
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Tone and hedges

    private func toneCard(_ r: Coach.Report) -> some View {
        CoachCard(title: "Tone check", symbol: "thermometer.medium", tint: .red) {
            if r.toneMoments.isEmpty {
                Label("Nothing harsh in the last 30 days.", systemImage: "hand.thumbsup.fill")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(r.toneMoments.prefix(4)) { t in
                VStack(alignment: .leading, spacing: 3) {
                    Text("“\(t.text)”").font(.callout).italic().fixedSize(horizontal: false, vertical: true)
                    Text("\(t.source) · \(t.date.formatted(.dateTime.month().day()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, Space.s + 2)
                .overlay(alignment: .leading) { Capsule().fill(.red.opacity(0.6)).frame(width: 3) }
            }
            if !r.toneMoments.isEmpty {
                Text("Read these as the other person would. Is there a way to say it that keeps them on your side?")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func hedgesCard(_ r: Coach.Report) -> some View {
        CoachCard(title: "Softening words", symbol: "text.word.spacing", tint: .purple) {
            if r.hedgeTotals.isEmpty {
                Text("No hedging words yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: Space.s) {
                    ForEach(r.hedgeTotals.prefix(10), id: \.phrase) { h in
                        HStack(spacing: 4) {
                            Text("“\(h.phrase)”").font(.callout)
                            Text("\(h.count)").font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(.purple)
                        }
                        .padding(.horizontal, Space.m).padding(.vertical, 5)
                        .background(.purple.opacity(0.1), in: .capsule)
                    }
                }
                Text("A few are natural. When you're sure, leave them out and the point lands harder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Meetings

    private func meetingsCard(_ r: Coach.Report) -> some View {
        CoachCard(title: "Meetings", symbol: "person.2.wave.2.fill", tint: .teal) {
            if r.meetings.isEmpty {
                Text("Once you're recognised in a meeting (name yourself once, or dictate a few times), it shows up here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(r.meetings.prefix(8)) { m in
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(m.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 210, alignment: .leading)
                        if m.hasOthers {
                            AirtimeBar(share: m.yourTalkShare).frame(width: 120)
                            Label("\(m.questions)", systemImage: "questionmark.bubble").help("Questions you asked")
                            Label("\(m.cutIns)", systemImage: "hand.raised").help("Times you cut in")
                        }
                        Spacer()
                        feedbackButton(m.id)
                    }
                    .labelStyle(CompactLabelStyle())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    if expanded == m.id, let notes = model.meetings.meeting(m.id)?.coaching {
                        FeedbackView(notes: notes).transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.vertical, Space.xs)
                if m.id != r.meetings.prefix(8).last?.id { Divider() }
            }
        }
    }

    @ViewBuilder
    private func feedbackButton(_ id: UUID) -> some View {
        if model.coaching.contains(id) {
            ProgressView().controlSize(.small).frame(width: 110)
        } else if model.meetings.meeting(id)?.coaching != nil {
            Button(expanded == id ? "Hide feedback" : "Show feedback") {
                withAnimation(.smooth) { expanded = expanded == id ? nil : id }
            }
            .buttonStyle(.glass)
        } else if Summarizer.isAvailable {
            Button {
                Task {
                    await model.coach(id)
                    withAnimation(.smooth) { expanded = id }
                }
            } label: {
                Label("Get feedback", systemImage: "sparkles")
            }
            .buttonStyle(.glass)
            .help("Apple Intelligence reads your lines in this meeting, on your Mac")
        }
    }
}

// MARK: - Components

private struct CoachCard<Content: View>: View {
    var title: String
    var symbol: String
    var tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Circle().fill(tint.gradient))
            }
            content
        }
        .padding(Space.xl - 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .surface(radius: Radius.card, elevation: 0.6)
    }
}

private struct MetricTile: View {
    var title: String
    var value: String?
    var delta: Double?
    var lowerIsBetter: Bool
    var symbol: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
                Spacer()
                if let delta, abs(delta) > 0.001 {
                    let good = lowerIsBetter ? delta < 0 : delta > 0
                    Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(good ? .green : .orange)
                        .help("Compared with last week")
                }
            }
            Text(value ?? "–").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .surface(radius: Radius.tile, elevation: 0.5)
    }
}

private struct AirtimeBar: View {
    var share: Double

    var body: some View {
        HStack(spacing: Space.xs + 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill((share > 0.6 ? Color.orange : Color.teal).gradient)
                        .frame(width: max(4, geo.size.width * share))
                }
            }
            .frame(height: 6)
            Text("\(Int(share * 100))%").frame(width: 34, alignment: .trailing)
        }
        .help("Your share of the talking")
    }
}

private struct FeedbackView: View {
    let notes: CoachingNotes

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(notes.strengths, id: \.self) { s in
                Label { Text(s).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            ForEach(notes.improvements, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(i.quote)”").strikethrough().foregroundStyle(.secondary)
                    Label { Text("“\(i.better)”").fontWeight(.medium) } icon: {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.purple)
                    }
                    Text(i.why).font(.caption).foregroundStyle(.secondary)
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.purple.opacity(0.07), in: .rect(cornerRadius: Radius.inset, style: .continuous))
            }
            if notes.improvements.isEmpty {
                Text("No specific rewrites this time.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.top, Space.xs)
    }
}
