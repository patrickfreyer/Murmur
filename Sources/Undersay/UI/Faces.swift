import SwiftUI

/// Deterministic traits for a little illustrated face, derived from a name (stable across launches,
/// unlike `hashValue`).
struct FaceTraits {
    enum Hair: CaseIterable { case none, short, long, bun, curly, sidePart, buzz }

    let skin: Color
    let skinShade: Color
    let hair: Color
    let hairStyle: Hair
    let glasses: Bool
    let shirt: Color
    let smile: CGFloat

    init(seed name: String) {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in name.lowercased().utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        func pick(_ n: Int, _ shift: UInt64) -> Int { Int((h >> shift) % UInt64(n)) }

        let skins: [(Double, Double, Double)] = [
            (0.98, 0.84, 0.72), (0.95, 0.78, 0.62), (0.87, 0.67, 0.50), (0.76, 0.55, 0.38),
            (0.60, 0.42, 0.28), (0.45, 0.31, 0.21),
        ]
        let s = skins[pick(skins.count, 3)]
        skin = Color(red: s.0, green: s.1, blue: s.2)
        skinShade = Color(red: s.0 * 0.82, green: s.1 * 0.76, blue: s.2 * 0.72)
        let hairs: [Color] = [
            Color(white: 0.12), Color(red: 0.30, green: 0.19, blue: 0.11), Color(red: 0.52, green: 0.33, blue: 0.18),
            Color(red: 0.85, green: 0.68, blue: 0.40), Color(red: 0.62, green: 0.26, blue: 0.14), Color(white: 0.72),
        ]
        hair = hairs[pick(hairs.count, 11)]
        hairStyle = Hair.allCases[pick(Hair.allCases.count, 19)]
        glasses = pick(4, 27) == 0
        let shirts: [Color] = [.white, Color(white: 0.2), .blue, .teal, .orange, .indigo, .pink, .green]
        shirt = shirts[pick(shirts.count, 33)]
        smile = [0.035, 0.05, 0.065][pick(3, 41)]
    }
}

/// A small portrait avatar: head, hair, eyes, smile and shoulders on the speaker's colour.
struct FaceAvatar: View {
    var name: String
    var color: Color
    var size: CGFloat

    var body: some View {
        let t = FaceTraits(seed: name)
        Canvas { ctx, sz in
            let s = sz.width
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
            }
            let disc = Path(ellipseIn: CGRect(origin: .zero, size: sz))
            ctx.fill(disc, with: .linearGradient(
                Gradient(colors: [color.opacity(0.55), color]), startPoint: .zero, endPoint: CGPoint(x: 0, y: s)))
            ctx.clip(to: disc)

            // Hair behind the head (long styles).
            if t.hairStyle == .long {
                ctx.fill(Path(roundedRect: r(0.25, 0.20, 0.50, 0.58), cornerRadius: 0.2 * s), with: .color(t.hair))
            }
            // Shoulders and neck.
            ctx.fill(Path(ellipseIn: r(0.13, 0.76, 0.74, 0.62)), with: .color(t.shirt))
            ctx.fill(Path(roundedRect: r(0.43, 0.58, 0.14, 0.22), cornerRadius: 0.05 * s), with: .color(t.skinShade))
            // Ears and head.
            ctx.fill(Path(ellipseIn: r(0.285, 0.43, 0.07, 0.10)), with: .color(t.skinShade))
            ctx.fill(Path(ellipseIn: r(0.645, 0.43, 0.07, 0.10)), with: .color(t.skinShade))
            ctx.fill(Path(ellipseIn: r(0.31, 0.23, 0.38, 0.44)), with: .color(t.skin))

            // Hair on top.
            switch t.hairStyle {
            case .none:
                break
            case .short, .long:
                ctx.fill(Path(ellipseIn: r(0.29, 0.18, 0.42, 0.21)), with: .color(t.hair))
            case .bun:
                ctx.fill(Path(ellipseIn: r(0.42, 0.08, 0.16, 0.15)), with: .color(t.hair))
                ctx.fill(Path(ellipseIn: r(0.30, 0.19, 0.40, 0.19)), with: .color(t.hair))
            case .curly:
                for (x, y) in [(0.30, 0.24), (0.38, 0.18), (0.47, 0.16), (0.56, 0.18), (0.63, 0.24)] {
                    ctx.fill(Path(ellipseIn: r(x - 0.02, y - 0.02, 0.13, 0.13)), with: .color(t.hair))
                }
            case .sidePart:
                var p = Path()
                p.move(to: CGPoint(x: 0.30 * s, y: 0.38 * s))
                p.addQuadCurve(to: CGPoint(x: 0.70 * s, y: 0.33 * s), control: CGPoint(x: 0.36 * s, y: 0.10 * s))
                p.addQuadCurve(to: CGPoint(x: 0.30 * s, y: 0.38 * s), control: CGPoint(x: 0.55 * s, y: 0.24 * s))
                ctx.fill(p, with: .color(t.hair))
            case .buzz:
                ctx.fill(Path(ellipseIn: r(0.31, 0.21, 0.38, 0.17)), with: .color(t.hair.opacity(0.75)))
            }

            // Eyes, cheeks, smile.
            let eye = Color(white: 0.12)
            ctx.fill(Path(ellipseIn: r(0.405, 0.435, 0.04, 0.05)), with: .color(eye))
            ctx.fill(Path(ellipseIn: r(0.555, 0.435, 0.04, 0.05)), with: .color(eye))
            ctx.fill(Path(ellipseIn: r(0.36, 0.50, 0.07, 0.04)), with: .color(.pink.opacity(0.25)))
            ctx.fill(Path(ellipseIn: r(0.57, 0.50, 0.07, 0.04)), with: .color(.pink.opacity(0.25)))
            var mouth = Path()
            mouth.move(to: CGPoint(x: 0.44 * s, y: 0.545 * s))
            mouth.addQuadCurve(to: CGPoint(x: 0.56 * s, y: 0.545 * s),
                               control: CGPoint(x: 0.50 * s, y: (0.545 + t.smile) * s))
            ctx.stroke(mouth, with: .color(eye.opacity(0.8)),
                       style: StrokeStyle(lineWidth: max(0.8, 0.022 * s), lineCap: .round))

            if t.glasses {
                let lw = max(0.8, 0.018 * s)
                ctx.stroke(Path(ellipseIn: r(0.37, 0.41, 0.11, 0.10)), with: .color(eye), lineWidth: lw)
                ctx.stroke(Path(ellipseIn: r(0.52, 0.41, 0.11, 0.10)), with: .color(eye), lineWidth: lw)
                var bridge = Path()
                bridge.move(to: CGPoint(x: 0.48 * s, y: 0.455 * s))
                bridge.addLine(to: CGPoint(x: 0.52 * s, y: 0.455 * s))
                ctx.stroke(bridge, with: .color(eye), lineWidth: lw)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)], startPoint: .top, endPoint: .center),
                lineWidth: 0.75)
        }
        .shadow(color: color.opacity(0.35), radius: size * 0.12, y: size * 0.06)
        .accessibilityLabel(name)
    }
}

/// A voice's "signature": the energy profile of its voice-print embedding as a symmetric bar
/// graph. Unique per person, and it visibly settles as more samples are learned.
struct VoiceSignature: View {
    var embedding: [Float]
    var color: Color
    var bars = 36

    var body: some View {
        let values = Self.profile(embedding, bars: bars)
        GeometryReader { geo in
            let spacing: CGFloat = 2.5
            let w = max(1.5, (geo.size.width - spacing * CGFloat(bars - 1)) / CGFloat(bars))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(values.indices, id: \.self) { i in
                    Capsule()
                        .fill(color.gradient.opacity(0.45 + 0.55 * Double(values[i])))
                        .frame(width: w, height: max(3, geo.size.height * CGFloat(values[i])))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func profile(_ e: [Float], bars: Int) -> [Float] {
        guard e.count >= bars else { return Array(repeating: 0.3, count: bars) }
        let chunk = e.count / bars
        let raw = (0..<bars).map { i -> Float in
            let slice = e[(i * chunk)..<((i + 1) * chunk)]
            return slice.map { abs($0) }.reduce(0, +) / Float(chunk)
        }
        let lo = raw.min() ?? 0, hi = raw.max() ?? 1
        return raw.map { hi > lo ? 0.2 + 0.8 * ($0 - lo) / (hi - lo) : 0.5 }
    }
}
