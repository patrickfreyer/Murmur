import Foundation
import Testing
@testable import UndersayCore

@Suite struct CoachTests {
    func meeting(_ lines: [(String, Double, Double, String)], daysAgo: Double = 1) -> (Meeting, VoicePrint) {
        let me = VoicePrint(name: "Alex", centroid: [1, 0], isMe: true)
        let speakers = [
            Speaker(id: "mic:S1", track: .mic, name: "Alex", voicePrintID: me.id, isConfirmed: true, embedding: [], talkTime: 0, colorIndex: 0),
            Speaker(id: "system:S1", track: .system, name: "Dana", embedding: [], talkTime: 0, colorIndex: 1),
        ]
        let segs = lines.map { TranscriptSegment(speakerID: $0.3, start: $0.1, end: $0.2, text: $0.0) }
        return (Meeting(title: "Sync", createdAt: Date().addingTimeInterval(-daysAgo * 86_400), duration: 60,
                        status: .ready, speakers: speakers, segments: segs), me)
    }

    @Test func countsTalkShareQuestionsCutInsAndCommitments() {
        let (m, me) = meeting([
            ("I think we should just ship it Thursday. I'll send the release notes tonight.", 0, 30, "mic:S1"),
            ("Okay, sounds good to me, and I will update the website.", 30, 40, "system:S1"),
            ("What do you need from me?", 35, 38, "mic:S1"),
        ])
        let r = Coach.report(meetings: [m], dictations: [], voices: [me], meName: "Alex")
        let s = r.meetings[0]
        #expect(s.questions == 1)
        #expect(s.cutIns == 1)
        #expect(abs(s.yourTalkShare - 33.0 / 43.0) < 0.01)
        #expect(r.commitments.map(\.who).sorted() == ["Alex", "Dana"])
        #expect(r.commitments.first { $0.isYou }?.text.hasPrefix("I'll send the release notes") == true)
        #expect(r.hedgeTotals.contains { $0.phrase == "just" })
    }

    @Test func focusPicksTheOutlier() {
        let (m, me) = meeting([("We ship Thursday and the plan is final and the scope is clear and set.", 0, 50, "mic:S1"),
                               ("Okay.", 50, 52, "system:S1")])
        let r = Coach.report(meetings: [m], dictations: [], voices: [me], meName: "Alex")
        #expect([Coach.Focus.leaveRoom, .askMore].contains(r.focus))
    }

    @Test func clearlyNegativeSentencesAreFlagged() {
        let d = Dictation(text: "That's wrong, this never works and it's a complete waste of time. Thanks for the update.",
                          duration: 5, appName: "Slack", processingTime: 0.1)
        let r = Coach.report(meetings: [], dictations: [d], voices: [], meName: "Alex")
        #expect(r.toneMoments.count == 1)
        #expect(r.toneMoments.first?.text.hasPrefix("That's wrong") == true)
    }

    @Test func noMeetingsAsksForData() {
        #expect(Coach.report(meetings: [], dictations: [], voices: [], meName: "Alex").focus == .needData)
    }
}
