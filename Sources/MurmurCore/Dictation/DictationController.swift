import AppKit
import Foundation
import Observation
import os

final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ s: [Float]) {
        lock.lock(); samples.append(contentsOf: s); lock.unlock()
    }

    func take() -> [Float] {
        lock.lock(); defer { samples = []; lock.unlock() }
        return samples
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }
}

@MainActor
@Observable
public final class DictationController {
    public enum State: Equatable {
        case idle
        case listening(handsFree: Bool)
        case transcribing
        case inserted(String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// Recent meter levels for the HUD waveform (oldest first).
    public private(set) var levels: [Float] = Array(repeating: 0, count: 28)
    public private(set) var startedAt: Date?
    public private(set) var targetAppName: String?
    public private(set) var targetAppIcon: NSImage?

    public var model: ASRModelChoice = .ultra
    public var learnMyVoice = true
    public var meName = "Me"
    public var onDictation: ((Dictation) -> Void)?
    public var onVoiceSample: (@MainActor ([Float]) -> Void)?

    private let log = Logger(subsystem: "com.patrickfreyer.murmur", category: "Dictation")
    private let mic = MicCapture()
    private let buffer = SampleBuffer()
    private let meter = LevelMeter()
    private var meterTask: Task<Void, Never>?
    private var lastTapAt: TimeInterval = 0
    private var stopOnRelease = false
    private var voiceSamplesLearned = 0
    private let maxDuration: TimeInterval = 10 * 60

    public init() {
        mic.onSamples = { [buffer, meter] s in
            buffer.append(s)
            meter.push(s)
        }
    }

    public func prewarm() { mic.prewarm() }

    public var isActive: Bool {
        if case .listening = state { return true }
        return state == .transcribing
    }

    // MARK: - Key handling

    public func handle(_ event: FnKeyMonitor.Event) {
        DiagnosticLog.write("fn event \(event) in state \(state)")
        switch event {
        case .pressed:
            switch state {
            case .listening(handsFree: true):
                stopOnRelease = true
            case .idle, .inserted, .failed:
                begin()
            default:
                break
            }

        case .released(let held, let interrupted):
            guard case .listening(let handsFree) = state else { return }
            if handsFree {
                if stopOnRelease {
                    stopOnRelease = false
                    finish()
                }
                return
            }
            if interrupted {
                cancel()
                return
            }
            if held >= 0.3 {
                finish()
                return
            }
            // Short tap: a second tap within 450 ms switches to hands-free mode.
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTapAt < 0.45 {
                lastTapAt = 0
                state = .listening(handsFree: true)
            } else {
                lastTapAt = now
                cancel(silently: true)
            }

        case .escape:
            cancel()
        }
    }

    // MARK: - Recording

    public func toggleHandsFree() {
        switch state {
        case .listening: finish()
        case .transcribing: break
        default:
            begin()
            if case .listening = state { state = .listening(handsFree: true) }
        }
    }

    private func begin() {
        let front = NSWorkspace.shared.frontmostApplication
        targetAppName = front?.localizedName
        targetAppIcon = front?.icon
        _ = buffer.take()
        meter.reset()
        do {
            try mic.start()
        } catch {
            fail("Microphone unavailable: \(error.localizedDescription)")
            return
        }
        startedAt = .now
        state = .listening(handsFree: false)
        stopOnRelease = false
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                self.levels.removeFirst()
                self.levels.append(self.meter.level)
                if let s = self.startedAt, Date.now.timeIntervalSince(s) > self.maxDuration { self.finish() }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    public func cancel(silently: Bool = false) {
        mic.stop()
        meterTask?.cancel()
        _ = buffer.take()
        levels = Array(repeating: 0, count: levels.count)
        state = .idle
        startedAt = nil
    }

    public func finish() {
        guard case .listening = state else { return }
        // Keep the mic open ~150 ms after release: people let go of fn while saying the last word.
        state = .transcribing
        meterTask?.cancel()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            mic.stop()
            let samples = buffer.take()
            levels = Array(repeating: 0, count: levels.count)
            await transcribe(samples)
        }
    }

    private func transcribe(_ samples: [Float]) async {
        let duration = Double(samples.count) / AudioSpec.sampleRate
        guard duration > 0.35, AudioMath.rms(samples) > 0.0025 else {
            state = .idle
            return
        }
        let started = Date.now
        do {
            try await SpeechEngine.shared.prepareASR(model)
            let result = try await SpeechEngine.shared.transcribe(samples)
            guard !result.text.isEmpty else {
                state = .idle
                return
            }
            let text = TextInserter.adapt(result.text, to: TextInserter.focusedContext())
            TextInserter.insert(text)
            let elapsed = Date.now.timeIntervalSince(started)
            log.info("Dictated \(duration, format: .fixed(precision: 1))s in \(elapsed, format: .fixed(precision: 2))s")
            onDictation?(
                Dictation(
                    text: result.text, duration: duration, appName: targetAppName, processingTime: elapsed))
            state = .inserted(result.text)
            learnVoice(from: samples, duration: duration)
            try? await Task.sleep(for: .milliseconds(900))
            if case .inserted = state { state = .idle }
        } catch {
            fail(error.localizedDescription)
        }
        startedAt = nil
    }

    /// Every dictation is you speaking, so it's free training data for your voice print.
    /// Taper off once the print is solid to save energy.
    private func learnVoice(from samples: [Float], duration: TimeInterval) {
        guard learnMyVoice, duration >= 2.5 else { return }
        voiceSamplesLearned += 1
        guard voiceSamplesLearned <= 25 || voiceSamplesLearned % 10 == 0 else { return }
        let handler = onVoiceSample
        Task.detached(priority: .background) {
            guard let embedding = try? await SpeechEngine.shared.embedding(for: samples) else { return }
            await MainActor.run { handler?(embedding) }
        }
    }

    private func fail(_ message: String) {
        log.error("\(message)")
        state = .failed(message)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if case .failed = state { state = .idle }
        }
    }
}
