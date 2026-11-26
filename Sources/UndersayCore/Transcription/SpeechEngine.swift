import AVFoundation
import FluidAudio
import Foundation
import os

public enum ASRModelChoice: String, CaseIterable, Codable, Sendable, Identifiable {
    case ultra, v3, v2

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ultra: "Parakeet Ultra"
        case .v3: "Parakeet v3"
        case .v2: "Parakeet v2"
        }
    }

    public var subtitle: String {
        switch self {
        case .ultra: "25 languages · most accurate"
        case .v3: "25 languages · balanced"
        case .v2: "English only · highest recall"
        }
    }

    var version: AsrModelVersion {
        switch self {
        case .ultra: .ultra
        case .v3: .v3
        case .v2: .v2
        }
    }
}

public struct EngineProgress: Sendable, Equatable {
    public var phase: String
    public var fraction: Double
}

/// Owns the on-device models. Everything runs locally on the Neural Engine via Core ML;
/// models are downloaded once and cached under ~/Library/Application Support/FluidAudio.
public actor SpeechEngine {
    public static let shared = SpeechEngine()

    private let log = Logger(subsystem: "com.patrickfreyer.undersay", category: "Engine")
    private var asr: AsrManager?
    private var loadedChoice: ASRModelChoice?
    private var asrLoading: Task<Void, Error>?
    private var diarizer: OfflineDiarizerManager?
    private var diarizerLoading: Task<Void, Error>?

    public init() {}

    public var isASRReady: Bool { asr != nil }

    public func prepareASR(
        _ choice: ASRModelChoice, progress: (@Sendable (EngineProgress) -> Void)? = nil
    ) async throws {
        if loadedChoice == choice, asr != nil { return }
        if let asrLoading { return try await asrLoading.value }
        let task = Task {
            let models = try await AsrModels.downloadAndLoad(version: choice.version) { p in
                progress?(EngineProgress(phase: "\(p.phase)", fraction: p.fractionCompleted))
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            // Warm-up so the first dictation doesn't pay Core ML's lazy initialisation.
            var state = try TdtDecoderState()
            _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
            self.install(manager, choice)
        }
        asrLoading = task
        defer { asrLoading = nil }
        try await task.value
    }

    private func install(_ manager: AsrManager, _ choice: ASRModelChoice) {
        asr = manager
        loadedChoice = choice
        log.info("ASR ready: \(choice.rawValue)")
    }

    public func prepareDiarizer() async throws {
        if diarizer != nil { return }
        if let diarizerLoading { return try await diarizerLoading.value }
        let task = Task {
            var config = OfflineDiarizerConfig()
            config.clustering.threshold = 0.6
            let manager = OfflineDiarizerManager(config: config)
            try await manager.prepareModels()
            self.installDiarizer(manager)
        }
        diarizerLoading = task
        defer { diarizerLoading = nil }
        try await task.value
    }

    private func installDiarizer(_ manager: OfflineDiarizerManager) {
        diarizer = manager
    }

    // MARK: - Transcription

    public func transcribe(_ samples: [Float], offset: TimeInterval = 0, track: AudioTrack = .mic)
        async throws -> (text: String, words: [Word])
    {
        guard let asr else { throw EngineError.notReady }
        // Parakeet needs at least ~1 s of context; pad short clips with silence.
        var input = samples
        if input.count < 16_000 { input += [Float](repeating: 0, count: 16_000 - input.count) }
        var state = try TdtDecoderState()
        let result = try await asr.transcribe(input, decoderState: &state)
        let words = WordBuilder.words(from: result.tokenTimings ?? [], offset: offset, track: track)
        return (TextCleanup.tidy(result.text), words)
    }

    public func transcribeFile(_ url: URL, track: AudioTrack) async throws -> [Word] {
        guard let asr else { throw EngineError.notReady }
        var state = try TdtDecoderState()
        let result = try await asr.transcribe(url, decoderState: &state)
        return WordBuilder.words(from: result.tokenTimings ?? [], offset: 0, track: track)
    }

    // MARK: - Speakers

    public func diarize(_ url: URL) async throws -> DiarizationResult {
        try await prepareDiarizer()
        guard let diarizer else { throw EngineError.notReady }
        return try await diarizer.process(url)
    }

    /// A WeSpeaker embedding for one clip of a single speaker (used to learn your own voice
    /// from dictations).
    public func embedding(for samples: [Float]) async throws -> [Float]? {
        try await prepareDiarizer()
        guard let diarizer, samples.count > 16_000 else { return nil }
        let duration = Double(samples.count) / AudioSpec.sampleRate
        let result = try await diarizer.embedSpans(
            audioSource: ArrayAudioSampleSource(samples: samples), spans: [0..<duration])
        return result.first
    }
}

public enum EngineError: LocalizedError {
    case notReady

    public var errorDescription: String? {
        switch self {
        case .notReady: "The speech model is still loading."
        }
    }
}

/// Merges SentencePiece tokens into words with timings.
public enum WordBuilder {
    /// The decoder lets the last token before a silence run on into it; no speech token is
    /// really longer than this, so cap it to keep pauses measurable.
    static let maxTokenDuration: TimeInterval = 0.35

    static func tokenEnd(_ t: TokenTiming) -> TimeInterval {
        min(t.endTime, t.startTime + maxTokenDuration)
    }

    public static func words(from tokens: [TokenTiming], offset: TimeInterval, track: AudioTrack) -> [Word] {
        var words: [Word] = []
        for token in tokens {
            var piece = token.token
            guard !piece.isEmpty, piece != "<unk>", piece != "<blank>" else { continue }
            let startsWord = piece.hasPrefix("▁") || piece.hasPrefix(" ")
            piece = piece.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            let isPunctuation = piece.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            if let last = words.indices.last, !startsWord || isPunctuation {
                words[last].text += piece
                // Punctuation is emitted late (often when the next speech starts); letting it stretch
                // the word would hide the pause that follows it.
                if !isPunctuation { words[last].end = max(words[last].end, tokenEnd(token) + offset) }
            } else {
                words.append(Word(text: piece, start: token.startTime + offset, end: tokenEnd(token) + offset, track: track))
            }
        }
        return words
    }
}

public enum TextCleanup {
    /// Whitespace normalisation for dictated text.
    public static func tidy(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " ([,.!?;:])", with: "$1", options: .regularExpression)
        // The decoder sometimes emits a full stop right after ? or ! ("Thursday?.").
        t = t.replacingOccurrences(of: "([?!])[.]+", with: "$1", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
