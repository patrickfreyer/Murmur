import Foundation
import NaturalLanguage

/// Decides where a long dictation should start a new paragraph.
///
/// A small logistic model over four signals instead of one fixed threshold:
///  - the pause, relative to this speaker's usual pause between sentences in this dictation
///  - the pause in absolute seconds
///  - a transition word opening the next sentence ("Separately," "Also," "Moving on,")
///  - how far the topic moves between the two sentences (Apple's on-device sentence embeddings)
///  - how long the current paragraph already is
///
/// Weights are hand-set starting values. Cheap gates (dictation length, sentences so far, a real
/// pause) mean the embedding model is only consulted for a handful of candidate boundaries.
public enum ParagraphModel {
    public struct Weights: Sendable {
        public var bias = -6.0
        public var relativePause = 1.2
        public var absolutePause = 1.0
        public var transition = 1.8
        public var topicShift = 3.0
        public var paragraphLength = 0.35
        public init() {}
    }

    public static var weights = Weights()

    static let transitions = [
        "separately", "also,", "additionally", "on another note", "on a different note", "moving on",
        "next,", "by the way", "another thing", "one more thing", "in other news", "anyway",
        "übrigens", "außerdem", "zum anderen", "noch etwas", "ein anderes thema",
    ]

    /// Lazily loaded: most dictations never need it.
    nonisolated(unsafe) private static var embeddings: [NLLanguage: NLEmbedding] = [:]
    private static let lock = NSLock()

    /// Topic distance between two sentences (0 = same, ~2 = unrelated), or nil without a model.
    /// NLEmbedding isn't thread-safe, so lookups are serialised; they're rare and fast.
    static func topicDistance(_ a: String, _ b: String) -> Double? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(a + " " + b)
        let lang = recognizer.dominantLanguage ?? .english
        lock.lock(); defer { lock.unlock() }
        let e: NLEmbedding
        if let cached = embeddings[lang] {
            e = cached
        } else {
            guard let loaded = NLEmbedding.sentenceEmbedding(for: lang) else { return nil }
            embeddings[lang] = loaded
            e = loaded
        }
        return e.distance(between: a, and: b)
    }

    struct Sentence {
        var text: String
        var firstPiece: Int
        var gapBefore: TimeInterval
        /// A command or list marker sits between this sentence and the previous one.
        var afterStructure: Bool
    }

    /// Indices (into `pieces`) of words that should start a new paragraph.
    static func breakIndices(
        _ pieces: [SmartFormatter.Piece], minWords: Int, minSentences: Int, minPause: TimeInterval
    ) -> Set<Int> {
        var sentences: [Sentence] = []
        var text = "", first = -1, gap: TimeInterval = 0, structure = false, words = 0
        for (i, p) in pieces.enumerated() {
            switch p {
            case .word(let w, let g):
                words += 1
                if first < 0 { first = i; gap = g }
                text += (text.isEmpty ? "" : " ") + w
                if SmartFormatter.endsSentence(w) {
                    sentences.append(Sentence(text: text, firstPiece: first, gapBefore: gap, afterStructure: structure))
                    text = ""; first = -1; structure = false
                }
            default:
                if !text.isEmpty {
                    sentences.append(Sentence(text: text, firstPiece: first, gapBefore: gap, afterStructure: structure))
                    text = ""; first = -1
                }
                structure = true
            }
        }
        if !text.isEmpty { sentences.append(Sentence(text: text, firstPiece: first, gapBefore: gap, afterStructure: structure)) }
        guard words >= minWords, sentences.count >= minSentences + 1 else { return [] }

        // This speaker's typical pause between sentences (lower median, floored).
        let gaps = sentences.dropFirst().map(\.gapBefore).sorted()
        let typical = max(0.6, gaps.isEmpty ? 0.6 : gaps[(gaps.count - 1) / 2])

        var breaks = Set<Int>()
        var inParagraph = 1
        for k in 1..<sentences.count {
            let s = sentences[k]
            if s.afterStructure { inParagraph = 1; continue }
            defer { inParagraph += 1 }
            guard inParagraph >= minSentences, s.gapBefore >= minPause else { continue }
            let p = probability(previous: sentences[k - 1].text, next: s.text, pause: s.gapBefore,
                                typicalPause: typical, sentencesSoFar: inParagraph)
            if p > 0.5 {
                breaks.insert(s.firstPiece)
                inParagraph = 0
            }
        }
        return breaks
    }

    /// Probability that `next` should open a new paragraph.
    public static func probability(
        previous: String, next: String, pause: TimeInterval, typicalPause: TimeInterval, sentencesSoFar: Int,
        weights w: Weights = weights
    ) -> Double {
        let lower = next.lowercased()
        let transition = transitions.contains { lower.hasPrefix($0) } ? 1.0 : 0.0
        var topic = 0.0
        if let d = topicDistance(previous, next) { topic = max(0, d - 1.1) }
        let z = w.bias
            + w.relativePause * min(pause / typicalPause, 4)
            + w.absolutePause * min(pause, 3)
            + w.transition * transition
            + w.topicShift * topic
            + w.paragraphLength * Double(min(sentencesSoFar, 5))
        return 1 / (1 + exp(-z))
    }
}
