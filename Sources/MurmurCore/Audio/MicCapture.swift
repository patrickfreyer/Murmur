import AVFoundation
import os

/// Captures the default input device and delivers 16 kHz mono samples.
public final class MicCapture {
    private let engine = AVAudioEngine()
    private let resampler = Resampler()
    private let log = Logger(subsystem: "com.patrickfreyer.murmur", category: "Mic")
    private var running = false
    private var outputWired = false

    /// Called on the audio render thread with 16 kHz mono samples.
    public var onSamples: (([Float]) -> Void)?

    public init() {}

    /// Pre-allocates engine resources so the first `start()` is fast (dictation latency).
    public func prewarm() {
        _ = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
    }

    /// - Parameter echoCancellation: use Apple's voice processing (AEC + noise suppression).
    ///   Used for meetings so audio coming out of the speakers isn't transcribed twice.
    public func start(echoCancellation: Bool = false) throws {
        guard !running else { return }
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(echoCancellation)
                if echoCancellation {
                    // Don't duck the call audio the user is listening to.
                    input.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                            enableAdvancedDucking: false, duckingLevel: .min)
                }
            } catch {
                log.error("Voice processing unavailable: \(error.localizedDescription)")
            }
        }
        let format = input.outputFormat(forBus: 0)
        if input.isVoiceProcessingEnabled, !outputWired {
            // Voice-processing I/O only produces samples while its output side runs too:
            // route the mic into a muted mixer so the unit is pulled without playing anything.
            engine.connect(input, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            outputWired = true
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.resampler.convert(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}

public enum CaptureError: LocalizedError {
    case noInputDevice
    case coreAudio(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone is available."
        case .coreAudio(let what, let status): "\(what) failed (OSStatus \(status))."
        }
    }
}
