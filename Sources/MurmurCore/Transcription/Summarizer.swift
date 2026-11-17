import Foundation
import FoundationModels

/// Meeting summaries with Apple's on-device foundation model. Nothing leaves the Mac.
public enum Summarizer {
    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence to get summaries."
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading."
        case .unavailable(.deviceNotEligible): "This Mac doesn't support Apple Intelligence."
        case .unavailable: "Apple Intelligence is unavailable."
        }
    }

    @Generable
    public struct MeetingNotes {
        @Guide(description: "A short, specific title for the meeting, at most 6 words")
        public var title: String
        @Guide(description: "Two or three sentence overview of what was discussed")
        public var overview: String
        @Guide(description: "Key points or decisions, each one short sentence")
        public var keyPoints: [String]
        @Guide(description: "Action items as 'Owner: task' when an owner is clear, else just the task")
        public var actionItems: [String]
    }

    public static func summarize(_ meeting: Meeting) async throws -> (title: String, markdown: String) {
        let lines = meeting.segments.map { seg in
            "\(meeting.speaker(seg.speakerID)?.displayName ?? "Unknown"): \(seg.text)"
        }
        // The on-device model has a small context window: condense long meetings chunk by chunk.
        let chunks = chunk(lines, maxCharacters: 7_000)
        var condensed = lines.joined(separator: "\n")
        if chunks.count > 1 {
            var partials: [String] = []
            for c in chunks {
                let session = LanguageModelSession(
                    instructions: "Condense this part of a meeting transcript into dense bullet notes. Keep names, numbers, decisions and commitments.")
                partials.append(try await session.respond(to: c).content)
            }
            condensed = partials.joined(separator: "\n")
            if condensed.count > 9_000 { condensed = String(condensed.prefix(9_000)) }
        }

        let session = LanguageModelSession(
            instructions: "You write crisp meeting notes from transcripts. Be factual; never invent details.")
        let notes = try await session.respond(
            to: "Meeting transcript:\n\(condensed)", generating: MeetingNotes.self
        ).content

        var md = notes.overview + "\n"
        if !notes.keyPoints.isEmpty {
            md += "\n**Key points**\n" + notes.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !notes.actionItems.isEmpty {
            md += "\n**Action items**\n" + notes.actionItems.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n"
        }
        return (notes.title, md)
    }

    static func chunk(_ lines: [String], maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in lines {
            if current.count + line.count > maxCharacters, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
