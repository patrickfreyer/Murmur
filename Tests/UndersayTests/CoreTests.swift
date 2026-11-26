import Foundation
import FluidAudio
import Testing
@testable import UndersayCore

@Suite struct TranscriptAssemblyTests {
    func w(_ t: String, _ s: Double, _ e: Double, _ tr: AudioTrack = .system) -> Word {
        Word(text: t, start: s, end: e, track: tr)
    }

    @Test func assignsWordsToOverlappingTurn() {
        let words = [w("hello", 0.1, 0.4), w("there", 0.5, 0.8), w("hi", 2.1, 2.3)]
        let turns = [SpeakerTurn(speakerID: "A", start: 0, end: 1), SpeakerTurn(speakerID: "B", start: 2, end: 3)]
        #expect(TranscriptAssembler.assignSpeakers(words: words, turns: turns, fallback: "X") == ["A", "A", "B"])
    }

    @Test func nearestTurnWhenNoOverlapAndFallbackWhenFar() {
        let words = [w("late", 1.2, 1.4), w("lost", 20, 21)]
        let turns = [SpeakerTurn(speakerID: "A", start: 0, end: 1)]
        #expect(TranscriptAssembler.assignSpeakers(words: words, turns: turns, fallback: "X") == ["A", "X"])
    }

    @Test func groupsBySpeakerAndGap() {
        let words = [w("one", 0, 0.3), w("two.", 0.4, 0.7), w("three", 0.8, 1), w("far", 5, 5.3)]
        let segs = TranscriptAssembler.segments(words: words, speakerIDs: ["A", "A", "B", "B"])
        #expect(segs.map(\.text) == ["One two.", "Three", "Far"])
        #expect(segs.map(\.speakerID) == ["A", "B", "B"])
    }

    @Test func removesMicEchoOfSystemAudio() {
        let words = [w("hello", 1, 1.3, .system), w("hello", 1.2, 1.5, .mic), w("mine", 3, 3.2, .mic)]
        #expect(TranscriptAssembler.removeEcho(words).map(\.track) == [.system, .mic])
    }

    @Test func punctuationDoesNotHidePauses() {
        let tokens = [
            TokenTiming(token: "▁done", tokenId: 1, startTime: 0.0, endTime: 0.4, confidence: 1),
            TokenTiming(token: ".", tokenId: 2, startTime: 1.9, endTime: 2.0, confidence: 1),
            TokenTiming(token: "▁next", tokenId: 3, startTime: 2.0, endTime: 2.3, confidence: 1),
        ]
        let w = WordBuilder.words(from: tokens, offset: 0, track: .mic)
        #expect(w.map(\.text) == ["done.", "next"])
        #expect(w[0].end == 0.35)
    }

    @Test func silenceSnapsWordEnds() {
        // 1 s of tone, 1.5 s of silence, 1 s of tone.
        let tone = (0..<16_000).map { Float(sin(Double($0) * 0.3)) * 0.3 }
        let samples = tone + [Float](repeating: 0, count: 24_000) + tone
        let sil = PauseAligner.silences(in: samples)
        #expect(sil.count == 1)
        let words = [Word(text: "done.", start: 0.5, end: 2.4, track: .mic), Word(text: "next", start: 2.5, end: 2.9, track: .mic)]
        let aligned = PauseAligner.align(words, silences: sil)
        #expect(abs(aligned[0].end - 1.0) < 0.05)
    }

    @Test func tidyPunctuation() {
        #expect(TextCleanup.tidy(" so  we are on track ?. ok ") == "so we are on track? ok")
    }
}

@Suite struct VoicePrintTests {
    func vec(_ seed: Int, noise: Float = 0) -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<64).map { i in sin(Float(i * seed) * 0.37) + Float.random(in: -noise...noise, using: &g) }
    }

    @Test func matchesSameVoiceAndRejectsStrangers() {
        let anna = VoicePrint(name: "Anna", centroid: vec(3))
        let ben = VoicePrint(name: "Ben", centroid: vec(7))
        let m = VoiceMatcher(threshold: 0.6)
        #expect(m.bestMatch(for: vec(3, noise: 0.1), in: [anna, ben])?.print.name == "Anna")
        #expect(m.bestMatch(for: vec(11), in: [anna, ben]) == nil)
    }

    @Test func eachPrintUsedOncePerTrack() {
        let anna = VoicePrint(name: "Anna", centroid: vec(3))
        let speakers = [
            Speaker(id: "system:S1", track: .system, embedding: vec(3, noise: 0.05), talkTime: 10, colorIndex: 0),
            Speaker(id: "system:S2", track: .system, embedding: vec(3, noise: 0.3), talkTime: 5, colorIndex: 1),
        ]
        let labelled = VoiceMatcher(threshold: 0.5, margin: 0).label(speakers, with: [anna])
        #expect(labelled.filter { $0.name == "Anna" }.count == 1)
        #expect(labelled[0].name == "Anna")
    }

    @Test func confirmedSpeakersKeepTheirNames() {
        var s = Speaker(id: "mic:S1", track: .mic, embedding: vec(5), talkTime: 1, colorIndex: 0)
        s.name = "Custom"
        s.isConfirmed = true
        let labelled = VoiceMatcher().label([s], with: [VoicePrint(name: "Other", centroid: vec(5))])
        #expect(labelled[0].name == "Custom")
    }

    @Test func absorbMovesCentroidTowardsSample() {
        var p = VoicePrint(name: "A", centroid: vec(3))
        let target = vec(4)
        let before = AudioMath.cosine(p.centroid, target)
        p.absorb(target)
        #expect(AudioMath.cosine(p.centroid, target) > before)
        #expect(p.sampleCount == 2)
    }
}

@Suite struct AudioMathTests {
    @Test func quietestSplitFindsSilence() {
        var s = [Float](repeating: 0.5, count: 16_000 * 3)
        for i in 32_000..<33_600 { s[i] = 0 }
        let split = AudioMath.quietestSplit(in: s, searchRange: 24_000..<48_000)
        #expect((32_000..<33_600).contains(split))
    }

    @Test func exportFormats() {
        let m = Meeting(title: "T", duration: 65, status: .ready,
                        speakers: [Speaker(id: "mic:S1", track: .mic, name: "Ann", embedding: [], talkTime: 3, colorIndex: 0)],
                        segments: [TranscriptSegment(speakerID: "mic:S1", start: 61.5, end: 63, text: "Hi.")])
        #expect(m.plainText == "[1:01] Ann: Hi.")
        #expect(m.srt.contains("00:01:01,500 --> 00:01:03,000"))
    }
}

@Suite struct EchoFilterTests {
    @Test func micClusterMatchingCallVoiceIsEcho() {
        let voice: [Float] = (0..<32).map { sin(Float($0) * 0.3) }
        let me: [Float] = (0..<32).map { cos(Float($0) * 1.7) }
        let centroids = ["system:S1": voice, "mic:S1": voice.map { $0 * 0.9 + 0.01 }, "mic:S2": me]
        #expect(EchoFilter.echoSpeakers(centroids: centroids) == ["mic:S1"])
    }

    @Test func noCallAudioMeansNoEcho() {
        #expect(EchoFilter.echoSpeakers(centroids: ["mic:S1": [1, 0], "mic:S2": [1, 0]]).isEmpty)
    }
}
