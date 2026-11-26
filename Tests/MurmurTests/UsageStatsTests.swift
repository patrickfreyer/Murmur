import Foundation
import Testing
@testable import MurmurCore

@Suite struct UsageStatsTests {
    @Test func computesDictationNumbers() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        let ds = [
            Dictation(text: "Ship the beta beta today", createdAt: now, duration: 3, appName: "Mail", processingTime: 0.1),
            Dictation(text: "Beta looks great", createdAt: now - day, duration: 2, appName: "Mail", processingTime: 0.08),
            Dictation(text: "Lunch at noon", createdAt: now - 2 * day, duration: 1, appName: "Slack", processingTime: 0.12),
        ]
        let s = UsageStats.compute(dictations: ds, meetings: [], voices: [], now: now)
        #expect(s.words == 11)
        #expect(s.dictations == 3)
        #expect(s.medianLatency == 0.1)
        #expect(s.topApps.first?.name == "Mail")
        #expect(s.favoriteWord?.word == "beta")
        #expect(s.streakDays == 3)
        #expect(abs((s.realtimeFactor ?? 0) - 6 / 0.3) < 0.01)
        #expect(s.heatmap.flatMap { $0 }.reduce(0, +) == 3)
    }

    @Test func talkShareUsesYourVoicePrint() {
        let me = VoicePrint(name: "Me", centroid: [1, 0], isMe: true)
        let m = Meeting(title: "T", status: .ready, speakers: [
            Speaker(id: "mic:S1", track: .mic, name: "Me", voicePrintID: me.id, isConfirmed: true, embedding: [], talkTime: 30, colorIndex: 0),
            Speaker(id: "system:S1", track: .system, name: "Ann", embedding: [], talkTime: 90, colorIndex: 1),
        ])
        let s = UsageStats.compute(dictations: [], meetings: [m], voices: [me])
        #expect(s.yourTalkShare == 0.25)
        #expect(s.people.map(\.name) == ["Ann"])
    }
}
