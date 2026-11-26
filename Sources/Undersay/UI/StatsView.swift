import Charts
import Darwin
import UndersayCore
import SwiftUI

/// "Stats for nerds": what you've said, how fast it went, and what's under the hood.
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var system = SystemInfo()

    var body: some View {
        let s = UsageStats.compute(
            dictations: model.dictations.items, meetings: model.meetings.meetings, voices: model.voices.prints)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                hero(s)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.l), GridItem(.flexible(), spacing: Space.l)],
                          alignment: .leading, spacing: Space.l) {
                    speedCard(s)
                    paceCard(s)
                    heatmapCard(s)
                    appsCard(s)
                    meetingsCard(s)
                    peopleCard(s)
                }
                engineCard(s)
                funFacts(s)
            }
            .padding(.vertical, Space.xl)
            .pageColumn(maxWidth: 1000)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .defaultScrollAnchor(ProcessInfo.processInfo.environment["UNDERSAY_STATS_BOTTOM"] != nil ? .bottom : .top)
        .background { AmbientBackdrop(tint: .green) }
        .navigationTitle("Statistics")
        .task { await system.load() }
    }

    // MARK: - Hero

    private func hero(_ s: UsageStats) -> some View {
        HStack(alignment: .bottom, spacing: Space.xxl) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("WORDS DICTATED").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                Text(s.words, format: .number)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(LinearGradient(colors: [.green, .teal, .blue], startPoint: .leading, endPoint: .trailing))
                Text(s.dictations == 0
                     ? "Hold fn and start talking: your numbers show up here."
                     : "\(s.dictations) dictations, \(Self.duration(s.audioSeconds)) of speech, \(Self.duration(s.timeSaved)) saved vs typing at \(Int(UsageStats.typingWPM)) wpm.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if s.streakDays > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(s.streakDays)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                    Label("day streak", systemImage: "flame.fill").font(.callout.weight(.medium)).foregroundStyle(.orange)
                }
            }
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Radius.hero, elevation: 1)
    }

    // MARK: - Cards

    private func speedCard(_ s: UsageStats) -> some View {
        StatCard(title: "Speed", symbol: "bolt.fill", tint: .green) {
            HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                BigStat(value: s.medianLatency.map { "\(Int($0 * 1000))" } ?? "–", unit: "ms", caption: "median")
                BigStat(value: s.p95Latency.map { "\(Int($0 * 1000))" } ?? "–", unit: "ms", caption: "p95")
                BigStat(value: s.realtimeFactor.map { String(format: "%.0f", $0) } ?? "–", unit: "×", caption: "real time")
            }
            if s.latencies.count >= 3 {
                Chart(Self.histogram(s.latencies), id: \.bucket) { bin in
                    BarMark(x: .value("Latency", bin.label), y: .value("Dictations", bin.count))
                        .foregroundStyle(LinearGradient(colors: [.green, .teal], startPoint: .bottom, endPoint: .top))
                        .clipShape(.rect(cornerRadius: 3))
                }
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2.monospacedDigit()) } }
                .frame(height: 90)
            }
        }
    }

    private func paceCard(_ s: UsageStats) -> some View {
        StatCard(title: "Your pace", symbol: "speedometer", tint: .blue) {
            BigStat(value: s.wordsPerMinute.map { "\(Int($0))" } ?? "–", unit: "wpm", caption: "while dictating")
            if let wpm = s.wordsPerMinute {
                // Speaking vs typing, as two bars.
                VStack(alignment: .leading, spacing: Space.s) {
                    PaceBar(label: "You, speaking", value: wpm, max: max(wpm, 60), color: .blue)
                    PaceBar(label: "Typing (average)", value: UsageStats.typingWPM, max: max(wpm, 60), color: .secondary)
                }
                Text(String(format: "%.1f× faster than typing", wpm / UsageStats.typingWPM))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func heatmapCard(_ s: UsageStats) -> some View {
        StatCard(title: "When you talk", symbol: "calendar", tint: .purple) {
            let peak = max(1, s.heatmap.flatMap { $0 }.max() ?? 1)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<7, id: \.self) { d in
                    HStack(spacing: 3) {
                        Text(["M", "T", "W", "T", "F", "S", "S"][d])
                            .font(.system(size: 9.5, weight: .semibold).monospaced()).foregroundStyle(.secondary)
                            .frame(width: 10)
                        ForEach(0..<24, id: \.self) { h in
                            let v = s.heatmap[d][h]
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(v == 0 ? AnyShapeStyle(.quaternary.opacity(0.6))
                                              : AnyShapeStyle(Color.purple.opacity(0.25 + 0.75 * Double(v) / Double(peak))))
                                .aspectRatio(1, contentMode: .fit)
                                .help("\(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][d]) \(h):00 · \(v) dictation\(v == 1 ? "" : "s")")
                        }
                    }
                }
                HStack {
                    Text("0:00"); Spacer(); Text("12:00"); Spacer(); Text("23:00")
                }
                .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.secondary)
                .padding(.leading, 13)
            }
        }
    }

    private func appsCard(_ s: UsageStats) -> some View {
        StatCard(title: "Where your words go", symbol: "square.grid.2x2.fill", tint: .orange) {
            if s.topApps.isEmpty {
                Text("No dictations yet").foregroundStyle(.secondary)
            }
            let top = Array(s.topApps.prefix(5))
            let peak = max(1, top.first?.count ?? 1)
            ForEach(top) { a in
                HStack(spacing: Space.s + 2) {
                    AppIconNode(bundleID: a.bundleID, appName: a.name, size: 22)
                    Text(a.name).font(.callout).lineLimit(1).frame(width: 90, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(Color.orange.gradient)
                            .frame(width: max(6, geo.size.width * CGFloat(a.count) / CGFloat(peak)))
                    }
                    .frame(height: 8)
                    Text("\(a.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
    }

    private func meetingsCard(_ s: UsageStats) -> some View {
        StatCard(title: "Meetings", symbol: "person.2.wave.2.fill", tint: .pink) {
            HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                BigStat(value: "\(s.meetings)", unit: "", caption: "recorded")
                BigStat(value: Self.duration(s.meetingSeconds), unit: "", caption: "transcribed")
                BigStat(value: "\(s.speakersIdentified)", unit: "", caption: "speaker labels")
            }
            if let share = s.yourTalkShare {
                VStack(alignment: .leading, spacing: Space.xs + 2) {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            Capsule().fill(Color.pink.gradient).frame(width: geo.size.width * share)
                            Capsule().fill(.quaternary)
                        }
                    }
                    .frame(height: 8)
                    Text("You do \(Int(share * 100))% of the talking").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func peopleCard(_ s: UsageStats) -> some View {
        StatCard(title: "People you talk to", symbol: "person.wave.2.fill", tint: .indigo) {
            if s.people.isEmpty {
                Text("Name speakers in a meeting and they'll show up here.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(s.people.prefix(4).enumerated()), id: \.element.id) { i, p in
                HStack(spacing: Space.s + 2) {
                    Text("\(i + 1)").font(.caption.monospacedDigit().weight(.bold)).foregroundStyle(.tertiary).frame(width: 12)
                    FaceAvatar(name: p.name, color: Theme.color(p.colorIndex), size: 26)
                    Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text("\(p.meetings) mtg · \(Self.duration(p.talkTime))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func engineCard(_ s: UsageStats) -> some View {
        StatCard(title: "Engine room", symbol: "cpu", tint: .teal) {
            let rows: [(String, String)] = [
                ("Chip", system.chip),
                ("Speech model", "\(model.asrModel.title) · TDT 0.6B"),
                ("Runs on", "Apple Neural Engine via Core ML"),
                ("Audio", "16 kHz mono · Float32"),
                ("Speaker embeddings", "WeSpeaker · 256-d · cosine ≥ \(String(format: "%.2f", model.matchThreshold))"),
                ("Voice prints", "\(model.voices.prints.count) · \(model.voices.prints.reduce(0) { $0 + $1.sampleCount }) samples"),
                ("Models on disk", system.modelsSize),
                ("Your library", system.librarySize),
                ("Memory in use", system.memory),
                ("Clipboard", "restored after every paste"),
            ]
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.xl), GridItem(.flexible(), spacing: Space.xl)],
                      alignment: .leading, spacing: Space.s) {
                ForEach(rows, id: \.0) { k, v in
                    HStack(alignment: .firstTextBaseline) {
                        Text(k).foregroundStyle(.secondary)
                        Spacer(minLength: Space.s)
                        Text(v).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 12.5).monospaced())
                    .padding(.vertical, 3)
                    .overlay(alignment: .bottom) { Rectangle().fill(.quaternary.opacity(0.6)).frame(height: 0.5) }
                }
            }
        }
    }

    private func funFacts(_ s: UsageStats) -> some View {
        let facts: [(String, String, Color)] = [
            s.fastest.map { ("hare", "Fastest: \(Int($0.latency * 1000)) ms for \(String(format: "%.1f", $0.audio)) s of speech", Color.green) },
            s.longest.map { ("timer", "Longest dictation: \(Self.duration($0.duration)) into \($0.appName ?? "an app")", Color.blue) },
            s.busiestDay.map { ("flame", "Busiest day: \($0.count) dictations on \($0.date.formatted(.dateTime.month().day()))", Color.orange) },
            s.favoriteWord.map { ("quote.bubble", "Your favourite word: “\($0.word)” (\($0.count)×)", Color.purple) },
        ].compactMap { $0 }
        return Group {
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: Space.m) {
                    SectionHeader("Fun facts")
                    FlowLayout(spacing: Space.s) {
                        ForEach(facts, id: \.1) { icon, text, color in
                            Label(text, systemImage: icon)
                                .font(.callout)
                                .padding(.horizontal, Space.m + 2)
                                .padding(.vertical, Space.s + 1)
                                .background(color.opacity(0.12), in: .capsule)
                                .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .padding(.top, Space.s)
            }
        }
    }

    // MARK: - Helpers

    struct Bin { let bucket: Int; let label: String; let count: Int }

    static func histogram(_ latencies: [TimeInterval]) -> [Bin] {
        let edges = [0, 50, 75, 100, 125, 150, 200, 300]
        return edges.indices.map { i in
            let lo = edges[i], hi = i + 1 < edges.count ? edges[i + 1] : Int.max
            let n = latencies.filter { let ms = Int($0 * 1000); return ms >= lo && ms < hi }.count
            return Bin(bucket: i, label: hi == Int.max ? "\(lo)+" : "\(lo)", count: n)
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        if t < 60 { return "\(Int(t.rounded())) s" }
        if t < 3600 { return "\(Int(t / 60)) min" }
        return String(format: "%.1f h", t / 3600)
    }
}

// MARK: - Components

private struct StatCard<Content: View>: View {
    var title: String
    var symbol: String
    var tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(tint.gradient))
            }
            content
        }
        .padding(Space.xl - 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface(radius: Radius.card, elevation: 0.6)
    }
}

private struct BigStat: View {
    var value: String
    var unit: String
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                if !unit.isEmpty { Text(unit).font(.callout.weight(.medium)).foregroundStyle(.secondary) }
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PaceBar: View {
    var label: String
    var value: Double
    var max: Double
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value)) wpm").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                Capsule().fill(color == .secondary ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color.gradient))
                    .frame(width: geo.size.width * CGFloat(value / max))
            }
            .frame(height: 8)
        }
    }
}

/// Machine facts for the engine room, gathered off the main thread.
@MainActor
@Observable
final class SystemInfo {
    var chip = "…"
    var modelsSize = "…"
    var librarySize = "…"
    var memory = "…"

    func load() async {
        chip = Self.sysctl("machdep.cpu.brand_string") ?? "Apple Silicon"
        memory = Self.bytes(Self.footprint())
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let (models, library) = await Task.detached(priority: .utility) {
            (Self.folderSize(support.appending(path: "FluidAudio")), Self.folderSize(Paths.root))
        }.value
        modelsSize = Self.bytes(models)
        librarySize = Self.bytes(library)
    }

    nonisolated static func sysctl(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    nonisolated static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    nonisolated static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
