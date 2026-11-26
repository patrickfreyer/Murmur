import Foundation
import Testing
@testable import UndersayCore

@Suite struct AutomationTests {
    func meeting(named: [String?]) -> Meeting {
        let speakers = named.enumerated().map { i, n in
            Speaker(id: "system:S\(i + 1)", track: .system, name: n, isConfirmed: n != nil, embedding: [], talkTime: 10, colorIndex: i)
        }
        let segs = speakers.map { TranscriptSegment(speakerID: $0.id, start: 0, end: 10, text: "Hello there.") }
        return Meeting(title: "Sync", status: .ready, speakers: speakers, segments: segs)
    }

    @Test func exportMarksConfidenceAndUnnamedSpeakers() {
        var m = meeting(named: ["Ann", "Ben", nil])
        m.speakers[1].isConfirmed = false
        let md = TranscriptExport.markdown(m, meName: "Alex", myVoicePrint: nil)
        #expect(md.contains("Ann (named by the user)"))
        #expect(md.contains("Ben (recognised by voice, not confirmed"))
        #expect(md.contains("(unidentified)"))
        #expect(md.contains("[0:00] Ann: Hello there."))
    }

    @Test func automationRoundTrips() throws {
        var a = Automation(name: "Notes", agent: .codex, folder: URL(fileURLWithPath: "/tmp/vault"), prompt: "Do it")
        a.allowShell = true
        let back = try JSONDecoder().decode(Automation.self, from: JSONEncoder().encode(a))
        #expect(back == a)
    }

    @Test func promptFramesTaskAndFillsPlaceholders() {
        let p = AutomationPrompt.build("Save {title} notes for {date}.", transcript: "/tmp/t.md", meeting: meeting(named: [nil]))
        #expect(p.contains("Transcript file: /tmp/t.md"))
        #expect(p.contains("Save Sync notes for"))
        #expect(p.contains("Speakers may be unnamed"))
        #expect(p.contains("short plain-text summary"))
    }

    @Test func olderMeetingFilesStillDecode() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting(named: ["Ann"]))) as! [String: Any]
        json["knowledge"] = ["status": "done"]
        let back = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.automationRuns == nil && back.title == "Sync")
    }

    @Test func firstJSONObjectSkipsWarnings() {
        let raw = Data("Warning: something\n{\"result\":\"ok\"}\n".utf8)
        #expect(Shell.firstJSONObject(raw).flatMap { String(data: $0, encoding: .utf8) } == "{\"result\":\"ok\"}")
    }
}
