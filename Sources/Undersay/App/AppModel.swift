import AVFoundation
import AppKit
import ApplicationServices
import UndersayCore
import Observation
import ServiceManagement
import SwiftUI

enum SidebarItem: Hashable {
    case today
    case meetings
    case dictations
    case people
    case stats
    case coach
    case automation(UUID)
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

    var selection: SidebarItem? = .today
    var modelStatus: ModelStatus = .idle
    var hasAccessibility = AXIsProcessTrusted()
    var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    var fnMonitorRunning = false
    var summarizing: Set<UUID> = []
    var coaching: Set<UUID> = []
    var agents: [AgentInfo] = []
    /// Meetings with an automation running or queued, by automation.
    var automationsRunning: Set<String> = []
    var automations: [Automation] = AppModel.loadAutomations() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(automations), forKey: "automations") }
    }
    /// Last focus the Coach page found (shown in the sidebar without recomputing anything).
    var coachFocus: Coach.Focus? = Coach.Focus(rawValue: Defaults.string("coachFocus") ?? "") {
        didSet { Defaults.set(coachFocus?.rawValue ?? "", "coachFocus") }
    }
    /// Commitments you ticked off.
    var coachDone: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "coachDone") ?? [])

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
        // Persist migrated automations right away (didSet doesn't fire for initial values).
        if UserDefaults.standard.data(forKey: "automations") == nil, !automations.isEmpty {
            UserDefaults.standard.set(try? JSONEncoder().encode(automations), forKey: "automations")
        }
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
            runAutomations(after: id)
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

    // MARK: Automations

    static func loadAutomations() -> [Automation] {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "automations"), let list = try? JSONDecoder().decode([Automation].self, from: data) {
            return list
        }
        // One-time migration from the earlier "Knowledge" setting.
        guard let data = d.data(forKey: "knowledgeSettings"),
            let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let folderString = old["folder"] as? String, let folder = URL(string: folderString)
        else { return [] }
        var prompt = (old["instructions"] as? String) ?? ""
        if let archive = (old["archiveFolder"] as? String).flatMap(URL.init(string:)) {
            prompt += "\n\nAlso save a cleaned, readable copy of the transcript as \(archive.path)/<project-or-client-slug>/<YYYY-MM-DD>_<short-topic>.txt (\"_internal\" for internal meetings, \"_unsorted\" if unsure)."
        }
        var a = Automation(name: "Knowledge graph", agent: .claudeCode, folder: folder,
                           prompt: "Enrich my knowledge graph from this transcript.\n\n" + prompt)
        a.runAutomatically = old["autoSync"] as? Bool ?? false
        a.allowShell = !((old["allowedCommands"] as? [String]) ?? []).isEmpty
        a.model = old["model"] as? String
        return [a]
    }

    func refreshAgents() async {
        agents = await Agents.detect()
    }

    func key(_ meeting: UUID, _ automation: UUID) -> String { "\(meeting)-\(automation)" }

    func run(_ automation: Automation, on meetingID: UUID) {
        let k = key(meetingID, automation.id)
        guard let meeting = meetings.meeting(meetingID), !automationsRunning.contains(k) else { return }
        automationsRunning.insert(k)
        setRun(AutomationRun(automation: automation), on: meetingID)
        let me = meName, myPrint = voices.me?.id
        Task {
            // Runs are serialised inside the runner actor: one agent at a time.
            let result = await AutomationRunner.shared.run(automation, meeting: meeting, meName: me, myVoicePrint: myPrint)
            setRun(result, on: meetingID)
            automationsRunning.remove(k)
            DiagnosticLog.write("automation \(automation.name): \(result.status.rawValue) on \(meeting.title)")
        }
    }

    private func setRun(_ run: AutomationRun, on meetingID: UUID) {
        meetings.update(meetingID) { m in
            var runs = m.automationRuns ?? []
            runs.removeAll { $0.automationID == run.automationID }
            runs.append(run)
            m.automationRuns = runs
        }
    }

    /// After a meeting is transcribed (and summarised), run every automation set to run automatically.
    func runAutomations(after meetingID: UUID) {
        guard meetings.meeting(meetingID)?.status == .ready else { return }
        for a in automations where a.enabled && a.runAutomatically { run(a, on: meetingID) }
    }

    func latestRun(of automation: UUID) -> AutomationRun? {
        meetings.meetings.compactMap { $0.automationRuns?.first { $0.automationID == automation } }
            .max { $0.startedAt < $1.startedAt }
    }

    func addAutomation(_ agent: AgentKind) -> Automation {
        let a = Automation(name: "New automation", agent: agent,
                           prompt: "Summarise the decisions and action items from this meeting into a note in this folder.")
        automations.append(a)
        return a
    }

    func toggleCoachDone(_ id: String) {
        if coachDone.contains(id) { coachDone.remove(id) } else { coachDone.insert(id) }
        UserDefaults.standard.set(Array(coachDone), forKey: "coachDone")
    }

    /// On-demand coaching for one meeting (Apple Intelligence, on device). Stored with the meeting.
    func coach(_ id: UUID) async {
        guard let meeting = meetings.meeting(id) else { return }
        let me = voices.me
        let you = Set(meeting.speakers.filter { s in
            (me != nil && s.voicePrintID == me?.id) || s.name == meName
        }.map(\.id))
        guard !you.isEmpty else { return }
        coaching.insert(id)
        defer { coaching.remove(id) }
        do {
            let notes = try await CoachFeedback.generate(for: meeting, youAre: you)
            meetings.update(id) { $0.coaching = notes }
        } catch {
            DiagnosticLog.write("coach: feedback failed: \(error.localizedDescription)")
        }
    }

    func assign(name: String, speakerID: String, meetingID: UUID, isMe: Bool = false) {
        SpeakerNaming.assign(
            name: name, to: speakerID, in: meetingID, store: meetings, voices: voices, matcher: matcher,
            isMe: isMe || name == meName)
    }

    func deleteMeeting(_ id: UUID) {
        if selection == .meeting(id) { selection = .today }
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
