import Foundation

/// A remembered voice: a running centroid of WeSpeaker embeddings, stored only on this Mac.
public struct VoicePrint: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var centroid: [Float]
    /// How many confirmed samples went into the centroid.
    public var sampleCount: Int
    public var isMe: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var colorIndex: Int

    public init(
        id: UUID = UUID(), name: String, centroid: [Float], sampleCount: Int = 1, isMe: Bool = false,
        createdAt: Date = .now, updatedAt: Date = .now, colorIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.centroid = AudioMath.normalized(centroid)
        self.sampleCount = sampleCount
        self.isMe = isMe
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.colorIndex = colorIndex
    }

    /// Folds a new sample into the centroid. Weight is capped so the print keeps adapting
    /// (microphones and rooms change) instead of freezing after the first meetings.
    public mutating func absorb(_ embedding: [Float], weight: Float = 1) {
        let e = AudioMath.normalized(embedding)
        guard e.count == centroid.count else {
            centroid = e
            sampleCount = 1
            updatedAt = .now
            return
        }
        let n = Float(min(sampleCount, 24))
        centroid = AudioMath.normalized(zip(centroid, e).map { ($0 * n + $1 * weight) / (n + weight) })
        sampleCount += 1
        updatedAt = .now
    }
}

public struct VoiceMatch: Sendable, Equatable {
    public var print: VoicePrint
    public var score: Float
}

public struct VoiceMatcher: Sendable {
    /// Cosine similarity needed to auto-label a speaker.
    public var threshold: Float
    /// Required lead over the runner-up, so two similar voices don't get confused.
    public var margin: Float

    public init(threshold: Float = 0.6, margin: Float = 0.06) {
        self.threshold = threshold
        self.margin = margin
    }

    public func bestMatch(for embedding: [Float], in prints: [VoicePrint]) -> VoiceMatch? {
        guard !embedding.isEmpty else { return nil }
        let scored = prints.map { ($0, AudioMath.cosine(embedding, $0.centroid)) }.sorted { $0.1 > $1.1 }
        guard let top = scored.first, top.1 >= threshold else { return nil }
        if scored.count > 1, top.1 - scored[1].1 < margin, scored[1].0.name != top.0.name { return nil }
        return VoiceMatch(print: top.0, score: top.1)
    }

    /// Labels speakers of one meeting. Each voice print is used at most once per track (two people
    /// on the same track can't both be "Anna"); higher scores win.
    public func label(_ speakers: [Speaker], with prints: [VoicePrint]) -> [Speaker] {
        var result = speakers
        var candidates: [(index: Int, match: VoiceMatch)] = []
        for (i, s) in speakers.enumerated() where !s.isConfirmed {
            result[i].name = nil
            result[i].voicePrintID = nil
            result[i].matchScore = nil
            if let m = bestMatch(for: s.embedding, in: prints) { candidates.append((i, m)) }
        }
        var used = Set<String>()
        for (i, s) in speakers.enumerated() where s.isConfirmed {
            if let id = s.voicePrintID { used.insert("\(s.track.rawValue):\(id)") }
        }
        for c in candidates.sorted(by: { $0.match.score > $1.match.score }) {
            let key = "\(speakers[c.index].track.rawValue):\(c.match.print.id)"
            guard !used.contains(key) else { continue }
            used.insert(key)
            result[c.index].name = c.match.print.name
            result[c.index].voicePrintID = c.match.print.id
            result[c.index].matchScore = c.match.score
        }
        return result
    }
}
