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

    var body: some View {
        let state = model.dictation.state
        VStack {
            Spacer(minLength: 0)
            if state != .idle {
                pill(state)
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: state)
    }

    @ViewBuilder
    private func pill(_ state: DictationController.State) -> some View {
        HStack(spacing: 12) {
            switch state {
            case .listening(let handsFree):
                if let icon = model.dictation.targetAppIcon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                }
                Waveform(levels: model.dictation.levels)
                    .frame(width: handsFree ? 120 : 150, height: 26)
                if handsFree {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsed).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button {
                        model.dictation.finish()
                    } label: {
                        Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(.red)
                }
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing").font(.callout.weight(.medium))
            case .inserted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                Text("Inserted").font(.callout.weight(.medium))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.callout).lineLimit(2)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 8)
    }

    private var elapsed: String {
        guard let s = model.dictation.startedAt else { return "0:00" }
        return Meeting.timestamp(Date.now.timeIntervalSince(s))
    }
}

/// Mirrored bar waveform driven by recent mic levels.
struct Waveform: View {
    var levels: [Float]
    var color: Color = .primary

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let spacing: CGFloat = 3
            let width = max(2, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule()
                        .fill(color.opacity(0.35 + 0.65 * Double(levels[i])))
                        .frame(width: width, height: max(3, geo.size.height * CGFloat(levels[i])))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.linear(duration: 0.05), value: levels)
        }
    }
}

// MARK: - Floating dictation bubble (touch screens)

/// A small draggable mic button at the screen edge. Tapping it starts hands-free dictation into
/// whatever field has focus — handy when you're using the touch screen, not the keyboard.
@MainActor
final class BubbleController {
    private let panel = FloatingPanel(size: CGSize(width: 64, height: 64))
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        panel.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: BubbleView().environment(model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
        if let saved = UserDefaults.standard.string(forKey: "bubbleOrigin") {
            panel.setFrameOrigin(NSPointFromString(saved))
        } else if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: visible.maxX - 84, y: visible.midY - 32))
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
            [weak panel] _ in
            guard let panel else { return }
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "bubbleOrigin")
        }
    }

    func setVisible(_ visible: Bool) {
        visible ? panel.orderFrontRegardless() : panel.orderOut(nil)
    }
}

struct BubbleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let listening: Bool = {
            if case .listening = model.dictation.state { return true }
            return false
        }()
        Button {
            model.dictation.toggleHandsFree()
        } label: {
            Image(systemName: listening ? "stop.fill" : "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(listening ? .red : nil)
        .frame(width: 64, height: 64)
        .help("Tap to dictate into the focused field")
    }
}
