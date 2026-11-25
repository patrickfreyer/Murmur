import AppKit
import MurmurCore
import SwiftUI

/// Panel that floats above everything without ever taking focus from the app you're typing in.
final class FloatingPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The dictation pill at the bottom of the screen.
@MainActor
final class HUDController {
    private let panel = FloatingPanel(size: CGSize(width: 340, height: 96))
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let host = NSHostingView(rootView: HUDView().environment(model))
        host.sizingOptions = []
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = model.dictation.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        if model.dictation.state == .idle {
            // Let the SwiftUI exit animation finish before ordering out.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(260))
                if model.dictation.state == .idle { panel.orderOut(nil) }
            }
        } else if !panel.isVisible {
            position()
            panel.orderFrontRegardless()
        }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 18))
    }
}

struct HUDView: View {
    @Environment(AppModel.self) private var model

    private let pillHeight: CGFloat = 52
    private let node: CGFloat = 28
    private let stopSize: CGFloat = 36

    var body: some View {
        let state = model.dictation.state
        VStack {
            Spacer(minLength: 0)
            if state != .idle {
                pill(state)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.5, anchor: .bottom).combined(with: .opacity)
                            .combined(with: .offset(y: 12)),
                        removal: .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: phaseKey(state))
    }

    private func phaseKey(_ s: DictationController.State) -> Int {
        switch s {
        case .idle: 0
        case .listening(false): 1
        case .listening(true): 2
        case .transcribing: 3
        case .inserted: 4
        case .failed: 5
        }
    }

    @ViewBuilder
    private func pill(_ state: DictationController.State) -> some View {
        let locked: Bool = { if case .listening(true) = state { return true }; return false }()
        HStack(spacing: Space.s + 2) {
            switch state {
            case .listening(let handsFree):
                leadingNode(locked: handsFree)
                // Fixed widths: every element has its own lane, so nothing can overlap.
                WaveformBars(levels: model.dictation.levels, bars: handsFree ? 22 : 30)
                    .frame(width: WaveformBars.width(bars: handsFree ? 22 : 30), height: 26)
                if handsFree {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsed)
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(countsDown: false))
                    }
                    .frame(width: 40, alignment: .trailing)
                    Button {
                        model.dictation.finish()
                    } label: {
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(.white)
                            .frame(width: 12, height: 12)
                            .frame(width: stopSize, height: stopSize)
                            .background(Circle().fill(Color.red.gradient))
                            .shadow(color: .red.opacity(0.45), radius: 6, y: 2)
                    }
                    .buttonStyle(PressScaleStyle())
                    .help("Finish (or tap fn)")
                }
            case .transcribing:
                leadingNode(locked: false)
                ShimmerText("Transcribing")
                    .frame(width: 118, alignment: .leading)
            case .inserted(let text):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .symbolEffect(.bounce, value: text)
                    .frame(width: node, height: node)
                Text(preview(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 210, alignment: .leading)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: node, height: node)
                Text(message).font(.callout).lineLimit(2).frame(maxWidth: 230, alignment: .leading)
            case .idle:
                EmptyView()
            }
        }
        // Concentric insets: a circle of diameter d sits (height − d) / 2 from the capsule's end.
        .padding(.leading, (pillHeight - node) / 2)
        .padding(.trailing, locked ? (pillHeight - stopSize) / 2 : 18)
        .frame(height: pillHeight)
        .glassEffect(.regular.tint(locked ? Color.accentColor.opacity(0.12) : .clear), in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
        .padding(.bottom, 14)
    }

    /// The app you're dictating into, which turns into a lock badge when hands-free is on.
    @ViewBuilder
    private func leadingNode(locked: Bool) -> some View {
        ZStack {
            if locked {
                Circle().fill(Color.accentColor.gradient)
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            } else if let icon = model.dictation.targetAppIcon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Circle().fill(.quaternary)
                Image(systemName: "mic.fill").font(.system(size: 12, weight: .semibold))
            }
        }
        .frame(width: node, height: node)
        .shadow(color: locked ? Color.accentColor.opacity(0.5) : .clear, radius: 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: locked)
    }

    private var elapsed: String {
        guard let s = model.dictation.startedAt else { return "0:00" }
        return Meeting.timestamp(Date.now.timeIntervalSince(s))
    }

    private func preview(_ text: String) -> String {
        text.count > 34 ? "“" + text.prefix(32) + "…”" : "“" + text + "”"
    }
}

/// Mirrored capsule bars with a soft accent-to-violet gradient; newest audio on the right.
struct WaveformBars: View {
    var levels: [Float]
    var bars: Int

    static let barWidth: CGFloat = 3
    static let gap: CGFloat = 2.5

    static func width(bars: Int) -> CGFloat { CGFloat(bars) * barWidth + CGFloat(bars - 1) * gap }

    var body: some View {
        let recent = Array(levels.suffix(bars))
        Canvas { ctx, size in
            let gradient = Gradient(colors: [Color.accentColor, .purple, .pink])
            for (i, level) in recent.enumerated() {
                // Older bars fade slightly: the waveform "flows" into the pill.
                let x = CGFloat(i) * (Self.barWidth + Self.gap)
                let h = max(3, size.height * CGFloat(min(1, level * 1.15)))
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: Self.barWidth, height: h)
                let age = Double(recent.count - 1 - i) / Double(max(1, recent.count - 1))
                ctx.opacity = 1 - age * 0.45
                ctx.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                         with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            }
        }
        .animation(.linear(duration: 0.05), value: recent)
    }
}

/// Text with a light sweep moving across it.
struct ShimmerText: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .overlay {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    LinearGradient(
                        stops: [.init(color: .clear, location: t - 0.25), .init(color: .white, location: t),
                                .init(color: .clear, location: t + 0.25)],
                        startPoint: .leading, endPoint: .trailing)
                }
                .mask(Text(text).font(.callout.weight(.medium)))
            }
    }
}

/// Buttons that dip under your finger.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
