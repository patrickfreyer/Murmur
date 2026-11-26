import Foundation

/// One diarized turn on one track.
public struct SpeakerTurn: Sendable, Hashable {
    public var speakerID: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

/// Turns timed words + diarization turns into readable, speaker-attributed paragraphs.
public enum TranscriptAssembler {
    /// Assigns each word to the turn that overlaps it most (or the nearest turn if none overlaps).
    public static func assignSpeakers(words: [Word], turns: [SpeakerTurn], fallback: String) -> [String] {
        let sorted = turns.sorted { $0.start < $1.start }
        return words.map { word in
            var best: (id: String, overlap: Double)?
            var nearest: (id: String, distance: Double)?
            for turn in sorted {
                if turn.start > word.end + 5 { break }
                let overlap = min(word.end, turn.end) - max(word.start, turn.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (turn.speakerID, overlap) }
                let distance = overlap > 0 ? 0 : min(abs(word.start - turn.end), abs(turn.start - word.end))
                if distance < (nearest?.distance ?? .infinity) { nearest = (turn.speakerID, distance) }
            }
            return best?.id ?? (nearest.flatMap { $0.distance < 3 ? $0.id : nil } ?? fallback)
        }
    }

    /// Groups consecutive words from the same speaker into segments.
    public static func segments(
        words: [Word], speakerIDs: [String], maxGap: TimeInterval = 1.6, maxLength: TimeInterval = 45
    ) -> [TranscriptSegment] {
        precondition(words.count == speakerIDs.count)
        let order = words.indices.sorted { words[$0].start < words[$1].start }
        var result: [TranscriptSegment] = []
        var current: (speaker: String, start: Double, end: Double, words: [String])?

        func flush() {
            guard let c = current, !c.words.isEmpty else { return }
            result.append(
                TranscriptSegment(speakerID: c.speaker, start: c.start, end: c.end, text: join(c.words)))
            current = nil
        }

        for i in order {
            let w = words[i]
            let sp = speakerIDs[i]
            if var c = current, c.speaker == sp, w.start - c.end <= maxGap,
                !(w.start - c.start > maxLength && endsSentence(c.words.last))
            {
                c.words.append(w.text)
                c.end = max(c.end, w.end)
                current = c
            } else {
                flush()
                current = (sp, w.start, w.end, [w.text])
            }
        }
        flush()
        return result
    }

    /// When the same audio reaches both tracks (laptop speakers + mic without echo cancellation),
    /// drop mic words that duplicate system words at the same moment.
    public static func removeEcho(_ words: [Word]) -> [Word] {
        let system = words.filter { $0.track == .system }
        guard !system.isEmpty else { return words }
        var index: [String: [Word]] = [:]
        for w in system { index[normalize(w.text), default: []].append(w) }
        return words.filter { w in
            guard w.track == .mic, let candidates = index[normalize(w.text)] else { return true }
            return !candidates.contains { abs($0.start - w.start) < 0.6 }
        }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    static func endsSentence(_ word: String?) -> Bool {
        guard let last = word?.last else { return false }
        return ".!?".contains(last)
    }

    static func join(_ words: [String]) -> String {
        var text = TextCleanup.tidy(words.joined(separator: " "))
        if let first = text.first, first.isLowercase { text = first.uppercased() + text.dropFirst() }
        return text
    }

    /// Speaking time per speaker, from the assembled segments.
    public static func talkTime(_ segments: [TranscriptSegment]) -> [String: TimeInterval] {
        segments.reduce(into: [:]) { $0[$1.speakerID, default: 0] += $1.end - $1.start }
    }
}
