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
    public private(set) var levels: [Float] = Array(repeating: 0, count: 30)
    public private(set) var startedAt: Date?
    public private(set) var targetAppName: String?
    public private(set) var targetAppIcon: NSImage?
    public private(set) var targetBundleID: String?

    public var model: ASRModelChoice = .ultra
    public var learnMyVoice = true
    public var meName = "Me"
    public var onDictation: ((Dictation) -> Void)?
    public var onVoiceSample: (@MainActor ([Float]) -> Void)?
    /// Moments worth a sound or haptic (handled by the app).
    public var onCue: ((Cue) -> Void)?

    public enum Cue: Sendable { case started, locked, stopped, inserted, cancelled }

    private let log = Logger(subsystem: "com.patrickfreyer.murmur", category: "Dictation")
    private let mic = MicCapture()
    private let buffer = SampleBuffer()
    private let meter = LevelMeter()
    private var meterTask: Task<Void, Never>?
    private var gesture = FnGestureRecognizer()
    private var voiceSamplesLearned = 0
    private let maxDuration: TimeInterval = 10 * 60

    public init() {
        mic.onSamples = { [buffer, meter] s in
            buffer.append(s)
            meter.push(s)
        }
    }

    public func prewarm() { mic.prewarm() }

    /// Puts the HUD into a given state without recording (README screenshots only).
    public func preview(_ state: State, levels: [Float], appIcon: NSImage?) {
        self.state = state
        self.levels = levels
        self.targetAppIcon = appIcon
        self.startedAt = Date.now.addingTimeInterval(-42)
    }

    public var isActive: Bool {
        if case .listening = state { return true }
        return state == .transcribing
    }

    // MARK: - Key handling

    public func handle(_ event: FnKeyMonitor.Event) {
        DiagnosticLog.write("fn event \(event) in state \(state)")
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case .pressed:
            if state == .transcribing { return }
            if case .inserted = state { gesture.reset() }
            if case .failed = state { gesture.reset() }
            apply(gesture.press(at: now))
        case .released(_, let interrupted):
            apply(gesture.release(at: now, interrupted: interrupted))
            if let deadline = gesture.pendingDeadline {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                    guard let self else { return }
                    self.apply(self.gesture.timeout(at: ProcessInfo.processInfo.systemUptime))
                }
            }
        case .escape:
            gesture.reset()
            cancel()
        }
    }

    private func apply(_ action: FnGestureRecognizer.Action) {
        switch action {
        case .none:
            break
        case .start:
            begin()
        case .lock:
            if case .listening = state {
                state = .listening(handsFree: true)
                onCue?(.locked)
            } else {
                begin()
                if case .listening = state { state = .listening(handsFree: true) }
            }
        case .finish:
            finish()
        case .cancel:
            cancel(silently: true)
        }
    }

    // MARK: - Recording

    public func toggleHandsFree() {
        switch state {
        case .listening: finish()
        case .transcribing: break
        default:
            begin()
            if case .listening = state {
                state = .listening(handsFree: true)
                gesture.forceLock()
            }
        }
    }

    private func begin() {
        let front = NSWorkspace.shared.frontmostApplication
        targetAppName = front?.localizedName
        targetAppIcon = front?.icon
        targetBundleID = front?.bundleIdentifier
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
        onCue?(.started)
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
        gesture.reset()
        if case .listening = state, !silently { onCue?(.cancelled) }
        mic.stop()
        meterTask?.cancel()
        _ = buffer.take()
        levels = Array(repeating: 0, count: levels.count)
        state = .idle
        startedAt = nil
    }

    public func finish() {
        guard case .listening = state else { return }
        gesture.reset()
        onCue?(.stopped)
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
                    text: result.text, duration: duration, appName: targetAppName, appBundleID: targetBundleID,
                    processingTime: elapsed))
            state = .inserted(result.text)
            onCue?(.inserted)
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
