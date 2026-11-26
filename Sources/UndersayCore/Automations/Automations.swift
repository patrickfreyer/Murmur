import Foundation

/// Automations: after a meeting is transcribed, run a locally installed AI agent (Claude Code, Codex
/// or any command) with your prompt or skill on the transcript. Undersay hands over the transcript and
/// shows what happened; conventions, commits and destinations live in the prompt.
public enum AgentKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case claudeCode, codex, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .custom: "Custom command"
        }
    }

    public var symbol: String {
        switch self {
        case .claudeCode: "sparkle"
        case .codex: "terminal"
        case .custom: "chevron.left.forwardslash.chevron.right"
        }
    }

    var executableNames: [String] {
        switch self {
        case .claudeCode: ["claude"]
        case .codex: ["codex"]
        case .custom: []
        }
    }
}

public struct Automation: Codable, Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var name: String
    public var agent: AgentKind
    /// Working folder (a notes vault, a repo…). nil = your home folder.
    public var folder: URL?
    /// What the agent should do with the transcript: plain words, or "Use the … skill to …".
    public var prompt: String
    public var runAutomatically = true
    public var enabled = true
    /// Let the agent run shell commands (needed by some skills). File edits are always allowed in the folder.
    public var allowShell = false
    /// Optional model alias for the agent ("sonnet", "o4-mini"…). nil = the agent's default.
    public var model: String?
    /// For `.custom`: the command line; `{prompt}` and `{transcript}` are filled in.
    public var command = ""

    public init(name: String, agent: AgentKind, folder: URL? = nil, prompt: String) {
        self.name = name
        self.agent = agent
        self.folder = folder
        self.prompt = prompt
    }
}

public enum RunStatus: String, Codable, Sendable { case running, done, failed }

/// The latest run of one automation on one meeting (stored on the meeting).
public struct AutomationRun: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID { automationID }
    public var automationID: UUID
    public var automationName: String
    public var status: RunStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var summary: String?
    public var changedFiles: [String] = []
    public var error: String?
    public var costUSD: Double?

    public init(automation: Automation, status: RunStatus = .running) {
        automationID = automation.id
        automationName = automation.name
        self.status = status
        startedAt = .now
    }
}

// MARK: - Agents

public struct AgentInfo: Sendable, Equatable, Identifiable {
    public var id: AgentKind { kind }
    public var kind: AgentKind
    public var path: String?
    public var signedIn: Bool?
    public var detail: String?
    public var installed: Bool { path != nil }
}

public enum Agents {
    public static func locate(_ kind: AgentKind) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin"]
        for name in kind.executableNames {
            for d in dirs where FileManager.default.isExecutableFile(atPath: "\(d)/\(name)") {
                return URL(fileURLWithPath: "\(d)/\(name)")
            }
        }
        return nil
    }

    /// What's installed and signed in. Cheap: version and auth-status calls only, no model requests.
    public static func detect() async -> [AgentInfo] {
        var out: [AgentInfo] = []
        let claude = await ClaudeCLI.status()
        var c = AgentInfo(kind: .claudeCode, path: claude.path, signedIn: claude.path == nil ? nil : claude.loggedIn)
        if claude.path == nil, FileManager.default.fileExists(atPath: "/Applications/Claude.app") {
            c.detail = "The Claude app is installed, but automations need its command-line tool, Claude Code (claude.com/claude-code)."
        } else {
            c.detail = claude.version
        }
        out.append(c)
        var x = AgentInfo(kind: .codex, path: locate(.codex)?.path)
        if let p = x.path, let r = try? await Shell.run(URL(fileURLWithPath: p), ["login", "status"]) {
            let text = (r.stdout + r.stderr).lowercased()
            x.signedIn = text.contains("logged in") && !text.contains("not logged in")
            x.detail = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        out.append(x)
        return out
    }
}

// MARK: - CLI

public enum ClaudeCLI {
    public struct Status: Sendable, Equatable {
        public var path: String?
        public var loggedIn = false
        public var method: String?
        public var version: String?
    }

    public static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.claude/local/claude"]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// GUI apps get a minimal environment; give the CLI a normal one.
    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["HOME"] = home
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.removeValue(forKey: "CLAUDECODE")
        return env
    }

    public static func status() async -> Status {
        var s = Status()
        guard let cli = locate() else { return s }
        s.path = cli.path
        if let v = try? await Shell.run(cli, ["--version"]), v.status == 0 {
            s.version = v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let a = try? await Shell.run(cli, ["auth", "status", "--json"]),
            let data = a.stdout.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: Shell.firstJSONObject(data) ?? data) as? [String: Any]
        {
            s.loggedIn = json["loggedIn"] as? Bool ?? false
            s.method = json["authMethod"] as? String
        }
        return s
    }
}

// MARK: - Transcript export

public enum TranscriptExport {
    /// A plain, self-describing transcript for the job: who is who (and how sure we are), then the dialogue.
    public static func markdown(_ m: Meeting, meName: String, myVoicePrint: UUID?) -> String {
        var out = "# \(m.title)\n\n"
        let date = ISO8601DateFormatter.string(from: m.createdAt, timeZone: .current, formatOptions: [.withFullDate])
        out += "- Date: \(date)\n- Duration: \(Meeting.timestamp(m.duration))\n"
        if let app = m.sourceApp { out += "- Recorded from: \(app)\n" }
        out += "- Recorded and transcribed on-device by Undersay\n\n## Participants\n\n"
        for s in m.speakers {
            let you = (myVoicePrint != nil && s.voicePrintID == myVoicePrint) || s.name == meName
            let label: String
            if you {
                label = "\(meName) (the person who recorded this meeting)"
            } else if let name = s.name {
                label = s.isConfirmed ? "\(name) (named by the user)"
                    : "\(name) (recognised by voice, not confirmed: treat attribution as tentative)"
            } else {
                label = "\(s.fallbackName) (unidentified)"
            }
            let where_ = s.track == .mic ? "in the room / microphone" : "on the call"
            out += "- \(label), \(where_), spoke \(Meeting.timestamp(s.talkTime))\n"
        }
        if let summary = m.summary, !summary.isEmpty { out += "\n## Summary (generated)\n\n\(summary)\n" }
        out += "\n## Transcript\n\n"
        for seg in m.segments {
            out += "[\(Meeting.timestamp(seg.start))] \(m.speaker(seg.speakerID)?.displayName ?? "Unknown"): \(seg.text)\n"
        }
        return out
    }

    /// Ready to sync: every speaker with a meaningful share of the conversation has a name.
    public static func speakersNamed(_ m: Meeting) -> Bool {
        let total = max(1, m.speakers.map(\.talkTime).reduce(0, +))
        return m.status == .ready && !m.segments.isEmpty
            && m.speakers.allSatisfy { $0.name != nil || $0.talkTime / total < 0.05 }
    }
}

// MARK: - Runner

public enum AutomationPrompt {
    /// The fixed frame around the user's prompt.
    public static func build(_ userPrompt: String, transcript: String, meeting: Meeting) -> String {
        let date = ISO8601DateFormatter.string(from: meeting.createdAt, timeZone: .current, formatOptions: [.withFullDate])
        let filled = userPrompt
            .replacingOccurrences(of: "{transcript}", with: transcript)
            .replacingOccurrences(of: "{title}", with: meeting.title)
            .replacingOccurrences(of: "{date}", with: date)
        return """
            You are running unattended, started by Undersay right after a meeting was transcribed.
            Meeting: "\(meeting.title)", \(date), \(Meeting.timestamp(meeting.duration)) long.
            Transcript file: \(transcript)
            Speakers may be unnamed ("Speaker 2"). Infer who they are only where the content makes it clear, \
            and treat such attributions as tentative. Use absolute dates.

            Task:
            \(filled)

            Don't ask questions. When you're done, reply with a short plain-text summary (at most 6 lines) \
            of what you did and which files you changed.
            """
    }
}

/// Runs automations one at a time.
public actor AutomationRunner {
    public static let shared = AutomationRunner()

    public func run(_ automation: Automation, meeting: Meeting, meName: String, myVoicePrint: UUID?,
                    timeout: TimeInterval = 20 * 60) async -> AutomationRun {
        var run = AutomationRun(automation: automation)
        let folder = automation.folder ?? FileManager.default.homeDirectoryForCurrentUser

        // The transcript goes to a private temp folder, never into the working folder.
        let tmp = FileManager.default.temporaryDirectory.appending(path: "undersay-run-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let transcript = tmp.appending(path: "transcript.md")
        do {
            try TranscriptExport.markdown(meeting, meName: meName, myVoicePrint: myVoicePrint)
                .write(to: transcript, atomically: true, encoding: .utf8)
        } catch {
            return failed(run, error.localizedDescription)
        }
        let prompt = AutomationPrompt.build(automation.prompt, transcript: transcript.path, meeting: meeting)

        let repo = await Git.root(of: folder)
        let before = repo == nil ? [:] : await Git.dirty(repo!)
        let summaryFile = tmp.appending(path: "summary.txt")

        let exe: URL, args: [String]
        switch automation.agent {
        case .claudeCode:
            guard let cli = Agents.locate(.claudeCode) else { return failed(run, "Claude Code isn't installed.") }
            guard await ClaudeCLI.status().loggedIn else {
                return failed(run, "Claude Code isn't signed in. Run “claude /login” once in Terminal.")
            }
            exe = cli
            // Skills stay on (that's the point); MCP servers are skipped: their tool lists are large and
            // an unattended transcript job rarely needs them.
            var a = ["-p", prompt, "--output-format", "json", "--no-session-persistence",
                     "--permission-mode", "acceptEdits", "--add-dir", tmp.path,
                     "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
            if let m = automation.model, !m.isEmpty { a += ["--model", m] }
            var tools = ["Read", "Glob", "Grep", "Edit", "Write", "Skill"]
            if automation.allowShell { tools.append("Bash") }
            args = a + ["--allowedTools"] + tools
        case .codex:
            guard let cli = Agents.locate(.codex) else { return failed(run, "Codex isn't installed.") }
            exe = cli
            var a = ["exec", "--skip-git-repo-check", "--ephemeral", "-C", folder.path, "--add-dir", tmp.path,
                     "-s", automation.allowShell ? "danger-full-access" : "workspace-write",
                     "-o", summaryFile.path]
            if let m = automation.model, !m.isEmpty { a += ["-m", m] }
            args = a + [prompt]
        case .custom:
            guard !automation.command.isEmpty else { return failed(run, "Set a command for this automation.") }
            exe = URL(fileURLWithPath: "/bin/zsh")
            let cmd = automation.command
                .replacingOccurrences(of: "{prompt}", with: Self.shellQuote(prompt))
                .replacingOccurrences(of: "{transcript}", with: Self.shellQuote(transcript.path))
            args = ["-lc", cmd]
        }

        do {
            let r = try await Shell.run(exe, args, cwd: folder, environment: ClaudeCLI.environment, timeout: timeout)
            switch automation.agent {
            case .claudeCode:
                if let data = Shell.firstJSONObject(r.stdout.data(using: .utf8) ?? Data()),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    run.summary = (json["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    run.costUSD = json["total_cost_usd"] as? Double
                    if json["is_error"] as? Bool == true { run.status = .failed; run.error = run.summary }
                } else if r.status != 0 {
                    run.status = .failed; run.error = Self.lastLine(r.stderr) ?? "Claude Code exited with \(r.status)."
                }
            case .codex:
                run.summary = (try? String(contentsOf: summaryFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? Self.tail(r.stdout)
                if r.status != 0 { run.status = .failed; run.error = Self.lastLine(r.stderr) ?? "Codex exited with \(r.status)." }
            case .custom:
                run.summary = Self.tail(r.stdout)
                if r.status != 0 { run.status = .failed; run.error = Self.lastLine(r.stderr) ?? "The command exited with \(r.status)." }
            }
        } catch {
            return failed(run, error.localizedDescription)
        }

        // Which files did the run change? (Already-dirty files that didn't change are not counted.)
        if let repo {
            let after = await Git.dirty(repo)
            run.changedFiles = after.filter { before[$0.key] != $0.value }.map(\.key).sorted()
        }
        if run.status == .running { run.status = .done }
        run.finishedAt = .now
        return run
    }

    private func failed(_ run: AutomationRun, _ message: String) -> AutomationRun {
        var r = run
        r.status = .failed
        r.error = message
        r.finishedAt = .now
        return r
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func lastLine(_ s: String) -> String? {
        s.split(separator: "\n").last(where: { !$0.contains("Warning: Ignoring extra certs") }).map(String.init)
    }
    static func tail(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.suffix(1200))
    }
}

// MARK: - Shell and git helpers

public enum Shell {
    public struct Result: Sendable { public var status: Int32; public var stdout: String; public var stderr: String }

    public static func run(_ exe: URL, _ args: [String], cwd: URL? = nil, environment: [String: String]? = nil,
                           timeout: TimeInterval = 60) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            p.environment = environment ?? ClaudeCLI.environment
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            // Read pipes concurrently so a chatty process can't fill the buffer and stall.
            let outBox = DataBox(), errBox = DataBox()
            out.fileHandleForReading.readabilityHandler = { outBox.append($0.availableData) }
            err.fileHandleForReading.readabilityHandler = { errBox.append($0.availableData) }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outBox.append(out.fileHandleForReading.readDataToEndOfFile())
                errBox.append(err.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: Result(status: proc.terminationStatus, stdout: outBox.string, stderr: errBox.string))
            }
            do { try p.run() } catch { cont.resume(throwing: error); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
    }

    /// The CLI may print warnings before its JSON; take the first {...} object.
    public static func firstJSONObject(_ data: Data) -> Data? {
        guard let s = String(data: data, encoding: .utf8), let start = s.firstIndex(of: "{"),
            let end = s.lastIndex(of: "}"), start < end
        else { return nil }
        return Data(s[start...end].utf8)
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

public enum Git {
    static let exe = URL(fileURLWithPath: "/usr/bin/git")

    public static func run(_ repo: URL, _ args: [String]) async throws -> Shell.Result {
        try await Shell.run(exe, ["-C", repo.path] + args, timeout: 120)
    }

    public static func root(of folder: URL) async -> URL? {
        guard let r = try? await Shell.run(exe, ["-C", folder.path, "rev-parse", "--show-toplevel"]), r.status == 0
        else { return nil }
        return URL(fileURLWithPath: r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Dirty paths → a content fingerprint, so files already dirty but then changed again are noticed.
    public static func dirty(_ repo: URL) async -> [String: String] {
        guard let r = try? await run(repo, ["status", "--porcelain", "-z", "--untracked-files=all"]), r.status == 0
        else { return [:] }
        var out: [String: String] = [:]
        for entry in r.stdout.split(separator: "\0") where entry.count > 3 {
            let path = String(entry.dropFirst(3))
            let url = repo.appending(path: path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? -1
            let mod = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out[path] = "\(size)-\(mod)"
        }
        return out
    }
}
