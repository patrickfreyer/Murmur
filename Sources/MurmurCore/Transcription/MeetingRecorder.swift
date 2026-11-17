import AppKit
import Foundation
import Observation
import os

public struct LiveLine: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public var track: AudioTrack
    public var start: TimeInterval
    public var text: String
}

/// Records mic + system audio to disk and shows a live transcript while the meeting runs.
@MainActor
@Observable
public final class MeetingRecorder {
    public enum State: Equatable {
        case idle
        case recording(UUID)
        case finishing
    }

    public private(set) var state: State = .idle
    public private(set) var startedAt: Date?
    public private(set) var liveLines: [LiveLine] = []
    public private(set) var micLevel: Float = 0
    public private(set) var systemLevel: Float = 0
    public private(set) var systemAudioError: String?
    public var lastError: String?

    private let log = Logger(subsystem: "com.patrickfreyer.murmur", category: "Meeting")
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var tracks: [AudioTrack: TrackRecorder] = [:]
    private var liveTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?

    public init() {}

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    public var meetingID: UUID? {
        if case .recording(let id) = state { return id }
        return nil
    }

    public func start(store: MeetingStore, echoCancellation: Bool, captureSystemAudio: Bool) async {
        guard state == .idle else { return }
        lastError = nil
        systemAudioError = nil
        liveLines = []
        let source = Self.detectMeetingApp()
        let meeting = Meeting(
            title: Self.defaultTitle(source: source), status: .recording, sourceApp: source)
        do {
            try FileManager.default.createDirectory(
                at: Paths.meetingFolder(meeting.id), withIntermediateDirectories: true)
            let clock = ProcessInfo.processInfo.systemUptime
            let micTrack = try TrackRecorder(url: Paths.track(.mic, meeting: meeting.id), clockStart: clock)
            let mic = MicCapture()
            mic.onSamples = { micTrack.append($0) }
            try mic.start(echoCancellation: false)
            self.mic = mic
            tracks[.mic] = micTrack

            if captureSystemAudio {
                do {
                    let sysTrack = try TrackRecorder(url: Paths.track(.system, meeting: meeting.id), clockStart: clock)
                    let system = SystemAudioCapture()
                    system.onSamples = { sysTrack.append($0) }
                    try system.start()
                    self.system = system
                    tracks[.system] = sysTrack
                } catch {
                    systemAudioError = error.localizedDescription
                    log.error("System audio unavailable: \(error.localizedDescription)")
                }
            }
        } catch {
            lastError = error.localizedDescription
            teardown()
            return
        }
        store.save(meeting)
        startedAt = .now
        state = .recording(meeting.id)
        startLiveLoop()
    }

    public func stop(
        store: MeetingStore, voices: VoicePrintStore, matcher: VoiceMatcher, model: ASRModelChoice, meName: String
    ) async {
        guard case .recording(let id) = state else { return }
        state = .finishing
        let duration = startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        liveTask?.cancel()
        mic?.stop()
        system?.stop()
        for t in tracks.values { t.finish() }
        teardown()
        store.update(id) { $0.duration = duration }
        state = .idle
        startedAt = nil
        await MeetingProcessor.process(
            id, store: store, voices: voices, matcher: matcher, model: model, meName: meName)
    }

    public func cancel(store: MeetingStore) {
        guard case .recording(let id) = state else { return }
        liveTask?.cancel()
        mic?.stop()
        system?.stop()
        for t in tracks.values { t.finish() }
        teardown()
        store.delete(id)
        state = .idle
        startedAt = nil
    }

    private func teardown() {
        mic = nil
        system = nil
        tracks = [:]
        meterTask?.cancel()
        meterTask = nil
        liveTask = nil
        micLevel = 0
        systemLevel = 0
    }

    private func startLiveLoop() {
        let tracks = self.tracks
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.micLevel = tracks[.mic]?.meter.level ?? 0
                self?.systemLevel = tracks[.system]?.meter.level ?? 0
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        liveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard await SpeechEngine.shared.isASRReady else { continue }
                for (track, recorder) in tracks {
                    guard let chunk = recorder.takeLiveChunk(minSeconds: 7) else { continue }
                    // Skip silence: no point spending the ANE on it.
                    guard AudioMath.rms(chunk.samples) > 0.004 else { continue }
                    if let result = try? await SpeechEngine.shared.transcribe(
                        chunk.samples, offset: chunk.start, track: track), !result.text.isEmpty
                    {
                        self?.appendLive(LiveLine(track: track, start: chunk.start, text: result.text))
                    }
                }
            }
        }
    }

    private func appendLive(_ line: LiveLine) {
        liveLines.append(line)
        liveLines.sort { $0.start < $1.start }
    }

    // MARK: - Helpers

    static let meetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.apple.FaceTime": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.hnc.Discord": "Discord",
    ]

    static func detectMeetingApp() -> String? {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, let name = meetingApps[front] {
            return name
        }
        return running.lazy.compactMap { meetingApps[$0] }.first
    }

    static func defaultTitle(source: String?) -> String {
        let time = Date.now.formatted(.dateTime.weekday(.wide).hour().minute())
        if let source { return "\(source) call · \(time)" }
        return "Meeting · \(time)"
    }
}
