import Foundation

/// Finds real pauses in the audio and snaps word end times to where the silence begins.
/// The recognizer's timestamps are emission times and drift into silences; energy doesn't.
public enum PauseAligner {
    /// Silent stretches (start, end) in seconds, at least `minLength` long.
    public static func silences(in samples: [Float], sampleRate: Double = AudioSpec.sampleRate,
                                minLength: TimeInterval = 0.25) -> [(TimeInterval, TimeInterval)] {
        let frame = Int(sampleRate * 0.02)  // 20 ms
        guard samples.count > frame * 4 else { return [] }
        var energies: [Float] = []
        var i = 0
        while i + frame <= samples.count {
            energies.append(AudioMath.rms(samples[i..<(i + frame)]))
            i += frame
        }
        // Threshold relative to the speech level, so it works for quiet and loud voices alike.
        let sorted = energies.sorted()
        let speech = sorted[Int(Double(sorted.count) * 0.9)]
        let floor = sorted[Int(Double(sorted.count) * 0.1)]
        let threshold = max(floor * 2.5, speech * 0.08, 0.002)
        var out: [(TimeInterval, TimeInterval)] = []
        var runStart: Int?
        for (k, e) in energies.enumerated() {
            if e < threshold {
                if runStart == nil { runStart = k }
            } else if let s = runStart {
                let a = Double(s * frame) / sampleRate, b = Double(k * frame) / sampleRate
                if b - a >= minLength { out.append((a, b)) }
                runStart = nil
            }
        }
        if let s = runStart {
            let a = Double(s * frame) / sampleRate, b = Double(energies.count * frame) / sampleRate
            if b - a >= minLength { out.append((a, b)) }
        }
        return out
    }

    /// For each pair of neighbouring words, if a silence lies between the first word's start and
    /// the next word's start, end the first word where that silence begins.
    public static func align(_ words: [Word], silences: [(TimeInterval, TimeInterval)]) -> [Word] {
        guard words.count > 1, !silences.isEmpty else { return words }
        var out = words
        for i in 0..<(out.count - 1) {
            let lo = out[i].start, hi = out[i + 1].start
            // The longest silence inside the window is the pause between these words.
            let inside = silences.compactMap { s -> (TimeInterval, TimeInterval)? in
                let a = max(s.0, lo), b = min(s.1, hi)
                return b - a > 0.05 ? (a, b) : nil
            }
            if let best = inside.max(by: { ($0.1 - $0.0) < ($1.1 - $1.0) }) {
                out[i].end = min(out[i].end, max(out[i].start, best.0))
            }
        }
        return out
    }
}
