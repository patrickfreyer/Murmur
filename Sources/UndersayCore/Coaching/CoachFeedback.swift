import Foundation
import FoundationModels

/// Qualitative feedback on one meeting from Apple's on-device model. Only runs when asked, and the
/// result is stored with the meeting so it never runs twice for the same meeting.
public enum CoachFeedback {
    @Generable
    struct Notes {
        @Guide(description: "Two or three specific things the person did well, one short sentence each")
        var strengths: [String]
        @Guide(description: "Two or three specific improvements, each tied to an exact quote of the person's own words")
        var improvements: [Item]
    }

    @Generable
    struct Item {
        @Guide(description: "The person's exact words, copied verbatim from a line marked YOU, at most 20 words")
        var quote: String
        @Guide(description: "A clearer, kinder or more direct way to say it, in the same language")
        var better: String
        @Guide(description: "Why this works better, in at most 15 words")
        var why: String
    }

    public static func generate(for meeting: Meeting, youAre speakerIDs: Set<String>) async throws -> CoachingNotes {
        // Your lines in full, others' lines shortened: enough context, small prompt.
        var lines: [String] = []
        var budget = 7_000
        for seg in meeting.segments {
            let mine = speakerIDs.contains(seg.speakerID)
            let who = mine ? "YOU" : (meeting.speaker(seg.speakerID)?.displayName ?? "Other")
            let text = mine ? seg.text : String(seg.text.prefix(160))
            let line = "\(who): \(text)"
            budget -= line.count
            if budget < 0 { break }
            lines.append(line)
        }
        let session = LanguageModelSession(instructions: """
            You are a warm, practical communication coach. Read a meeting transcript and give feedback \
            only on the lines marked YOU. Look at clarity, directness, listening, questions, tone and \
            word choice. Be specific and encouraging. Never invent quotes: copy them exactly.
            """)
        let notes = try await session.respond(to: lines.joined(separator: "\n"), generating: Notes.self).content
        let yourText = meeting.segments.filter { speakerIDs.contains($0.speakerID) }.map(\.text).joined(separator: " ")
        // Keep only improvements whose quote really appears in what you said.
        let verified = notes.improvements.filter { item in
            let q = item.quote.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'. "))
            return q.count > 3 && yourText.localizedCaseInsensitiveContains(q)
        }
        return CoachingNotes(
            strengths: Array(notes.strengths.prefix(3)),
            improvements: verified.prefix(3).map { .init(quote: $0.quote, better: $0.better, why: $0.why) })
    }
}
