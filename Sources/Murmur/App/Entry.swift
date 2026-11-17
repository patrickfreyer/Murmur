import AppKit
import Foundation
import MurmurCore

/// Launches the UI, or runs a headless check of the speech pipeline:
///   Murmur --transcribe <audio-file>
///   Murmur --selftest <meetingA-dir> <meetingB-dir>   (each holds mic.caf + system.caf)
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--transcribe" {
            run { try await SelfTest.transcribe(URL(fileURLWithPath: args[2])) }
        } else if args.count >= 4, args[1] == "--selftest" {
            run { try await SelfTest.meetings(URL(fileURLWithPath: args[2]), URL(fileURLWithPath: args[3])) }
        } else {
            MurmurApp.main()
        }
    }

    private static func run(_ body: @escaping @MainActor () async throws -> Bool) {
        Task { @MainActor in
            do {
                let ok = try await body()
                exit(ok ? 0 : 1)
            } catch {
                print("ERROR: \(error.localizedDescription)")
                exit(2)
            }
        }
        dispatchMain()
    }
}

@MainActor
enum SelfTest {
    static func transcribe(_ url: URL) async throws -> Bool {
        let t0 = Date()
        try await SpeechEngine.shared.prepareASR(.ultra)
        print("model ready in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        let t1 = Date()
        let words = try await SpeechEngine.shared.transcribeFile(url, track: .mic)
        print("transcribed in \(String(format: "%.2f", Date().timeIntervalSince(t1))) s:")
        print(words.map(\.text).joined(separator: " "))
        return !words.isEmpty
    }

    static func meetings(_ a: URL, _ b: URL) async throws -> Bool {
        print("Library: \(Paths.root.path)")
        let store = MeetingStore()
        let voices = VoicePrintStore()
        let matcher = VoiceMatcher()

        let idA = try importMeeting(a, title: "Fixture A", store: store)
        let t0 = Date()
        await MeetingProcessor.process(idA, store: store, voices: voices, matcher: matcher, model: .ultra, meName: "Patrick")
        guard let mA = store.meeting(idA), mA.status == .ready else {
            print("FAIL: meeting A status \(String(describing: store.meeting(idA)?.status)) \(store.meeting(idA)?.statusDetail ?? "")")
            return false
        }
        print("\n== Meeting A processed in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s ==")
        dump(mA)

        // Name speakers the way a user would, by what they said.
        for s in mA.speakers {
            let text = mA.segments.filter { $0.speakerID == s.id }.map(\.text).joined(separator: " ").lowercased()
            let name: String? =
                s.track == .mic ? "Patrick"
                : text.contains("beta build") || text.contains("server migration") ? "Daniel"
                : text.contains("design") || text.contains("icons") ? "Karen" : nil
            if let name {
                SpeakerNaming.assign(name: name, to: s.id, in: idA, store: store, voices: voices, matcher: matcher,
                                     isMe: name == "Patrick")
            }
        }
        print("\nVoice prints: \(voices.prints.map { "\($0.name)(\($0.sampleCount))" }.joined(separator: ", "))")

        let idB = try importMeeting(b, title: "Fixture B", store: store)
        await MeetingProcessor.process(idB, store: store, voices: voices, matcher: matcher, model: .ultra, meName: "Patrick")
        guard let mB = store.meeting(idB), mB.status == .ready else { print("FAIL: meeting B"); return false }
        print("\n== Meeting B (auto-labelled from voice prints) ==")
        dump(mB)

        // Expectations: every line is attributed to the right person in meeting B.
        let expected: [(String, String)] = [
            ("migration finished", "Daniel"), ("still on track", "Patrick"), ("icons are in the build", "Karen"),
            ("invitation emails", "Daniel"), ("first feedback", "Patrick"),
        ]
        var failures = 0
        for (phrase, who) in expected {
            let seg = mB.segments.first { $0.text.lowercased().contains(phrase) }
            let got = seg.flatMap { mB.speaker($0.speakerID)?.name }
            let ok = got == who
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  “\(phrase)” → \(got ?? "nil") (expected \(who))")
        }
        return failures == 0
    }

    private static func importMeeting(_ dir: URL, title: String, store: MeetingStore) throws -> UUID {
        let m = Meeting(title: title, status: .processing)
        try FileManager.default.createDirectory(at: Paths.meetingFolder(m.id), withIntermediateDirectories: true)
        for t in AudioTrack.allCases {
            let src = dir.appending(path: "\(t.rawValue).caf")
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: Paths.track(t, meeting: m.id))
            }
        }
        store.save(m)
        return m.id
    }

    private static func dump(_ m: Meeting) {
        for s in m.speakers {
            print("  speaker \(s.id) → \(s.name ?? "-") match=\(s.matchScore.map { String(format: "%.2f", $0) } ?? "-") talk=\(String(format: "%.1f", s.talkTime))s emb=\(s.embedding.count)")
        }
        for seg in m.segments {
            print("  [\(Meeting.timestamp(seg.start))] \(m.speaker(seg.speakerID)?.displayName ?? "?"): \(seg.text)")
        }
    }
}
