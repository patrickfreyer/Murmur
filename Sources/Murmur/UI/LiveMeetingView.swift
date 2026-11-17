import MurmurCore
import SwiftUI

struct LiveMeetingView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDiscard = false

    var body: some View {
        let recorder = model.recorder
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                if let start = recorder.startedAt {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .font(.system(size: 64, weight: .light, design: .rounded))
                        .monospacedDigit()
                }
                HStack(spacing: 28) {
                    meter("You", symbol: "mic.fill", level: recorder.micLevel, color: .accentColor)
                    meter("Call audio", symbol: "speaker.wave.2.fill", level: recorder.systemLevel, color: .purple)
                }
                .frame(maxWidth: 520)
                if let err = recorder.systemAudioError {
                    Label("System audio not captured: \(err)", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                HStack(spacing: 14) {
                    Button(role: .destructive) {
                        confirmDiscard = true
                    } label: {
                        Label("Discard", systemImage: "trash").frame(minHeight: 34)
                    }
                    .buttonStyle(.glass)
                    Button {
                        model.stopMeeting()
                    } label: {
                        Label("Stop & transcribe", systemImage: "stop.fill").frame(minWidth: 200, minHeight: 34)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                }
                .controlSize(.extraLarge)
            }
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if recorder.liveLines.isEmpty {
                            Text("Live transcript appears here as people talk. Speakers are identified when you stop.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                        ForEach(recorder.liveLines) { line in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: line.track == .mic ? "mic.fill" : "speaker.wave.2.fill")
                                    .foregroundStyle(line.track == .mic ? Color.accentColor : .purple)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.start.clock).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(line.text).font(.title3).textSelection(.enabled)
                                }
                            }
                            .id(line.id)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: recorder.liveLines.count) {
                    if let last = recorder.liveLines.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .navigationTitle("Recording")
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard) {
            Button("Discard Recording", role: .destructive) { model.recorder.cancel(store: model.meetings) }
        }
    }

    private func meter(_ title: String, symbol: String, level: Float, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            LevelBar(level: level, color: color)
        }
    }
}
