import Foundation

/// Optional "Knowledge" feature: after a meeting, a headless Claude Code job reads the transcript and
/// appends durable facts about people and projects to a folder of notes (an Obsidian vault, a
/// knowledge repo, …), following that folder's own conventions. Nothing runs unless a folder is set.
public struct KnowledgeSettings: Codable, Sendable, Equatable {
    /// The knowledge folder the job works in (its working directory). nil = feature off.
    public var folder: URL?
    /// Optional folder for cleaned transcript copies (may be its own git repo).
    public var archiveFolder: URL?
    /// Run automatically once a meeting's speakers are named.
    public var autoSync = false
    /// Commit (and push) the files the job changed. Off by default.
    public var commitAndPush = false
    /// Claude model alias for the job ("sonnet", "haiku", "opus").
    public var model = "sonnet"
    /// Extra shell commands the job may run, e.g. a lookup script ("python3 tools/graph.py").
    public var allowedCommands: [String] = []
    /// Folder-specific instructions (conventions, file layout, tone). Empty = generic defaults.
    public var instructions = ""
    /// Files the job may touch incidentally (caches) that should be reverted, never committed.
    public var revertPatterns = [".graph-cache.json"]

    public init() {}

    public var isEnabled: Bool { folder != nil }
}

public enum KnowledgeStatus: String, Codable, Sendable {
    case running, done, failed
}

/// What happened when a meeting was synced; stored on the meeting.
public struct KnowledgeState: Codable, Sendable, Hashable {
    public var status: KnowledgeStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var summary: String?
    public var changedFiles: [String] = []
    public var archivedFiles: [String] = []
    public var committed = false
    public var error: String?
    public var costUSD: Double?

    public init(status: KnowledgeStatus, startedAt: Date = .now) {
        self.status = status
        self.startedAt = startedAt
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

// MARK: - Prompt

public enum KnowledgePrompt {
    public static let defaultInstructions = """
        Follow the conventions this folder already uses (read its README, CLAUDE.md, AGENTS.md or \
        index notes first). Typical layout: one note per person and one per project.
        """

    public static func build(transcriptPath: String, archiveFolder: String?, settings: KnowledgeSettings,
                             date: String) -> String {
        var p = """
            You are running headless and unattended to update a personal knowledge base from one meeting \
            transcript, then exit. The current directory is the knowledge base.

            Transcript: \(transcriptPath)
            Meeting date: \(date)

            What to do:
            1. Read the transcript. Identify the meeting's project or client and the people in it.
            2. Look each person and project up before writing (search by full name, then partial name). \
            Never create a note for someone known only by a first name or as an unidentified speaker; \
            mention them in your final summary instead.
            3. Append durable facts only: decisions, commitments, roles, relationships, open threads, \
            preferences. Skip small talk. Use absolute dates (\(date)), newest first where the notes are \
            dated, and tag facts with their source as "(meeting, Undersay)".
            4. Speakers marked "recognised by voice, not confirmed" may be misattributed: record what was \
            said without pinning quotes on them.
            5. Edit conservatively: append to existing notes; never delete, rename or rewrite existing \
            content, and never touch files unrelated to this meeting. Create new notes sparingly, only \
            for clearly identified people or projects, using the folder's existing format.

            """
        if let archiveFolder {
            p += """
                6. Also save a cleaned, readable copy of the transcript as \
                \(archiveFolder)/<project-or-client-slug>/\(date)_<short-topic-slug>.txt (use "_internal" \
                for internal meetings with no project, "_unsorted" if unsure). Start it with 2–3 header \
                lines (date, project or client, participants).

                """
        }
        p += "Folder-specific instructions:\n\(settings.instructions.isEmpty ? defaultInstructions : settings.instructions)\n\n"
        p += "When you are done, reply with a short plain-text summary (at most 6 lines): which notes you "
            + "created or updated and the key facts added. Do not ask questions."
        return p
    }
}

// MARK: - Runner

/// Runs one sync at a time.
public actor KnowledgeRunner {
    public static let shared = KnowledgeRunner()

    public struct Outcome: Sendable {
        public var state: KnowledgeState
    }

    public func run(meeting: Meeting, meName: String, myVoicePrint: UUID?, settings: KnowledgeSettings,
                    timeout: TimeInterval = 20 * 60) async -> KnowledgeState {
        var state = KnowledgeState(status: .running)
        guard let folder = settings.folder else {
            state.status = .failed; state.error = "No knowledge folder is set."; return state
        }
        guard let cli = ClaudeCLI.locate() else {
            state.status = .failed
            state.error = "Claude Code isn't installed. Install it from claude.com/claude-code, then try again."
            return state
        }
        let status = await ClaudeCLI.status()
        guard status.loggedIn else {
            state.status = .failed
            state.error = "Claude Code isn't signed in. Run “claude /login” once in Terminal, then try again."
            return state
        }

        // Transcript goes to a private temp folder, never into the knowledge base.
        let tmp = FileManager.default.temporaryDirectory.appending(path: "undersay-knowledge-\(meeting.id.uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let transcript = tmp.appending(path: "transcript.md")
        do {
            try TranscriptExport.markdown(meeting, meName: meName, myVoicePrint: myVoicePrint)
                .write(to: transcript, atomically: true, encoding: .utf8)
        } catch {
            state.status = .failed; state.error = error.localizedDescription; return state
        }

        let repo = await Git.root(of: folder)
        let archiveRepo = settings.archiveFolder == nil ? nil : await Git.root(of: settings.archiveFolder!)
        if settings.commitAndPush {
            if let repo { _ = try? await Git.run(repo, ["pull", "--rebase", "--autostash", "--quiet"]) }
            if let archiveRepo { _ = try? await Git.run(archiveRepo, ["pull", "--rebase", "--autostash", "--quiet"]) }
        }
        let before = repo == nil ? [:] : await Git.dirty(repo!)
        let archiveBefore = archiveRepo == nil ? [:] : await Git.dirty(archiveRepo!)

        let day = ISO8601DateFormatter.string(from: meeting.createdAt, timeZone: .current, formatOptions: [.withFullDate])
        let prompt = KnowledgePrompt.build(transcriptPath: transcript.path, archiveFolder: settings.archiveFolder?.path,
                                           settings: settings, date: day)
        var tools = ["Read", "Glob", "Grep", "Edit", "Write"]
        tools += settings.allowedCommands.filter { !$0.isEmpty }.map { "Bash(\($0):*)" }
        var args = ["-p", prompt, "--output-format", "json", "--model", settings.model, "--no-session-persistence",
                    "--disable-slash-commands", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                    "--permission-mode", "acceptEdits", "--add-dir", tmp.path]
        if let a = settings.archiveFolder { args += ["--add-dir", a.path] }
        // Variadic flag: each tool is its own argument (shell patterns contain spaces). Keep it last.
        args += ["--allowedTools"] + tools

        do {
            let result = try await Shell.run(cli, args, cwd: folder, environment: ClaudeCLI.environment, timeout: timeout)
            if let data = Shell.firstJSONObject(result.stdout.data(using: .utf8) ?? Data()),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                state.summary = (json["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                state.costUSD = json["total_cost_usd"] as? Double
                if json["is_error"] as? Bool == true {
                    state.status = .failed
                    state.error = state.summary ?? "The job reported an error."
                }
            } else if result.status != 0 {
                state.status = .failed
                state.error = result.stderr.split(separator: "\n").last.map(String.init) ?? "Claude Code exited with \(result.status)."
            }
        } catch {
            state.status = .failed
            state.error = error.localizedDescription
        }

        // What did the job change? (Files dirty before the run are someone else's work: left alone.)
        if let repo {
            let after = await Git.dirty(repo)
            var changed = after.filter { before[$0.key] != $0.value }.map(\.key).sorted()
            let incidental = changed.filter { path in settings.revertPatterns.contains { path.hasSuffix($0) } }
            for path in incidental where before[path] == nil {
                _ = try? await Git.run(repo, ["checkout", "--", path])
            }
            changed.removeAll { incidental.contains($0) }
            if let archiveRepo, archiveRepo.standardizedFileURL.path.hasPrefix(repo.standardizedFileURL.path),
                archiveRepo != repo
            {
                let nested = archiveRepo.path.dropFirst(repo.path.count + 1)
                changed.removeAll { $0.hasPrefix(nested) }
            }
            state.changedFiles = changed
            if settings.commitAndPush, state.status != .failed, !changed.isEmpty {
                state.committed = await Git.commitAndPush(repo, files: changed, message: "Undersay: notes from “\(meeting.title)” (\(day))")
            }
        }
        if let archiveRepo {
            let after = await Git.dirty(archiveRepo)
            state.archivedFiles = after.filter { archiveBefore[$0.key] != $0.value }.map(\.key).sorted()
            if settings.commitAndPush, state.status != .failed, !state.archivedFiles.isEmpty {
                _ = await Git.commitAndPush(archiveRepo, files: state.archivedFiles,
                                            message: "Undersay: transcript “\(meeting.title)” (\(day))")
            }
        }
        if state.status == .running { state.status = .done }
        state.finishedAt = .now
        return state
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

    /// Commits exactly `files` (never `add -A`), then pushes. Returns true on success.
    static func commitAndPush(_ repo: URL, files: [String], message: String) async -> Bool {
        guard (try? await run(repo, ["add", "--"] + files))?.status == 0,
            (try? await run(repo, ["commit", "--quiet", "-m", message, "--"] + files))?.status == 0
        else { return false }
        return (try? await run(repo, ["push", "--quiet"]))?.status == 0
    }
}
