import AVFoundation
import Accelerate

public enum AudioSpec {
    /// Every model in the pipeline (Parakeet, pyannote, WeSpeaker) runs on 16 kHz mono.
    public static let sampleRate: Double = 16_000
    public static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// On-disk format for meeting tracks: 16-bit PCM keeps files at ~115 MB/hour per track
    /// without the artefacts lossy codecs add for ASR.
    public static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
}

/// Converts arbitrary PCM buffers (any rate, any channel count) to 16 kHz mono Float32.
/// Not thread safe: use one instance per audio source, called from that source's queue.
public final class Resampler {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    public init() {}

    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        if inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: AudioSpec.format)
            converter?.downmix = true
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            inputFormat = buffer.format
        }
        guard let converter else { return [] }
        let ratio = AudioSpec.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioSpec.format, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

public enum AudioMath {
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }

    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress, ptr.count > 0 else { return 0 }
            var value: Float = 0
            vDSP_rmsqv(base, 1, &value, vDSP_Length(ptr.count))
            return value
        }
    }

    /// Maps RMS to a perceptual 0...1 level for meters.
    public static func meterLevel(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 55) / 50))
    }

    /// Finds a good split point (quietest 100 ms frame) inside `searchRange` so live chunks
    /// don't cut words in half.
    public static func quietestSplit(in samples: [Float], searchRange: Range<Int>) -> Int {
        let frame = Int(AudioSpec.sampleRate / 10)
        let lower = max(0, searchRange.lowerBound)
        let upper = min(samples.count, searchRange.upperBound)
        guard upper - lower > frame else { return upper }
        var best = upper
        var bestRMS = Float.greatestFiniteMagnitude
        var start = lower
        while start + frame <= upper {
            let value = rms(samples[start..<(start + frame)])
            if value < bestRMS {
                bestRMS = value
                best = start + frame / 2
            }
            start += frame / 2
        }
        return best
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let denom = sqrt(na) * sqrt(nb)
        return denom > 0 ? dot / denom : 0
    }

    public static func normalized(_ v: [Float]) -> [Float] {
        var sq: Float = 0
        vDSP_svesq(v, 1, &sq, vDSP_Length(v.count))
        let n = sqrt(sq)
        guard n > 0 else { return v }
        return v.map { $0 / n }
    }
}

/// Thread-safe level publisher shared between audio threads and the UI.
public final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var _level: Float = 0

    public init() {}

    public var level: Float {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    public func push(_ samples: [Float]) {
        let l = AudioMath.meterLevel(AudioMath.rms(samples))
        lock.lock()
        // Fast attack, slow release reads better on a meter.
        _level = l > _level ? l : _level * 0.8 + l * 0.2
        lock.unlock()
    }

    public func reset() {
        lock.lock(); _level = 0; lock.unlock()
    }
}
