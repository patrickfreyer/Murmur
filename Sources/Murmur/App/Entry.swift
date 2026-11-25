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
        } else if args.count >= 4, args[1] == "--make-demo" {
            run { try await SelfTest.makeDemo(URL(fileURLWithPath: args[2]), URL(fileURLWithPath: args[3])) }
        } else if args.count >= 2, args[1] == "--capture-test" {
            run { try await SelfTest.capture(seconds: Double(args.dropFirst(2).first ?? "") ?? 6) }
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

    /// Builds a demo library (fictional people, real transcriptions) for README screenshots.
    static func makeDemo(_ a: URL, _ b: URL) async throws -> Bool {
        let store = MeetingStore()
        let voices = VoicePrintStore()
        let matcher = VoiceMatcher()
        let me = "Alex Rivera"
        let idA = try importMeeting(a, title: "Weekly product sync", store: store)
        await MeetingProcessor.process(idA, store: store, voices: voices, matcher: matcher, model: .ultra, meName: me)
        guard let mA = store.meeting(idA) else { return false }
        for s in mA.speakers {
            let text = mA.segments.filter { $0.speakerID == s.id }.map(\.text).joined(separator: " ").lowercased()
            let name = s.track == .mic ? me : text.contains("beta build") ? "Daniel Brooks" : "Karen Lee"
            SpeakerNaming.assign(name: name, to: s.id, in: idA, store: store, voices: voices, matcher: matcher,
                                 isMe: name == me)
        }
        let idB = try importMeeting(b, title: "Beta launch follow-up", store: store)
        await MeetingProcessor.process(idB, store: store, voices: voices, matcher: matcher, model: .ultra, meName: me)
        let hour: TimeInterval = 3600
        store.update(idA) {
            $0.createdAt = Date.now.addingTimeInterval(-26 * hour)
            $0.summary = """
                The team reviewed the launch timeline: the beta build is ready to go to testers on Thursday and the onboarding screens are finished.

                **Key points**
                - Final icons are the last open design item
                - A slipping server migration would push the beta to Monday

                **Action items**
                - [ ] Karen Lee: send the final icons to Daniel by Wednesday
                - [ ] Alex Rivera: decide on the beta date on Wednesday
                """
        }
        store.update(idB) {
            $0.createdAt = Date.now.addingTimeInterval(-2 * hour)
            $0.summary = """
                The server migration finished without problems, so the beta stays on track for Thursday with the new icons in the build.

                **Action items**
                - [ ] Daniel Brooks: send tester invitations tomorrow morning
                - [ ] Alex Rivera: schedule a follow-up after first feedback
                """
        }
        let dictations = DictationStore()
        dictations.clear()
        let samples: [(Double, String, String, String, Double, Double)] = [
            (60 * 27, "Draft: the new onboarding flow cuts setup time from ten minutes to under two, mostly because permissions are requested in context.", "Safari", "com.apple.Safari", 9.4, 0.156),
            (60 * 95, "Sounds good, see you at three.", "Messages", "com.apple.MobileSMS", 1.9, 0.092),
            (60 * 37, "Remember to book the flights to Munich for the workshop and check whether the hotel near the office has availability.", "Notes", "com.apple.Notes", 6.8, 0.131),
            (60 * 4, "Can you send me the updated deck before the call tomorrow? I want to review the pricing section once more.", "Mail", "com.apple.mail", 5.2, 0.118),
        ]
        for (ago, text, app, bundle, dur, ms) in samples {
            dictations.add(Dictation(text: text, createdAt: Date.now.addingTimeInterval(-ago), duration: dur,
                                     appName: app, appBundleID: bundle, processingTime: ms))
        }
        print("Demo library at \(Paths.root.path)")
        return true
    }

    /// Records mic + system audio for a few seconds and transcribes both tracks.
    static func capture(seconds: Double) async throws -> Bool {
        let store = MeetingStore()
        let recorder = MeetingRecorder()
        try await SpeechEngine.shared.prepareASR(.ultra)
        await recorder.start(store: store, echoCancellation: ProcessInfo.processInfo.environment["AEC"] == "1", captureSystemAudio: true)
        guard let id = recorder.meetingID else {
            print("FAIL: could not start: \(recorder.lastError ?? "?")")
            return false
        }
        print("recording… system audio error: \(recorder.systemAudioError ?? "none")")
        var peakMic: Float = 0, peakSys: Float = 0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(100))
            peakMic = max(peakMic, recorder.micLevel)
            peakSys = max(peakSys, recorder.systemLevel)
        }
        print("live lines: \(recorder.liveLines.map { "[\($0.track.rawValue)] \($0.text)" })")
        await recorder.stop(store: store, voices: VoicePrintStore(), matcher: VoiceMatcher(), model: .ultra, meName: "Me")
        let m = store.meeting(id)!
        print("peak meter mic=\(peakMic) system=\(peakSys)")
        for t in AudioTrack.allCases {
            print("\(t.rawValue).caf duration: \(AudioFileInfo.duration(Paths.track(t, meeting: id)))")
        }
        print("status: \(m.status) \(m.statusDetail ?? "")")
        dump(m)
        return m.status == .ready
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
