import UndersayCore
import SwiftUI

struct LiveMeetingView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDiscard = false

    var body: some View {
        let recorder = model.recorder
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Space.xl) {
                    controlCard(recorder)
                    transcript(recorder)
                }
                .padding(.vertical, Space.xl)
                .pageColumn(maxWidth: 820)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .onChange(of: recorder.liveLines.count) {
                if let last = recorder.liveLines.last {
                    withAnimation(.smooth) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background { AmbientBackdrop(tint: .red) }
        .navigationTitle("Recording")
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard) {
            Button("Discard Recording", role: .destructive) { model.recorder.cancel(store: model.meetings) }
        }
    }

    private func controlCard(_ recorder: MeetingRecorder) -> some View {
        VStack(spacing: Space.xl) {
            HStack(spacing: Space.s) {
                Circle().fill(.red).frame(width: 8, height: 8)
                    .shadow(color: .red.opacity(0.8), radius: 4)
                    .phaseAnimator([1.0, 0.35]) { c, o in c.opacity(o) } animation: { _ in .easeInOut(duration: 0.9) }
                Text("REC").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
            }
            if let start = recorder.startedAt {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .font(.system(size: 64, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            HStack(spacing: Space.xxl) {
                meter("You", symbol: "mic.fill", level: recorder.micLevel, color: .accentColor)
                meter("Call audio", symbol: "speaker.wave.2.fill", level: recorder.systemLevel, color: .purple)
            }
            .frame(maxWidth: 520)
            if let err = recorder.systemAudioError {
                Label("System audio not captured: \(err)", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack(spacing: Space.m) {
                Button(role: .destructive) {
                    confirmDiscard = true
                } label: {
                    Label("Discard", systemImage: "trash").frame(minWidth: 110, minHeight: Theme.buttonHeight)
                }
                .buttonStyle(.glass)
                Button {
                    model.stopMeeting()
                } label: {
                    Label("Stop & transcribe", systemImage: "stop.fill")
                        .frame(minWidth: 200, minHeight: Theme.buttonHeight)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
            }
            .controlSize(.large)
        }
        .padding(.vertical, Space.xxl)
        .padding(.horizontal, Space.xl)
        .frame(maxWidth: .infinity)
        .surface(radius: Radius.hero, elevation: 1.2)
    }

    @ViewBuilder
    private func transcript(_ recorder: MeetingRecorder) -> some View {
        if recorder.liveLines.isEmpty {
            Text("The live transcript appears here as people talk. Speakers are identified when you stop.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.top, Space.xl)
        } else {
            LazyVStack(alignment: .leading, spacing: Space.l) {
                let lines = recorder.liveLines
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                    // Depth of field by recency: the newest line is in focus, older ones recede.
                    let age = lines.count - 1 - i
                    LiveLineRow(line: line)
                        .opacity(age == 0 ? 1 : max(0.38, 0.9 - Double(age) * 0.12))
                        .blur(radius: age == 0 ? 0 : min(1.2, Double(age) * 0.25))
                        .animation(.smooth(duration: 0.5), value: age)
                        .depthOfField()
                        .id(line.id)
                }
            }
            .padding(.horizontal, Space.s)
        }
    }

    private func meter(_ title: String, symbol: String, level: Float, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label(title, systemImage: symbol).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            LevelBar(level: level, color: color)
        }
    }
}

private struct LiveLineRow: View {
    let line: LiveLine

    var body: some View {
        let color: Color = line.track == .mic ? .accentColor : .purple
        HStack(alignment: .firstTextBaseline, spacing: Space.m + 2) {
            Image(systemName: line.track == .mic ? "mic.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.14), in: .circle)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(line.start.clock).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(line.text).font(.title3).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
