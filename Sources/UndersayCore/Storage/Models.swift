import Foundation

public enum AudioTrack: String, Codable, Sendable, CaseIterable {
    /// The local microphone: you, plus anyone in the room.
    case mic
    /// Everything played by the Mac: remote call participants.
    case system
}

public struct Word: Codable, Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var track: AudioTrack

    public init(text: String, start: TimeInterval, end: TimeInterval, track: AudioTrack) {
        self.text = text
        self.start = start
        self.end = end
        self.track = track
    }
}

public struct TranscriptSegment: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var speakerID: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(id: UUID = UUID(), speakerID: String, start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Speaker: Codable, Sendable, Identifiable, Hashable {
    /// Stable within a meeting, e.g. "mic:S1" or "system:S2".
    public var id: String
    public var track: AudioTrack
    /// Display name. nil = still anonymous ("Speaker 2").
    public var name: String?
    public var voicePrintID: UUID?
    /// Cosine similarity of the automatic voice-print match (nil if assigned by hand).
    public var matchScore: Float?
    /// true once the user named or confirmed this speaker.
    public var isConfirmed: Bool
    public var embedding: [Float]
    public var talkTime: TimeInterval
    public var colorIndex: Int

    public init(
        id: String, track: AudioTrack, name: String? = nil, voicePrintID: UUID? = nil, matchScore: Float? = nil,
        isConfirmed: Bool = false, embedding: [Float], talkTime: TimeInterval, colorIndex: Int
    ) {
        self.id = id
        self.track = track
        self.name = name
        self.voicePrintID = voicePrintID
        self.matchScore = matchScore
        self.isConfirmed = isConfirmed
        self.embedding = embedding
        self.talkTime = talkTime
        self.colorIndex = colorIndex
    }

    public var fallbackName: String {
        let number = id.split(separator: "S").last.map(String.init) ?? "?"
        return track == .mic ? "Room \(number)" : "Speaker \(number)"
    }

    public var displayName: String { name ?? fallbackName }
}

public enum MeetingStatus: String, Codable, Sendable {
    case recording, processing, ready, failed
}

public struct Meeting: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var duration: TimeInterval
    public var status: MeetingStatus
    public var statusDetail: String?
    public var speakers: [Speaker]
    public var segments: [TranscriptSegment]
    public var summary: String?
    public var sourceApp: String?

    public init(
        id: UUID = UUID(), title: String, createdAt: Date = .now, duration: TimeInterval = 0,
        status: MeetingStatus = .recording, statusDetail: String? = nil, speakers: [Speaker] = [],
        segments: [TranscriptSegment] = [], summary: String? = nil, sourceApp: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.status = status
        self.statusDetail = statusDetail
        self.speakers = speakers
        self.segments = segments
        self.summary = summary
        self.sourceApp = sourceApp
    }

    public func speaker(_ id: String) -> Speaker? { speakers.first { $0.id == id } }

    public var plainText: String {
        segments.map { seg in
            let name = speaker(seg.speakerID)?.displayName ?? "Unknown"
            return "[\(Self.timestamp(seg.start))] \(name): \(seg.text)"
        }.joined(separator: "\n\n")
    }

    public var markdown: String {
        var out = "# \(title)\n\n"
        out += "_\(createdAt.formatted(date: .long, time: .shortened)) · \(Self.timestamp(duration))_\n\n"
        if let summary, !summary.isEmpty { out += "## Summary\n\n\(summary)\n\n## Transcript\n\n" }
        for seg in segments {
            let name = speaker(seg.speakerID)?.displayName ?? "Unknown"
            out += "**\(name)** `\(Self.timestamp(seg.start))`  \n\(seg.text)\n\n"
        }
        return out
    }

    public var srt: String {
        segments.enumerated().map { i, seg in
            let name = speaker(seg.speakerID)?.displayName ?? "Unknown"
            return "\(i + 1)\n\(Self.srtTime(seg.start)) --> \(Self.srtTime(seg.end))\n\(name): \(seg.text)\n"
        }.joined(separator: "\n")
    }

    public static func timestamp(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func srtTime(_ t: TimeInterval) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

public struct Dictation: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var text: String
    public var createdAt: Date
    public var duration: TimeInterval
    public var appName: String?
    /// Bundle identifier of the app the text went into (for its icon). nil on older entries.
    public var appBundleID: String?
    public var processingTime: TimeInterval

    public init(
        id: UUID = UUID(), text: String, createdAt: Date = .now, duration: TimeInterval, appName: String?,
        appBundleID: String? = nil, processingTime: TimeInterval
    ) {
        self.appBundleID = appBundleID
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.duration = duration
        self.appName = appName
        self.processingTime = processingTime
    }
}
