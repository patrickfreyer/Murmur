import MurmurCore
import SwiftUI

// MARK: - Design tokens

/// 4-pt spacing grid.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Horizontal gutter of every detail page.
    static let gutter: CGFloat = 32
    /// Comfortable reading width for transcripts and cards.
    static let readable: CGFloat = 880
}

/// Corner radii. Nested shapes are concentric: inner radius = outer radius − inset.
enum Radius {
    static let hero: CGFloat = 32
    static let card: CGFloat = 24
    static let tile: CGFloat = 20
    static let row: CGFloat = 16
    static let inset: CGFloat = 12

    static func inner(_ outer: CGFloat, inset: CGFloat) -> CGFloat { max(4, outer - inset) }
}

enum Theme {
    static let speakerColors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .indigo, .mint, .red]

    static func color(_ index: Int) -> Color { speakerColors[abs(index) % speakerColors.count] }

    /// Touch targets: Apple's 44 pt minimum.
    static let touchTarget: CGFloat = 44
    /// Height of primary buttons, so every row of controls lines up.
    static let buttonHeight: CGFloat = 36
}

extension Speaker {
    func color(voices: [VoicePrint]) -> Color {
        if let id = voicePrintID, let p = voices.first(where: { $0.id == id }) { return Theme.color(p.colorIndex) }
        return Theme.color(colorIndex)
    }
}

// MARK: - Depth

/// Layer 0: a soft, static wash of colour behind content. Frosted surfaces above blur it,
/// which gives the window depth without moving anything (no CPU cost while idle).
struct AmbientBackdrop: View {
    var tint: Color = .accentColor
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let a = scheme == .dark ? 0.30 : 0.20
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.55, 0], [1, 0],
                [0, 0.45], [0.62, 0.38], [1, 0.55],
                [0, 1], [0.45, 1], [1, 1],
            ],
            colors: [
                tint.opacity(a), .purple.opacity(a * 0.7), .clear,
                .indigo.opacity(a * 0.45), .clear, .pink.opacity(a * 0.35),
                .clear, .clear, .teal.opacity(a * 0.3),
            ]
        )
        .blur(radius: 40)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Layer 1: frosted content surface with a hairline highlight and a two-part soft shadow
/// (a wide ambient shadow plus a tight contact shadow), so cards float slightly above the backdrop.
struct Surface: ViewModifier {
    var radius: CGFloat = Radius.card
    var elevation: CGFloat = 1

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.04), .black.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.07 * elevation), radius: 18 * elevation, y: 10 * elevation)
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
            .containerShape(shape)
    }
}

extension View {
    func surface(radius: CGFloat = Radius.card, elevation: CGFloat = 1) -> some View {
        modifier(Surface(radius: radius, elevation: elevation))
    }

    /// Depth of field for scrolling content: items soften, dim and recede slightly as they
    /// approach the top or bottom edge, keeping the eye on what's in the middle.
    func depthOfField(maxBlur: CGFloat = 2.5) -> some View {
        scrollTransition(.interactive(timingCurve: .easeIn), axis: .vertical) { content, phase in
            let d = abs(phase.value)
            return content
                .opacity(1 - d * 0.55)
                .blur(radius: d * maxBlur)
                .scaleEffect(1 - d * 0.02, anchor: phase.value < 0 ? .bottom : .top)
        }
    }

    /// Focus state for transcript lines: out-of-focus lines dim and blur a touch.
    func focus(_ inFocus: Bool, dimmed: Bool) -> some View {
        opacity(dimmed && !inFocus ? 0.42 : 1)
            .blur(radius: dimmed && !inFocus ? 0.6 : 0)
            .animation(.smooth(duration: 0.35), value: inFocus)
            .animation(.smooth(duration: 0.35), value: dimmed)
    }

    /// Standard page frame: centred readable column with the page gutter.
    func pageColumn(maxWidth: CGFloat = Space.readable) -> some View {
        padding(.horizontal, Space.gutter)
            .frame(maxWidth: maxWidth + Space.gutter * 2)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Components

struct Avatar: View {
    var name: String
    var color: Color
    var size: CGFloat = 36
    var dashed = false

    var body: some View {
        ZStack {
            if dashed {
                Circle().fill(color.opacity(0.14))
                Circle().strokeBorder(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.25, dash: [3, 3]))
            } else {
                Circle().fill(color.gradient)
                // Specular rim: light from above, like the rest of the glass UI.
                Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)], startPoint: .top, endPoint: .center),
                    lineWidth: 0.75)
            }
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(dashed ? color : .white)
        }
        .frame(width: size, height: size)
        .shadow(color: dashed ? .clear : color.opacity(0.35), radius: size * 0.12, y: size * 0.06)
    }

    private var initials: String {
        let parts = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = parts.prefix(2).compactMap(\.first)
        if letters.isEmpty { return name.filter(\.isNumber).prefix(2).description }
        return String(letters).uppercased()
    }
}

/// Frosted card.
struct Card<Content: View>: View {
    var padding: CGFloat = Space.xl
    var radius: CGFloat = Radius.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(radius: radius)
    }
}

/// Section header used on every page: title left, optional action right, on one baseline.
struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            trailing
        }
        .padding(.horizontal, Space.xs)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// Square icon badge with concentric corners, used in rows.
struct IconBadge: View {
    var symbol: String
    var tint: Color = .secondary
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct LevelBar: View {
    var level: Float
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color.gradient)
                    .frame(width: max(8, geo.size.width * CGFloat(level)))
                    .shadow(color: color.opacity(0.5), radius: 4)
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 8)
    }
}

extension TimeInterval {
    var clock: String { Meeting.timestamp(self) }

    var humanDuration: String {
        let f = DateComponentsFormatter()
        f.allowedUnits = self >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: self) ?? ""
    }
}
