import AVFoundation
import FluidAudio
import Foundation
import os

/// Offline pass after a meeting: full-accuracy ASR per track, diarization per track,
/// word→speaker alignment and voice-print labelling.
@MainActor
public enum MeetingProcessor {
    private static let log = Logger(subsystem: "com.patrickfreyer.murmur", category: "Processor")

    public static func process(
        _ id: UUID, store: MeetingStore, voices: VoicePrintStore, matcher: VoiceMatcher, model: ASRModelChoice,
        meName: String
    ) async {
        let engine = SpeechEngine.shared
        func status(_ text: String) { store.update(id) { $0.status = .processing; $0.statusDetail = text } }

        do {
            status("Loading speech model…")
            try await engine.prepareASR(model)

            var allWords: [Word] = []
            var turns: [AudioTrack: [SpeakerTurn]] = [:]
            var centroids: [String: [Float]] = [:]
            var duration: TimeInterval = 0

            for track in AudioTrack.allCases {
                let url = Paths.track(track, meeting: id)
                let length = AudioFileInfo.duration(url)
                guard length > 0.5 else { continue }
                duration = max(duration, length)

                status(track == .mic ? "Transcribing your microphone…" : "Transcribing call audio…")
                let words = try await engine.transcribeFile(url, track: track)
                guard !words.isEmpty else { continue }
                allWords += words

                status("Identifying speakers…")
                do {
                    let result = try await engine.diarize(url)
                    let prefix = "\(track.rawValue):"
                    turns[track] = result.segments.map {
                        SpeakerTurn(
                            speakerID: prefix + $0.speakerId, start: Double($0.startTimeSeconds),
                            end: Double($0.endTimeSeconds))
                    }
                    if let db = result.speakerDatabase, !db.isEmpty {
                        for (k, v) in db { centroids[prefix + k] = v }
                    } else {
                        for (k, v) in meanEmbeddings(result.segments) { centroids[prefix + k] = v }
                    }
                } catch {
                    log.error("Diarization failed on \(track.rawValue): \(error.localizedDescription)")
                }
            }

            let words = TranscriptAssembler.removeEcho(allWords)
            var speakerIDs = [String](repeating: "", count: words.count)
            for track in AudioTrack.allCases {
                let idx = words.indices.filter { words[$0].track == track }
                let fallback = "\(track.rawValue):S1"
                let assigned = TranscriptAssembler.assignSpeakers(
                    words: idx.map { words[$0] }, turns: turns[track] ?? [], fallback: fallback)
                for (i, sp) in zip(idx, assigned) { speakerIDs[i] = sp }
            }
            let segments = TranscriptAssembler.segments(words: words, speakerIDs: speakerIDs)
            let talk = TranscriptAssembler.talkTime(segments)

            let existing = store.meeting(id)?.speakers ?? []
            var speakers: [Speaker] = talk.keys.sorted().enumerated().map { i, sid in
                let track: AudioTrack = sid.hasPrefix("system") ? .system : .mic
                if let old = existing.first(where: { $0.id == sid && $0.isConfirmed }) {
                    var s = old
                    s.talkTime = talk[sid] ?? 0
                    return s
                }
                return Speaker(
                    id: sid, track: track, embedding: centroids[sid] ?? [], talkTime: talk[sid] ?? 0,
                    colorIndex: i)
            }
            speakers = matcher.label(speakers, with: voices.prints)
            speakers = suggestMe(speakers, voices: voices, meName: meName)

            store.update(id) {
                $0.segments = segments
                $0.speakers = speakers.sorted { $0.talkTime > $1.talkTime }
                $0.duration = max($0.duration, duration)
                $0.status = .ready
                $0.statusDetail = nil
            }
        } catch {
            log.error("Processing failed: \(error.localizedDescription)")
            store.update(id) {
                $0.status = .failed
                $0.statusDetail = error.localizedDescription
            }
        }
    }

    /// Before your voice print exists, the person who talks most on the microphone during a call
    /// is almost always you: suggest it (unconfirmed) so one tap teaches Murmur your voice.
    static func suggestMe(_ speakers: [Speaker], voices: VoicePrintStore, meName: String) -> [Speaker] {
        guard voices.me == nil, speakers.contains(where: { $0.track == .system }) else { return speakers }
        guard !speakers.contains(where: { $0.name == meName }),
            let i = speakers.indices.filter({ speakers[$0].track == .mic && speakers[$0].name == nil })
                .max(by: { speakers[$0].talkTime < speakers[$1].talkTime })
        else { return speakers }
        var result = speakers
        result[i].name = meName
        return result
    }

    static func meanEmbeddings(_ segments: [TimedSpeakerSegment]) -> [String: [Float]] {
        var sums: [String: [Float]] = [:]
        for seg in segments where !seg.embedding.isEmpty {
            let w = seg.durationSeconds
            let e = AudioMath.normalized(seg.embedding).map { $0 * w }
            if let s = sums[seg.speakerId], s.count == e.count {
                sums[seg.speakerId] = zip(s, e).map(+)
            } else {
                sums[seg.speakerId] = e
            }
        }
        return sums.mapValues(AudioMath.normalized)
    }
}

/// Applies a user's speaker naming to a meeting and the voice-print library.
@MainActor
public enum SpeakerNaming {
    public static func assign(
        name: String, to speakerID: String, in meetingID: UUID, store: MeetingStore, voices: VoicePrintStore,
        matcher: VoiceMatcher, isMe: Bool = false
    ) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let meeting = store.meeting(meetingID),
            let speaker = meeting.speaker(speakerID)
        else { return }

        var printID: UUID?
        if !speaker.embedding.isEmpty {
            printID = voices.enroll(name: clean, embedding: speaker.embedding, isMe: isMe).id
        }
        store.update(meetingID) { m in
            guard let i = m.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
            m.speakers[i].name = clean
            m.speakers[i].isConfirmed = true
            m.speakers[i].voicePrintID = printID
            m.speakers[i].matchScore = nil
        }
        relabelLibrary(store: store, voices: voices, matcher: matcher)
    }

    /// Clears a name and forgets nothing else (the voice print keeps earlier samples).
    public static func clear(_ speakerID: String, in meetingID: UUID, store: MeetingStore) {
        store.update(meetingID) { m in
            guard let i = m.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
            m.speakers[i].name = nil
            m.speakers[i].isConfirmed = false
            m.speakers[i].voicePrintID = nil
            m.speakers[i].matchScore = nil
        }
    }

    /// Re-runs matching for every unconfirmed speaker in every meeting, so naming someone once
    /// also labels them in older transcripts.
    public static func relabelLibrary(store: MeetingStore, voices: VoicePrintStore, matcher: VoiceMatcher) {
        for meeting in store.meetings where meeting.status == .ready {
            let labelled = matcher.label(meeting.speakers, with: voices.prints)
            if labelled != meeting.speakers {
                store.update(meeting.id) { $0.speakers = labelled }
            }
        }
    }
}

public enum AudioFileInfo {
    public static func duration(_ url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
