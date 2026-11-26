import AVFoundation
import AppKit
import ApplicationServices
import MurmurCore
import Observation
import ServiceManagement
import SwiftUI

enum SidebarItem: Hashable {
    case home
    case meetings
    case dictations
    case voices
    case meeting(UUID)
}

/// App-wide state and wiring. One instance, owned by the app delegate.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let meetings = MeetingStore()
    let voices = VoicePrintStore()
    let dictations = DictationStore()
    let dictation = DictationController()
    let recorder = MeetingRecorder()
    let player = TranscriptPlayer()
    @ObservationIgnored let fnMonitor = FnKeyMonitor()
    @ObservationIgnored private var hud: HUDController?

    var selection: SidebarItem? = .home
    var modelStatus: ModelStatus = .idle
    var hasAccessibility = AXIsProcessTrusted()
    var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    var fnMonitorRunning = false
    var summarizing: Set<UUID> = []

    // MARK: Settings (persisted)

    var asrModel: ASRModelChoice = ASRModelChoice(rawValue: Defaults.string("asrModel") ?? "") ?? .ultra {
        didSet {
            Defaults.set(asrModel.rawValue, "asrModel")
            dictation.model = asrModel
            loadModels()
        }
    }
    var meName: String = Defaults.string("meName") ?? AppModel.firstName() {
        didSet {
            Defaults.set(meName, "meName")
            dictation.meName = meName
        }
    }
    var learnMyVoice: Bool = Defaults.bool("learnMyVoice", true) {
        didSet { Defaults.set(learnMyVoice, "learnMyVoice"); dictation.learnMyVoice = learnMyVoice }
    }
    var suppressGlobeAction: Bool = Defaults.bool("suppressGlobe", true) {
        didSet { Defaults.set(suppressGlobeAction, "suppressGlobe"); fnMonitor.suppressSystemFnAction = suppressGlobeAction }
    }
    var echoCancellation: Bool = Defaults.bool("echoCancellation", true) {
        didSet { Defaults.set(echoCancellation, "echoCancellation") }
    }
    var captureSystemAudio: Bool = Defaults.bool("captureSystemAudio", true) {
        didSet { Defaults.set(captureSystemAudio, "captureSystemAudio") }
    }
    var smartFormatting: Bool = Defaults.bool("smartFormatting", true) {
        didSet { Defaults.set(smartFormatting, "smartFormatting"); dictation.smartFormatting = smartFormatting }
    }
    var soundEffects: Bool = Defaults.bool("soundEffects", true) {
        didSet { Defaults.set(soundEffects, "soundEffects") }
    }
    var autoSummarize: Bool = Defaults.bool("autoSummarize", true) {
        didSet { Defaults.set(autoSummarize, "autoSummarize") }
    }
    var matchThreshold: Double = Defaults.double("matchThreshold", 0.65) {
        didSet { Defaults.set(matchThreshold, "matchThreshold") }
    }
    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login: \(error)")
            }
        }
    }

    var matcher: VoiceMatcher { VoiceMatcher(threshold: Float(matchThreshold)) }

    enum ModelStatus: Equatable {
        case idle
        case loading(String, Double)
        case ready
        case failed(String)
    }

    // MARK: Lifecycle

    func launch() {
        DiagnosticLog.rotate()
        let bundle = Bundle.main.bundlePath
        DiagnosticLog.write("launch \(bundle) AX=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess()) post=\(CGPreflightPostEventAccess())")
        dictation.model = asrModel
        dictation.meName = meName
        dictation.learnMyVoice = learnMyVoice
        dictation.smartFormatting = smartFormatting
        dictation.onDictation = { [weak self] d in self?.dictations.add(d) }
        dictation.onVoiceSample = { [weak self] e in
            guard let self else { return }
            self.voices.enrollMe(embedding: e, defaultName: self.meName)
            SpeakerNaming.relabelLibrary(store: self.meetings, voices: self.voices, matcher: self.matcher)
        }
        dictation.onCue = { [weak self] cue in
            MainActor.assumeIsolated { Feedback.play(cue, sound: self?.soundEffects ?? true) }
        }
        dictation.prewarm()

        hud = HUDController(model: self)

        fnMonitor.suppressSystemFnAction = suppressGlobeAction
        fnMonitor.isCapturingEscape = { [weak self] in
            MainActor.assumeIsolated { self?.dictation.isActive ?? false }
        }
        fnMonitor.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.dictation.handle(event) }
        }
        startFnMonitorIfPossible()
        pollPermissions()
        loadModels()
        Snapshots.runIfRequested(self)
    }

    func loadModels() {
        let choice = asrModel
        modelStatus = .loading("Preparing speech model…", 0)
        Task {
            do {
                try await SpeechEngine.shared.prepareASR(choice) { p in
                    Task { @MainActor in
                        AppModel.shared.modelStatus = .loading(
                            p.fraction < 1 ? "Downloading \(choice.title)…" : "Compiling for the Neural Engine…",
                            p.fraction)
                    }
                }
                modelStatus = .ready
                // Diarization models are small; fetch them in the background for the first meeting.
                Task.detached(priority: .utility) { try? await SpeechEngine.shared.prepareDiarizer() }
            } catch {
                modelStatus = .failed(error.localizedDescription)
            }
        }
    }

    func startFnMonitorIfPossible() {
        hasAccessibility = AXIsProcessTrusted()
        if hasAccessibility { fnMonitorRunning = fnMonitor.start() }
    }

    /// Permissions can be granted in System Settings at any time; pick them up without a relaunch.
    private func pollPermissions() {
        Task { @MainActor in
            while true {
                let ax = AXIsProcessTrusted()
                if ax != hasAccessibility || (ax && !fnMonitorRunning) {
                    DiagnosticLog.write("permissions: AX \(hasAccessibility) -> \(ax), tap running=\(fnMonitorRunning)")
                    hasAccessibility = ax
                    if ax { fnMonitorRunning = fnMonitor.start() }
                }
                micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                try? await Task.sleep(for: .seconds(hasAccessibility ? 10 : 1.5))
            }
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in AppModel.shared.micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
        }
    }

    func openSettingsPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Meetings

    func toggleMeeting() {
        if recorder.isRecording { stopMeeting() } else { startMeeting() }
    }

    func startMeeting() {
        Task {
            await recorder.start(
                store: meetings, echoCancellation: echoCancellation, captureSystemAudio: captureSystemAudio)
            if recorder.isRecording { Feedback.meeting(started: true, sound: soundEffects) }
            if let id = recorder.meetingID { selection = .meeting(id) }
        }
    }

    func stopMeeting() {
        guard let id = recorder.meetingID else { return }
        Feedback.meeting(started: false, sound: soundEffects)
        Task {
            await recorder.stop(
                store: meetings, voices: voices, matcher: matcher, model: asrModel, meName: meName)
            if autoSummarize, Summarizer.isAvailable { await summarize(id) }
        }
    }

    func reprocess(_ id: UUID) {
        Task {
            await MeetingProcessor.process(
                id, store: meetings, voices: voices, matcher: matcher, model: asrModel, meName: meName)
        }
    }

    func summarize(_ id: UUID) async {
        guard let meeting = meetings.meeting(id), !meeting.segments.isEmpty else { return }
        summarizing.insert(id)
        defer { summarizing.remove(id) }
        do {
            let result = try await Summarizer.summarize(meeting)
            meetings.update(id) { m in
                m.summary = result.markdown
                if m.title.hasPrefix("Meeting ·") || m.title.contains(" call · ") { m.title = result.title }
            }
        } catch {
            meetings.update(id) { $0.summary = "Couldn't summarise: \(error.localizedDescription)" }
        }
    }

    func assign(name: String, speakerID: String, meetingID: UUID, isMe: Bool = false) {
        SpeakerNaming.assign(
            name: name, to: speakerID, in: meetingID, store: meetings, voices: voices, matcher: matcher,
            isMe: isMe || name == meName)
    }

    func deleteMeeting(_ id: UUID) {
        if selection == .meeting(id) { selection = .home }
        if player.meetingID == id { player.unload() }
        meetings.delete(id)
    }

    private static func firstName() -> String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
    }
}

enum Defaults {
    static func string(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }
    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
    static func double(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }
    static func set(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
}
