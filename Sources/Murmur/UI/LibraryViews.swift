import AppKit
import MurmurCore
import SwiftUI

struct DictationsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var confirmClear = false

    var body: some View {
        let items = model.dictations.items.filter {
            query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)
        }
        Group {
            if model.dictations.items.isEmpty {
                ContentUnavailableView(
                    "No dictations yet", systemImage: "text.bubble",
                    description: Text("Hold fn anywhere and start talking. Everything you dictate is kept here."))
            } else {
                List {
                    ForEach(items) { d in
                        DictationRow(dictation: d)
                            .depthOfField()
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: Space.s, leading: Space.gutter, bottom: Space.s, trailing: Space.gutter))
                            .swipeActions {
                                Button(role: .destructive) {
                                    model.dictations.delete(d.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .all)
            }
        }
        .background { AmbientBackdrop(tint: .teal) }
        .navigationTitle("Dictation")
        .searchable(text: $query, placement: .toolbar)
        .toolbar {
            if !model.dictations.items.isEmpty {
                Button("Clear history", systemImage: "trash") { confirmClear = true }
            }
        }
        .confirmationDialog("Clear all dictation history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.dictations.clear() }
        }
    }
}

struct DictationRow: View {
    let dictation: Dictation
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 6) {
                Text(dictation.text)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let app = dictation.appName { Text(app) }
                    Text("·")
                    Text(dictation.createdAt, format: .relative(presentation: .named))
                    Text("·")
                    Text("\(String(format: "%.1f", dictation.duration)) s audio → \(Int(dictation.processingTime * 1000)) ms")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(dictation.text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Copy")
        }
        .padding(.vertical, Space.l)
        .padding(.leading, Space.l + 4)
        .padding(.trailing, Space.m)
        .surface(radius: Radius.tile, elevation: 0.5)
    }
}

struct VoicesView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: VoicePrint?
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Card {
                    HStack(alignment: .center, spacing: Space.l) {
                        IconBadge(symbol: "person.wave.2.fill", tint: .accentColor)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Voice prints stay on this Mac").font(.headline)
                            Text("Name a speaker once in any transcript and Murmur recognises them in every meeting after — and in older ones too. Your own voice is learned quietly from your dictations.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if model.voices.prints.isEmpty {
                    ContentUnavailableView(
                        "No voices yet", systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Tap a speaker in a meeting transcript to name them."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: Space.l)], spacing: Space.l) {
                        ForEach(model.voices.prints.sorted { ($0.isMe ? 0 : 1, $0.name) < ($1.isMe ? 0 : 1, $1.name) }) { p in
                            voiceCard(p)
                        }
                    }
                }
            }
            .padding(.vertical, Space.xl)
            .pageColumn(maxWidth: 980)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background { AmbientBackdrop(tint: .indigo) }
        .navigationTitle("Voices")
        .alert("Rename voice", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let r = renaming {
                    model.voices.rename(r.id, to: newName)
                    renameInMeetings(r.id, to: newName)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func voiceCard(_ p: VoicePrint) -> some View {
        let meetings = model.meetings.meetings.filter { $0.speakers.contains { $0.voicePrintID == p.id } }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Avatar(name: p.name, color: Theme.color(p.colorIndex), size: 48)
                Spacer()
                if p.isMe {
                    Text("You").font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.18), in: .capsule)
                        .foregroundStyle(Color.accentColor)
                }
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        newName = p.name
                        renaming = p
                    }
                    if !p.isMe {
                        Button("This is me", systemImage: "person.crop.circle") { model.voices.setMe(p.id) }
                    }
                    Divider()
                    Button("Forget voice", systemImage: "trash", role: .destructive) { model.voices.delete(p.id) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 36, height: 36)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .menuIndicator(.hidden)
            }
            Text(p.name).font(.title3.weight(.semibold))
            Text("\(p.sampleCount) sample\(p.sampleCount == 1 ? "" : "s") · in \(meetings) meeting\(meetings == 1 ? "" : "s")")
                .font(.callout).foregroundStyle(.secondary)
            ProgressView(value: min(1, Double(p.sampleCount) / 8))
                .tint(Theme.color(p.colorIndex))
                .help("Recognition gets more reliable with more samples")
        }
        .padding(Space.xl)
        .surface(radius: Radius.card, elevation: 0.7)
    }

    private func renameInMeetings(_ id: UUID, to name: String) {
        for m in model.meetings.meetings where m.speakers.contains(where: { $0.voicePrintID == id }) {
            model.meetings.update(m.id) { m in
                for i in m.speakers.indices where m.speakers[i].voicePrintID == id { m.speakers[i].name = name }
            }
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform").font(.title3).foregroundStyle(Color.accentColor)
                Text("Murmur").font(.headline)
                Spacer()
                statusText.font(.caption).foregroundStyle(.secondary)
            }

            Button {
                model.toggleMeeting()
            } label: {
                HStack {
                    Image(systemName: model.recorder.isRecording ? "stop.fill" : "record.circle")
                    if model.recorder.isRecording, let s = model.recorder.startedAt {
                        Text("Stop recording")
                        Spacer()
                        Text(timerInterval: s...Date.distantFuture, countsDown: false).monospacedDigit()
                    } else {
                        Text("Record meeting")
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(model.recorder.isRecording ? .red : .accentColor)
            .controlSize(.large)

            Button {
                model.dictation.toggleHandsFree()
            } label: {
                HStack {
                    Image(systemName: "mic.fill")
                    Text("Dictate hands-free")
                    Spacer()
                    Text("fn fn").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            if let last = model.dictations.items.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last dictation").font(.caption).foregroundStyle(.secondary)
                    Text(last.text).lineLimit(3).font(.callout)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                .onTapGesture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(last.text, forType: .string)
                }
            }

            Divider()
            HStack {
                Button("Open Murmur") {
                    NSApp.activate()
                    openWindow(id: "main")
                }
                Spacer()
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder
    private var statusText: some View {
        switch model.modelStatus {
        case .ready: Text(model.fnMonitorRunning ? "fn ready" : "Needs permission")
        case .loading(_, let f): Text("Loading \(Int(f * 100))%")
        case .failed: Text("Model error")
        case .idle: Text("Starting…")
        }
    }
}
