import AppKit
import SwiftUI
import UndersayCore

/// Settings → Knowledge: connect a notes folder that Undersay enriches after meetings.
struct KnowledgeSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Text("After a meeting, Claude Code reads the transcript and adds facts about the people and projects to your notes, following the folder's own conventions. It only appends; it never deletes.")
                    .font(.callout).foregroundStyle(.secondary)
                folderRow("Knowledge folder", url: model.knowledge.folder, placeholder: "Not connected") {
                    model.knowledge.folder = $0
                }
                folderRow("Transcript archive", url: model.knowledge.archiveFolder, placeholder: "Optional") {
                    model.knowledge.archiveFolder = $0
                }
            }
            if model.knowledge.isEnabled {
                Section("Behaviour") {
                    Toggle("Sync after each meeting, once speakers are named", isOn: $model.knowledge.autoSync)
                    Toggle("Commit and push the changed files", isOn: $model.knowledge.commitAndPush)
                    Text("Only files the sync changed are committed (never anything else in the folder), after pulling first.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Model", selection: $model.knowledge.model) {
                        Text("Sonnet (recommended)").tag("sonnet")
                        Text("Haiku (cheapest)").tag("haiku")
                        Text("Opus (most careful)").tag("opus")
                    }
                    TextField("Allowed commands (separate with ;)", text: Binding(
                        get: { model.knowledge.allowedCommands.joined(separator: "; ") },
                        set: { model.knowledge.allowedCommands = $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                        .font(.system(.body, design: .monospaced))
                }
                Section("Folder instructions") {
                    TextEditor(text: $model.knowledge.instructions)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 130)
                    Text("Where notes live, their format and any rules. Leave empty to let Claude read the folder's own README or CLAUDE.md.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Claude Code") {
                cliRow
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshCLIStatus() }
    }

    @ViewBuilder
    private var cliRow: some View {
        if let s = model.cliStatus {
            if s.path == nil {
                Label("Not installed. Get it at claude.com/claude-code.", systemImage: "xmark.circle.fill").foregroundStyle(.orange)
            } else if !s.loggedIn {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Installed but not signed in", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Run `claude /login` once in Terminal.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("Signed in (\(s.method ?? "account")) · \(s.version ?? "")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Button("Check again") { Task { await model.refreshCLIStatus() } }
        } else {
            ProgressView().controlSize(.small)
        }
        Text("Each sync is one Claude Code run of about 20 seconds; on a claude.ai plan it counts toward your usage.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func folderRow(_ title: String, url: URL?, placeholder: String, set: @escaping (URL?) -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? placeholder)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = url
                    if panel.runModal() == .OK { set(panel.url) }
                }
                if url != nil { Button("Clear") { set(nil) } }
            }
        }
    }
}

/// Meeting detail: what the knowledge sync did (or will do) for this meeting.
struct KnowledgeCard: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting

    var body: some View {
        if model.knowledge.isEnabled {
            let state = meeting.knowledge
            let running = model.knowledgeRunning.contains(meeting.id) || state?.status == .running
            VStack(alignment: .leading, spacing: Space.m) {
                HStack {
                    Label("Knowledge", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                    Spacer()
                    if running {
                        ProgressView().controlSize(.small)
                        Text("Updating your notes…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(state == nil ? "Sync now" : "Run again") { model.syncKnowledge(meeting.id) }
                            .buttonStyle(.glass)
                    }
                }
                if let state, !running {
                    if state.status == .failed {
                        Label(state.error ?? "The sync failed.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout)
                    } else {
                        if let summary = state.summary {
                            SummaryText(markdown: summary).font(.callout)
                        }
                        let files = state.changedFiles + state.archivedFiles
                        if !files.isEmpty {
                            FlowLayout(spacing: Space.s) {
                                ForEach(files, id: \.self) { f in
                                    Button {
                                        reveal(f, archived: state.archivedFiles.contains(f))
                                    } label: {
                                        Label((f as NSString).lastPathComponent, systemImage: "doc.text")
                                            .font(.caption)
                                            .padding(.horizontal, Space.s + 2).padding(.vertical, 4)
                                            .background(.quaternary.opacity(0.6), in: .capsule)
                                    }
                                    .buttonStyle(.plain)
                                    .help(f)
                                }
                            }
                        }
                        HStack(spacing: Space.s) {
                            Text(state.finishedAt.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "")
                            if state.committed { Text("· committed and pushed") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                } else if state == nil, !running {
                    Text(TranscriptExport.speakersNamed(meeting)
                         ? (model.knowledge.autoSync ? "Syncs to your notes shortly." : "Ready to sync to your notes.")
                         : "Name the speakers first; then it syncs who said what to your notes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(Space.xl)
            .surface(radius: Radius.card, elevation: 0.6)
        }
    }

    private func reveal(_ path: String, archived: Bool) {
        let base = archived ? model.knowledge.archiveFolder : model.knowledge.folder
        guard let base else { return }
        // Paths are relative to the git repo root, which may sit above the chosen folder.
        Task {
            let root = await Git.root(of: base) ?? base
            NSWorkspace.shared.activateFileViewerSelecting([root.appending(path: path)])
        }
    }
}
