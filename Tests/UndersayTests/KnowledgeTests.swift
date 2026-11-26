import Foundation
import Testing
@testable import UndersayCore

@Suite struct KnowledgeTests {
    func meeting(named: [String?]) -> Meeting {
        let speakers = named.enumerated().map { i, n in
            Speaker(id: "system:S\(i + 1)", track: .system, name: n, isConfirmed: n != nil, embedding: [], talkTime: 10, colorIndex: i)
        }
        let segs = speakers.map { TranscriptSegment(speakerID: $0.id, start: 0, end: 10, text: "Hello there.") }
        return Meeting(title: "Sync", status: .ready, speakers: speakers, segments: segs)
    }

    @Test func waitsUntilSpeakersAreNamed() {
        #expect(!TranscriptExport.speakersNamed(meeting(named: ["Ann", nil])))
        #expect(TranscriptExport.speakersNamed(meeting(named: ["Ann", "Ben"])))
    }

    @Test func exportMarksConfidence() {
        var m = meeting(named: ["Ann", "Ben"])
        m.speakers[1].isConfirmed = false
        let md = TranscriptExport.markdown(m, meName: "Alex", myVoicePrint: nil)
        #expect(md.contains("Ann (named by the user)"))
        #expect(md.contains("Ben (recognised by voice, not confirmed"))
        #expect(md.contains("[0:00] Ann: Hello there."))
    }

    @Test func settingsRoundTripAndDecodeFromPlainJSON() throws {
        let json = #"{"folder":"file:///tmp/kb/","autoSync":true,"commitAndPush":false,"model":"haiku","allowedCommands":[],"instructions":"x","revertPatterns":[]}"#
        let s = try JSONDecoder().decode(KnowledgeSettings.self, from: Data(json.utf8))
        #expect(s.folder?.path == "/tmp/kb")
        #expect(s.autoSync && s.model == "haiku")
    }

    @Test func promptMentionsArchiveOnlyWhenSet() {
        var k = KnowledgeSettings()
        let a = KnowledgePrompt.build(transcriptPath: "/t.md", archiveFolder: nil, settings: k, date: "2026-11-25")
        #expect(!a.contains("cleaned, readable copy"))
        k.instructions = "Use people/ folder."
        let b = KnowledgePrompt.build(transcriptPath: "/t.md", archiveFolder: "/arch", settings: k, date: "2026-11-25")
        #expect(b.contains("/arch/") && b.contains("Use people/ folder."))
    }

    @Test func firstJSONObjectSkipsWarnings() {
        let raw = Data("Warning: something\n{\"result\":\"ok\"}\n".utf8)
        #expect(Shell.firstJSONObject(raw).flatMap { String(data: $0, encoding: .utf8) } == "{\"result\":\"ok\"}")
    }
}
