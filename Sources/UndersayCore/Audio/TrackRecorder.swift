import AVFoundation

/// Streams one audio source to disk while keeping a small rolling buffer for live transcription.
public final class TrackRecorder: @unchecked Sendable {
    public let url: URL
    public let meter = LevelMeter()
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "undersay.track-writer", qos: .userInitiated)
    private var pending: [Float] = []
    private var pendingStart = 0
    private var written = 0
    /// Uptime when the meeting started; both tracks are aligned to it.
    private let clockStart: TimeInterval

    public init(url: URL, clockStart: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        self.url = url
        self.clockStart = clockStart
        file = try AVAudioFile(
            forWriting: url, settings: AudioSpec.fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Called from audio threads.
    public func append(_ samples: [Float]) {
        meter.push(samples)
        let arrival = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            // Sources like the system-audio tap go quiet (deliver nothing) when no app plays sound.
            // Fill those holes with silence so the track stays on the meeting's clock.
            let expected = Int((arrival - clockStart) * AudioSpec.sampleRate) - samples.count
            if expected - written > Int(AudioSpec.sampleRate * 0.25) {
                if ProcessInfo.processInfo.environment["UNDERSAY_DEBUG_PAD"] != nil {
                    print("pad \(url.lastPathComponent) +\(expected - written) at \(written)")
                }
                write([Float](repeating: 0, count: expected - written))
            }
            write(samples)
        }
    }

    private func write(_ samples: [Float]) {
        do {
            guard let file, let buffer = AVAudioPCMBuffer(
                pcmFormat: AudioSpec.format, frameCapacity: AVAudioFrameCount(samples.count))
            else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            try? file.write(from: buffer)
            written += samples.count
            pending.append(contentsOf: samples)
        }
    }

    public var duration: TimeInterval {
        queue.sync { Double(written) / AudioSpec.sampleRate }
    }

    /// Takes the not-yet-transcribed audio once at least `minSeconds` are buffered, splitting at a
    /// quiet moment so words aren't cut. Returns the chunk and its start offset in seconds.
    public func takeLiveChunk(minSeconds: Double, force: Bool = false) -> (samples: [Float], start: TimeInterval)? {
        queue.sync {
            let minCount = Int(minSeconds * AudioSpec.sampleRate)
            guard !pending.isEmpty, force || pending.count >= minCount else { return nil }
            let split: Int
            if force {
                split = pending.count
            } else {
                let window = Int(1.5 * AudioSpec.sampleRate)
                split = AudioMath.quietestSplit(
                    in: pending, searchRange: (pending.count - window)..<pending.count)
            }
            let chunk = Array(pending[0..<split])
            let start = Double(pendingStart) / AudioSpec.sampleRate
            pending.removeFirst(split)
            pendingStart += split
            return (chunk, start)
        }
    }

    public func finish() {
        queue.sync {
            file = nil  // AVAudioFile flushes and closes on release.
            pending.removeAll()
        }
    }
}
