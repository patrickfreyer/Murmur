import AppKit
import SwiftUI
import UndersayCore

/// Edit one automation: which agent, where it works, what it should do, and when.
struct AutomationView: View {
    @Environment(AppModel.self) private var model
    let automationID: UUID
    @State private var runOn: UUID?
    @State private var expanded: Set<UUID> = []

    private var index: Int? { model.automations.firstIndex { $0.id == automationID } }

    var body: some View {
        if let i = index {
            @Bindable var model = model
            let a = model.automations[i]
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    HStack(spacing: Space.m) {
                        Image(systemName: a.agent.symbol)
                            .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.gradient))
                        TextField("Name", text: $model.automations[i].name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Toggle("Enabled", isOn: $model.automations[i].enabled).toggleStyle(.switch).labelsHidden()
                    }

                    card("Agent") {
                        HStack(spacing: Space.s) {
                            ForEach(AgentKind.allCases) { kind in
                                agentChoice(kind, selected: a.agent == kind) { model.automations[i].agent = kind }
                            }
                        }
                        if let info = model.agents.first(where: { $0.kind == a.agent }) {
                            agentStatus(info)
                        }
                        if a.agent == .custom {
                            TextField("Command, e.g. my-agent --prompt {prompt}", text: $model.automations[i].command)
                                .font(.system(.body, design: .monospaced))
                            Text("{prompt} and {transcript} are filled in. Runs in zsh with your PATH.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            TextField("Model (optional, e.g. sonnet)", text: Binding(
                                get: { model.automations[i].model ?? "" },
                                set: { model.automations[i].model = $0.isEmpty ? nil : $0 }))
                        }
                    }

                    card("Instructions") {
                        TextEditor(text: $model.automations[i].prompt)
                            .font(.system(size: 13))
                            .frame(minHeight: 140)
                            .scrollContentBackground(.hidden)
                            .padding(Space.s)
                            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: Radius.inset, style: .continuous))
                        Text("Plain words or a skill, e.g. “Use the project-context skill to add today's decisions.” Undersay passes the transcript (named or not) and asks for a short summary at the end. You can use {title}, {date} and {transcript}.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        FlowLayout(spacing: Space.s) {
                            example("Meeting note", "Write a meeting note in this folder: date, people, decisions, action items as checkboxes, and a short summary. Link people as [[Name]].", i)
                            example("Update projects", "Use the project-context skill to add today's decisions, risks and next steps to the matching project notes. Create nothing if no project matches.", i)
                            example("Action items", "List every action item with its owner and due date, and append them to tasks.md in this folder.", i)
                        }
                    }

                    card("Where and when") {
                        LabeledContent("Works in") {
                            HStack {
                                Text(a.folder.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "Home folder")
                                    .lineLimit(1).truncationMode(.middle)
                                Button("Choose…") {
                                    let panel = NSOpenPanel()
                                    panel.canChooseDirectories = true
                                    panel.canChooseFiles = false
                                    if panel.runModal() == .OK { model.automations[i].folder = panel.url }
                                }
                                if a.folder != nil { Button("Clear") { model.automations[i].folder = nil } }
                            }
                        }
                        Toggle("Run after every meeting", isOn: $model.automations[i].runAutomatically)
                        Toggle("Allow shell commands", isOn: $model.automations[i].allowShell)
                        Text("File edits are always allowed in the folder above. Some skills also need to run commands; only allow that for instructions you trust.")
                            .font(.caption).foregroundStyle(.secondary)
                        Label(a.agent == .codex
                              ? "Codex sends the transcript to OpenAI. Everything else in Undersay stays on your Mac."
                              : a.agent == .claudeCode
                              ? "Claude Code sends the transcript to Anthropic. Everything else in Undersay stays on your Mac."
                              : "Your command decides where the transcript goes.",
                              systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    card("Run now") {
                        HStack {
                            Picker("Meeting", selection: $runOn) {
                                ForEach(model.meetings.meetings.filter { $0.status == .ready }.prefix(20)) { m in
                                    Text("\(m.title) · \(m.createdAt.formatted(date: .abbreviated, time: .omitted))").tag(Optional(m.id))
                                }
                            }
                            .labelsHidden()
                            Button {
                                if let id = runOn { model.run(model.automations[i], on: id) }
                            } label: {
                                Label("Run", systemImage: "play.fill")
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(runOn == nil)
                        }
                    }

                    runs(a)
                }
                .padding(.vertical, Space.xl)
                .pageColumn(maxWidth: 820)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .background { AmbientBackdrop(tint: .indigo) }
            .navigationTitle(a.name)
            .onAppear { runOn = runOn ?? model.meetings.meetings.first { $0.status == .ready }?.id }
            .task { await model.refreshAgents() }
        }
    }

    // MARK: Pieces

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(title).font(.headline)
            content()
        }
        .padding(Space.xl - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Radius.card, elevation: 0.6)
    }

    private func agentChoice(_ kind: AgentKind, selected: Bool, action: @escaping () -> Void) -> some View {
        let info = model.agents.first { $0.kind == kind }
        let available = kind == .custom || (info?.installed ?? false)
        return Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: kind.symbol)
                VStack(alignment: .leading, spacing: 0) {
                    Text(kind.title).font(.callout.weight(.semibold))
                    Text(kind == .custom ? "Any command" : available ? "Installed" : "Not installed")
                        .font(.caption).foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                }
            }
            .foregroundStyle(selected ? .white : .primary)
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quaternary.opacity(0.5))))
            .opacity(available || selected ? 1 : 0.55)
        }
        .buttonStyle(PressScaleStyle(scale: 0.97))
    }

    @ViewBuilder
    private func agentStatus(_ info: AgentInfo) -> some View {
        if !info.installed {
            Label(info.detail ?? "Not installed on this Mac.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        } else if info.signedIn == false {
            Label(info.kind == .codex ? "Installed but not signed in. Run “codex login” in Terminal."
                                      : "Installed but not signed in. Run “claude /login” in Terminal.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        } else {
            Label("Ready" + (info.detail.map { " · \($0)" } ?? ""), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).lineLimit(1)
        }
    }

    private func example(_ title: String, _ text: String, _ i: Int) -> some View {
        Button {
            model.automations[i].prompt = text
            if model.automations[i].name == "New automation" { model.automations[i].name = title }
        } label: {
            Label(title, systemImage: "text.badge.plus").font(.caption)
                .padding(.horizontal, Space.m).padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func runs(_ a: Automation) -> some View {
        let runs = model.meetings.meetings.compactMap { m in m.automationRuns?.first { $0.automationID == a.id }.map { (m, $0) } }
            .sorted { $0.1.startedAt > $1.1.startedAt }
        card("Recent runs") {
            if runs.isEmpty {
                Text(a.runAutomatically ? "Runs after your next meeting." : "Use Run now, or turn on “Run after every meeting”.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(runs.prefix(10), id: \.0.id) { meeting, run in
                RunRow(meeting: meeting, run: run, expanded: expanded.contains(meeting.id)) {
                    withAnimation(.smooth) {
                        if expanded.contains(meeting.id) { expanded.remove(meeting.id) } else { expanded.insert(meeting.id) }
                    }
                }
                if meeting.id != runs.prefix(10).last?.0.id { Divider() }
            }
        }
    }
}

/// One automation's latest run on one meeting.
struct RunRow: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    let run: AutomationRun
    var expanded: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button(action: toggle) {
                HStack(spacing: Space.s + 2) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(meeting.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded { RunDetail(run: run, folder: model.automations.first { $0.id == run.automationID }?.folder) }
        }
    }

    private var subtitle: String {
        var parts = [run.startedAt.formatted(.relative(presentation: .named))]
        if !run.changedFiles.isEmpty { parts.append("\(run.changedFiles.count) file\(run.changedFiles.count == 1 ? "" : "s") changed") }
        if let c = run.costUSD { parts.append(String(format: "$%.2f", c)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch run.status {
        case .running: ProgressView().controlSize(.small).frame(width: 18)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

struct RunDetail: View {
    let run: AutomationRun
    let folder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let error = run.error, run.status == .failed {
                Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let summary = run.summary {
                SummaryText(markdown: summary).font(.callout)
            }
            if !run.changedFiles.isEmpty {
                FlowLayout(spacing: Space.s) {
                    ForEach(run.changedFiles, id: \.self) { f in
                        Button {
                            Task {
                                let base = folder ?? FileManager.default.homeDirectoryForCurrentUser
                                let root = await Git.root(of: base) ?? base
                                NSWorkspace.shared.activateFileViewerSelecting([root.appending(path: f)])
                            }
                        } label: {
                            Label((f as NSString).lastPathComponent, systemImage: "doc.text").font(.caption)
                                .padding(.horizontal, Space.s + 2).padding(.vertical, 4)
                                .background(.quaternary.opacity(0.6), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .help(f)
                    }
                }
            }
        }
        .padding(.leading, 28)
    }
}

/// Meeting detail: each enabled automation, its latest run on this meeting, and a Run button.
struct AutomationsCard: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let active = model.automations.filter(\.enabled)
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                Label("Automations", systemImage: "bolt.horizontal").font(.headline)
                ForEach(active) { a in
                    let run = meeting.automationRuns?.first { $0.automationID == a.id }
                    let running = model.automationsRunning.contains(model.key(meeting.id, a.id))
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(spacing: Space.s + 2) {
                            Image(systemName: a.agent.symbol).foregroundStyle(.secondary).frame(width: 18)
                            Button {
                                withAnimation(.smooth) {
                                    if expanded.contains(a.id) { expanded.remove(a.id) } else { expanded.insert(a.id) }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.name).font(.callout.weight(.semibold))
                                    Text(status(run, running: running)).font(.caption).foregroundStyle(run?.status == .failed ? .orange : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            if running {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(run == nil ? "Run" : "Run again") { model.run(a, on: meeting.id) }.buttonStyle(.glass)
                            }
                        }
                        if expanded.contains(a.id), let run, !running {
                            RunDetail(run: run, folder: a.folder)
                        }
                    }
                }
            }
            .padding(Space.xl)
            .surface(radius: Radius.card, elevation: 0.6)
        }
    }

    private func status(_ run: AutomationRun?, running: Bool) -> String {
        if running { return "Running…" }
        guard let run else { return "Hasn't run on this meeting" }
        switch run.status {
        case .failed: return "Failed · \(run.error ?? "")"
        case .done: return "Done \(run.finishedAt?.formatted(.relative(presentation: .named)) ?? "")" + (run.changedFiles.isEmpty ? "" : " · \(run.changedFiles.count) files")
        case .running: return "Running…"
        }
    }
}
