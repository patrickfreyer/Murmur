import Foundation
import NaturalLanguage

/// Light-weight communication coaching from transcripts and dictations.
///
/// Everything here is plain counting over text the app already has (no model, no audio work), and
/// it only runs when the Coach page is opened. The things counting can't judge well (tone, better
/// phrasing) live in `CoachFeedback`, which uses the on-device model only when asked, per meeting.
public enum Coach {
    public static let hedges = [
        "just", "i think", "sort of", "kind of", "maybe", "sorry", "i guess", "probably", "a little bit",
        "basically", "actually", "literally", "you know", "i feel like", "i mean",
    ]

    public struct Commitment: Sendable, Identifiable, Hashable {
        public var id: String
        public var who: String
        public var isYou: Bool
        public var text: String
        public var meetingID: UUID
        public var meetingTitle: String
        public var date: Date
    }

    public struct MeetingStats: Sendable, Identifiable {
        public var id: UUID
        public var title: String
        public var date: Date
        public var hasOthers: Bool
        public var yourTalkShare: Double
        public var yourWords: Int
        public var wordsPerMinute: Double?
        public var questions: Int
        /// Times you started talking while someone else was mid-sentence.
        public var cutIns: Int
        public var longestStretch: TimeInterval
        public var hedgeCount: Int
    }

    public enum Focus: String, Sendable {
        case leaveRoom, askMore, letFinish, beDirect, slowDown, keepItUp, needData

        public var title: String {
            switch self {
            case .leaveRoom: "Leave more room"
            case .askMore: "Ask more questions"
            case .letFinish: "Let people finish"
            case .beDirect: "Say it with confidence"
            case .slowDown: "Slow down a little"
            case .keepItUp: "Keep it up"
            case .needData: "Record a few meetings"
            }
        }

        public var tip: String {
            switch self {
            case .leaveRoom:
                "You do most of the talking. After you make a point, pause and ask what others think before adding more."
            case .askMore:
                "Questions bring people in. Try one open question per topic: “What would you do differently?”, “What am I missing?”"
            case .letFinish:
                "You often start while someone is mid-sentence. Wait a beat after they stop. It also gives you time to answer better."
            case .beDirect:
                "Words like “just”, “I think” and “sort of” soften your point. Drop them when you mean it: “Let’s ship Thursday.”"
            case .slowDown:
                "You speak fast in meetings. Short pauses after key points help people follow and make you sound more certain."
            case .keepItUp:
                "Balanced airtime, plenty of questions, clear wording. Nothing stands out to fix this week."
            case .needData:
                "Coaching needs a few meetings where you're recognised by voice. Name yourself in a transcript or dictate a few times."
            }
        }

        public var symbol: String {
            switch self {
            case .leaveRoom: "person.2.wave.2"
            case .askMore: "questionmark.bubble"
            case .letFinish: "hand.raised"
            case .beDirect: "arrow.right.circle"
            case .slowDown: "tortoise"
            case .keepItUp: "hands.clap"
            case .needData: "waveform.badge.plus"
            }
        }
    }

    /// A sentence of yours that Apple's on-device sentiment model reads as clearly negative.
    public struct ToneMoment: Sendable, Identifiable, Hashable {
        public var id: String { text }
        public var text: String
        public var score: Double
        public var source: String
        public var date: Date
        public var meetingID: UUID?
    }

    public struct Report: Sendable {
        public var toneMoments: [ToneMoment] = []
        public var meetings: [MeetingStats] = []
        public var commitments: [Commitment] = []
        public var hedgeTotals: [(phrase: String, count: Int)] = []
        public var hedgesPer100: Double?
        public var focus: Focus = .needData
        public var evidence: String = ""
        /// Averages over the last 7 days and the 7 before, for trend arrows.
        public var thisWeek = Window()
        public var lastWeek = Window()

        public struct Window: Sendable {
            public var meetings = 0
            public var talkShare: Double?
            public var questionsPerMeeting: Double?
            public var cutInsPerMeeting: Double?
            public var wordsPerMinute: Double?
            public var hedgesPer100: Double?
        }
    }

    // MARK: - Report

    public static func report(
        meetings: [Meeting], dictations: [Dictation], voices: [VoicePrint], meName: String, now: Date = .now
    ) -> Report {
        var r = Report()
        let me = voices.first(where: \.isMe)
        func isYou(_ s: Speaker) -> Bool {
            if let me, s.voicePrintID == me.id { return true }
            return s.name != nil && s.name == meName
        }

        var hedgeCounts: [String: Int] = [:]
        var allYourWords = 0
        var toneCandidates: [(String, String, Date, UUID?)] = []
        for m in meetings where m.status == .ready {
            let you = Set(m.speakers.filter(isYou).map(\.id))
            guard !you.isEmpty else { continue }
            let yours = m.segments.filter { you.contains($0.speakerID) }
            let others = m.segments.filter { !you.contains($0.speakerID) }
            let yourText = yours.map(\.text).joined(separator: " ")
            let yourWords = yourText.split(whereSeparator: \.isWhitespace).count
            let yourTime = yours.reduce(0) { $0 + ($1.end - $1.start) }
            let totalTime = m.segments.reduce(0) { $0 + ($1.end - $1.start) }
            let hedgesHere = countHedges(yourText, into: &hedgeCounts)
            allYourWords += yourWords

            var cutIns = 0
            for y in yours where others.contains(where: { $0.start + 0.5 < y.start && y.start < $0.end - 0.3 }) {
                cutIns += 1
            }
            // Longest stretch: your consecutive segments with short gaps.
            var longest: TimeInterval = 0, runStart: TimeInterval?, runEnd: TimeInterval = 0
            for seg in m.segments.sorted(by: { $0.start < $1.start }) {
                if you.contains(seg.speakerID) {
                    if let s = runStart, seg.start - runEnd < 2 { runEnd = seg.end; longest = max(longest, runEnd - s) }
                    else { runStart = seg.start; runEnd = seg.end; longest = max(longest, seg.end - seg.start) }
                } else {
                    runStart = nil
                }
            }
            r.meetings.append(MeetingStats(
                id: m.id, title: m.title, date: m.createdAt, hasOthers: !others.isEmpty,
                yourTalkShare: totalTime > 0 ? yourTime / totalTime : 0, yourWords: yourWords,
                wordsPerMinute: yourTime > 20 ? Double(yourWords) / (yourTime / 60) : nil,
                questions: yours.reduce(0) { $0 + $1.text.filter { $0 == "?" }.count },
                cutIns: cutIns, longestStretch: longest, hedgeCount: hedgesHere))

            if now.timeIntervalSince(m.createdAt) < 30 * 86_400 {
                for seg in yours { toneCandidates.append((seg.text, m.title, m.createdAt, m.id)) }
            }
            for seg in m.segments {
                guard let sp = m.speaker(seg.speakerID), let who = you.contains(sp.id) ? meName : sp.name else { continue }
                for c in commitments(in: seg.text) {
                    r.commitments.append(Commitment(
                        id: "\(m.id.uuidString)-\(stableHash(c))", who: who, isYou: you.contains(sp.id), text: c,
                        meetingID: m.id, meetingTitle: m.title, date: m.createdAt))
                }
            }
        }
        // Dictations are your words too (writing style).
        for d in dictations {
            allYourWords += d.text.split(whereSeparator: \.isWhitespace).count
            _ = countHedges(d.text, into: &hedgeCounts)
            if now.timeIntervalSince(d.createdAt) < 30 * 86_400 {
                toneCandidates.append((d.text, d.appName.map { "Dictation in \($0)" } ?? "Dictation", d.createdAt, nil))
            }
        }
        r.toneMoments = toneMoments(toneCandidates)
        r.meetings.sort { $0.date > $1.date }
        r.commitments.sort { $0.date > $1.date }
        r.hedgeTotals = hedgeCounts.map { ($0.key, $0.value) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        let totalHedges = hedgeCounts.values.reduce(0, +)
        if allYourWords >= 100 { r.hedgesPer100 = Double(totalHedges) / Double(allYourWords) * 100 }

        let day: TimeInterval = 86_400
        r.thisWeek = window(r.meetings.filter { now.timeIntervalSince($0.date) < 7 * day })
        r.lastWeek = window(r.meetings.filter { (7 * day..<14 * day).contains(now.timeIntervalSince($0.date)) })
        r.thisWeek.hedgesPer100 = r.hedgesPer100
        (r.focus, r.evidence) = pickFocus(r)
        return r
    }

    static func window(_ ms: [MeetingStats]) -> Report.Window {
        var w = Report.Window()
        let social = ms.filter(\.hasOthers)
        w.meetings = social.count
        guard !social.isEmpty else { return w }
        let n = Double(social.count)
        w.talkShare = social.map(\.yourTalkShare).reduce(0, +) / n
        w.questionsPerMeeting = Double(social.map(\.questions).reduce(0, +)) / n
        w.cutInsPerMeeting = Double(social.map(\.cutIns).reduce(0, +)) / n
        let paces = social.compactMap(\.wordsPerMinute)
        if !paces.isEmpty { w.wordsPerMinute = paces.reduce(0, +) / Double(paces.count) }
        return w
    }

    /// Picks the one habit that stands out most against simple targets. Deterministic on purpose.
    static func pickFocus(_ r: Report) -> (Focus, String) {
        let recent = r.thisWeek.meetings > 0 ? r.thisWeek : window(Array(r.meetings.prefix(5)))
        guard recent.meetings > 0 else {
            if let h = r.hedgesPer100, h > 3 {
                return (.beDirect, String(format: "%.1f hedge words per 100 words in your dictations.", h))
            }
            return (.needData, "")
        }
        // Targets start from sensible defaults and move toward your own history once there is enough
        // of it, so "too much" means "more than usual for you", not "more than a number I picked".
        let history = window(Array(r.meetings.dropFirst(recent.meetings)))
        let personal = history.meetings >= 6
        let talkTarget = personal ? max(0.6, (history.talkShare ?? 0.6) * 1.15) : 0.6
        let questionTarget = personal ? min(2, max(1, (history.questionsPerMeeting ?? 2) * 0.85)) : 2
        let cutInTarget = personal ? max(2, (history.cutInsPerMeeting ?? 2) * 1.25) : 2
        let paceTarget = personal ? max(175, (history.wordsPerMinute ?? 175) * 1.12) : 175
        var candidates: [(Focus, Double, String)] = []
        if let t = recent.talkShare, t > talkTarget {
            candidates.append((.leaveRoom, t / talkTarget, "You spoke \(Int(t * 100))% of the time in \(recent.meetings) meeting\(recent.meetings == 1 ? "" : "s")."))
        }
        if let q = recent.questionsPerMeeting, q < questionTarget {
            candidates.append((.askMore, (questionTarget - q) / questionTarget + 1, String(format: "You asked %.1f questions per meeting.", q)))
        }
        if let c = recent.cutInsPerMeeting, c >= cutInTarget {
            candidates.append((.letFinish, c / cutInTarget, String(format: "You cut in %.1f times per meeting.", c)))
        }
        if let h = r.hedgesPer100, h > 3 {
            candidates.append((.beDirect, h / 3, String(format: "%.1f hedge words per 100 words.", h)))
        }
        if let w = recent.wordsPerMinute, w > paceTarget {
            candidates.append((.slowDown, w / paceTarget, "You averaged \(Int(w)) words per minute in meetings."))
        }
        guard let top = candidates.max(by: { $0.1 < $1.1 }) else { return (.keepItUp, "") }
        return (top.0, top.2)
    }

    // MARK: - Tone

    /// Sentences scoring at or below this read as clearly negative; milder scores are noise.
    public static let negativeThreshold = -0.6

    static func toneMoments(_ candidates: [(String, String, Date, UUID?)]) -> [ToneMoment] {
        // Score each sentence on its own: tagging by sentence inside a paragraph hands every
        // sentence the paragraph's score.
        let splitter = NLTokenizer(unit: .sentence)
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        var out: [ToneMoment] = []
        for (text, source, date, meeting) in candidates {
            splitter.string = text
            splitter.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard sentence.split(separator: " ").count >= 3 else { return true }
                tagger.string = sentence
                let (tag, _) = tagger.tag(at: sentence.startIndex, unit: .paragraph, scheme: .sentimentScore)
                if let raw = tag?.rawValue, let score = Double(raw), score <= negativeThreshold {
                    out.append(ToneMoment(text: sentence, score: score, source: source, date: date, meetingID: meeting))
                }
                return true
            }
        }
        return Array(Set(out)).sorted { $0.date > $1.date }
    }

    // MARK: - Text helpers

    static func countHedges(_ text: String, into totals: inout [String: Int]) -> Int {
        let lower = " " + text.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        var n = 0
        for h in hedges {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: h) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let c = re.numberOfMatches(in: lower, range: NSRange(lower.startIndex..., in: lower))
            if c > 0 {
                totals[h, default: 0] += c
                n += c
            }
        }
        return n
    }

    static let commitmentPattern = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[.!?]\s)|(?<=,\s)|(?<=\band\s))((?:I'll|I will|I'm going to|I am going to|I can send|We'll|We will|Let me)\b[^.!?]{4,140}[.!?]?)"#,
        options: [.caseInsensitive])

    /// Sentences where someone commits to doing something ("I'll send the deck tomorrow.").
    public static func commitments(in text: String) -> [String] {
        let ns = text as NSString
        return commitmentPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
    }

    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return String(h, radix: 36)
    }
}
