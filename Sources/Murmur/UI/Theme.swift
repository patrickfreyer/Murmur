import MurmurCore
import SwiftUI

enum Theme {
    static let speakerColors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .indigo, .mint, .red]

    static func color(_ index: Int) -> Color { speakerColors[abs(index) % speakerColors.count] }

    /// Touch targets: Apple's 44 pt minimum, a bit more for primary actions.
    static let touchTarget: CGFloat = 44
}

extension Speaker {
    func color(voices: [VoicePrint]) -> Color {
        if let id = voicePrintID, let p = voices.first(where: { $0.id == id }) { return Theme.color(p.colorIndex) }
        return Theme.color(colorIndex)
    }
}

struct Avatar: View {
    var name: String
    var color: Color
    var size: CGFloat = 36
    var dashed = false

    var body: some View {
        ZStack {
            Circle().fill(color.gradient.opacity(dashed ? 0.25 : 1))
            if dashed {
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(dashed ? color : .white)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let parts = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = parts.prefix(2).compactMap(\.first)
        if letters.isEmpty { return name.filter(\.isNumber).prefix(2).description }
        return String(letters).uppercased()
    }
}

/// Rounded glass card used throughout.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 22))
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
                    .frame(width: max(6, geo.size.width * CGFloat(level)))
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
