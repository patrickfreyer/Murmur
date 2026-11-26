import Foundation

/// Numbers for the Statistics page, computed from the local library. Pure, so it's testable.
public struct UsageStats: Sendable {
    public struct AppUsage: Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var bundleID: String?
        public var count: Int
        public var words: Int
    }

    public struct PersonUsage: Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var colorIndex: Int
        public var meetings: Int
        public var talkTime: TimeInterval
    }

    // Dictation
    public var dictations = 0
    public var words = 0
    public var audioSeconds: TimeInterval = 0
    public var latencies: [TimeInterval] = []
    public var medianLatency: TimeInterval?
    public var p95Latency: TimeInterval?
    public var fastest: (latency: TimeInterval, audio: TimeInterval)?
    /// Seconds of audio transcribed per second of compute.
    public var realtimeFactor: Double?
    /// Speaking pace while dictating.
    public var wordsPerMinute: Double?
    /// Time saved versus typing at `typingWPM`.
    public var timeSaved: TimeInterval = 0
    public static let typingWPM: Double = 40
    public var longest: Dictation?
    public var busiestDay: (date: Date, count: Int)?
    public var favoriteWord: (word: String, count: Int)?
    public var streakDays = 0
    /// [weekday 0 = Monday][hour 0…23] → dictations
    public var heatmap: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    public var topApps: [AppUsage] = []

    // Meetings
    public var meetings = 0
    public var meetingSeconds: TimeInterval = 0
    public var speakersIdentified = 0
    public var yourTalkShare: Double?
    public var people: [PersonUsage] = []

    public init() {}

    static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "at", "by", "with", "from", "is", "are",
        "was", "were", "be", "been", "it", "its", "this", "that", "these", "those", "i", "you", "we", "they", "he",
        "she", "me", "my", "your", "our", "their", "so", "if", "as", "can", "could", "would", "should", "will", "do",
        "does", "did", "have", "has", "had", "not", "no", "yes", "just", "also", "about", "there", "here", "what",
        "when", "then", "than", "all", "any", "some", "more", "very", "into", "out", "up", "down", "over", "let's",
        "i'm", "it's", "don't", "that's", "we're", "you're", "der", "die", "das", "und", "ist", "ich", "wir", "sie",
        "es", "ein", "eine", "zu", "mit", "auf", "für", "nicht", "den", "dem", "des", "im", "am", "auch", "noch",
    ]

    public static func compute(
        dictations ds: [Dictation], meetings ms: [Meeting], voices: [VoicePrint], calendar: Calendar = .current,
        now: Date = .now
    ) -> UsageStats {
        var s = UsageStats()
        s.dictations = ds.count
        s.words = ds.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        s.audioSeconds = ds.reduce(0) { $0 + $1.duration }
        s.latencies = ds.map(\.processingTime).filter { $0 > 0 }
        let sorted = s.latencies.sorted()
        if !sorted.isEmpty {
            s.medianLatency = sorted[sorted.count / 2]
            s.p95Latency = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
        if let f = ds.filter({ $0.processingTime > 0 }).min(by: { $0.processingTime < $1.processingTime }) {
            s.fastest = (f.processingTime, f.duration)
        }
        let compute = s.latencies.reduce(0, +)
        if compute > 0 { s.realtimeFactor = s.audioSeconds / compute }
        if s.audioSeconds > 5 { s.wordsPerMinute = Double(s.words) / (s.audioSeconds / 60) }
        s.timeSaved = max(0, Double(s.words) / typingWPM * 60 - s.audioSeconds - compute)
        s.longest = ds.max { $0.duration < $1.duration }

        var perDay: [Date: Int] = [:]
        var apps: [String: AppUsage] = [:]
        var wordCounts: [String: Int] = [:]
        for d in ds {
            let day = calendar.startOfDay(for: d.createdAt)
            perDay[day, default: 0] += 1
            // Weekday with Monday = 0.
            let wd = (calendar.component(.weekday, from: d.createdAt) + 5) % 7
            let hour = calendar.component(.hour, from: d.createdAt)
            s.heatmap[wd][hour] += 1
            let name = d.appName ?? "Unknown"
            var a = apps[name] ?? AppUsage(name: name, bundleID: d.appBundleID, count: 0, words: 0)
            a.count += 1
            a.words += d.text.split(whereSeparator: \.isWhitespace).count
            if a.bundleID == nil { a.bundleID = d.appBundleID }
            apps[name] = a
            for raw in d.text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
                let w = String(raw)
                guard w.count >= 4, !stopWords.contains(w) else { continue }
                wordCounts[w, default: 0] += 1
            }
        }
        if let busy = perDay.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }) {
            s.busiestDay = (busy.key, busy.value)
        }
        if let fav = wordCounts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }),
            fav.value >= 2
        {
            s.favoriteWord = (fav.key, fav.value)
        }
        s.topApps = apps.values.sorted { $0.count > $1.count || ($0.count == $1.count && $0.name < $1.name) }
        // Current streak: consecutive days up to today (or yesterday) with at least one dictation.
        var day = calendar.startOfDay(for: now)
        if perDay[day] == nil { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        while perDay[day] != nil {
            s.streakDays += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }

        // Meetings
        let ready = ms.filter { $0.status == .ready }
        s.meetings = ready.count
        s.meetingSeconds = ready.reduce(0) { $0 + $1.duration }
        let meID = voices.first(where: \.isMe)?.id
        var mine: TimeInterval = 0, total: TimeInterval = 0
        var people: [String: PersonUsage] = [:]
        for m in ready {
            var seen = Set<String>()
            for sp in m.speakers {
                total += sp.talkTime
                if let meID, sp.voicePrintID == meID { mine += sp.talkTime; continue }
                guard let name = sp.name else { continue }
                s.speakersIdentified += 1
                let color = voices.first { $0.id == sp.voicePrintID }?.colorIndex ?? sp.colorIndex
                var p = people[name] ?? PersonUsage(name: name, colorIndex: color, meetings: 0, talkTime: 0)
                if seen.insert(name).inserted { p.meetings += 1 }
                p.talkTime += sp.talkTime
                people[name] = p
            }
        }
        if total > 0, meID != nil { s.yourTalkShare = mine / total }
        s.people = people.values.sorted { $0.talkTime > $1.talkTime }
        return s
    }
}
