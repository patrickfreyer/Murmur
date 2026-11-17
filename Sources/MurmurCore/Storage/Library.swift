import Foundation
import Observation
import os

public enum Paths {
    /// MURMUR_HOME overrides the library location (used by tests and the CLI self-check).
    public static var root: URL = {
        if let custom = ProcessInfo.processInfo.environment["MURMUR_HOME"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Murmur", directoryHint: .isDirectory)
    }()

    public static var meetings: URL { root.appending(path: "Meetings", directoryHint: .isDirectory) }
    public static var voicePrints: URL { root.appending(path: "voiceprints.json") }
    public static var dictations: URL { root.appending(path: "dictations.json") }

    public static func meetingFolder(_ id: UUID) -> URL {
        meetings.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    public static func track(_ track: AudioTrack, meeting id: UUID) -> URL {
        meetingFolder(id).appending(path: "\(track.rawValue).caf")
    }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            Logger(subsystem: "com.patrickfreyer.murmur", category: "Storage")
                .error("Write failed \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

@MainActor
@Observable
public final class MeetingStore {
    public private(set) var meetings: [Meeting] = []

    public init(load: Bool = true) {
        if load { reload() }
    }

    public func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: Paths.meetings, includingPropertiesForKeys: nil)) ?? []
        meetings = folders.compactMap { JSON.read(Meeting.self, from: $0.appending(path: "meeting.json")) }
            .map { m in
                var m = m
                // A recording interrupted by a crash or quit can't resume; mark it for reprocessing.
                if m.status == .recording || m.status == .processing {
                    m.status = .failed
                    m.statusDetail = "Interrupted. Tap Retry to transcribe the saved audio."
                }
                return m
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    public func save(_ meeting: Meeting) {
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[i] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
        JSON.write(meeting, to: Paths.meetingFolder(meeting.id).appending(path: "meeting.json"))
    }

    public func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard var m = meeting(id) else { return }
        change(&m)
        save(m)
    }

    public func delete(_ id: UUID) {
        meetings.removeAll { $0.id == id }
        try? FileManager.default.trashItem(at: Paths.meetingFolder(id), resultingItemURL: nil)
    }
}

@MainActor
@Observable
public final class VoicePrintStore {
    public private(set) var prints: [VoicePrint] = []
    private let url: URL

    public init(url: URL = Paths.voicePrints) {
        self.url = url
        prints = JSON.read([VoicePrint].self, from: url) ?? []
    }

    public var me: VoicePrint? { prints.first { $0.isMe } }

    public func print(named name: String) -> VoicePrint? {
        prints.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Adds a confirmed sample for `name`, creating the voice print if needed.
    @discardableResult
    public func enroll(name: String, embedding: [Float], isMe: Bool = false) -> VoicePrint {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = prints.firstIndex(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            prints[i].absorb(embedding)
            if isMe { prints[i].isMe = true }
            persist()
            return prints[i]
        }
        let print = VoicePrint(name: clean, centroid: embedding, isMe: isMe, colorIndex: prints.count)
        prints.append(print)
        persist()
        return print
    }

    /// Learns your own voice from a dictation clip.
    public func enrollMe(embedding: [Float], defaultName: String) {
        if let i = prints.firstIndex(where: \.isMe) {
            prints[i].absorb(embedding, weight: 0.5)
            persist()
        } else {
            enroll(name: defaultName, embedding: embedding, isMe: true)
        }
    }

    public func rename(_ id: UUID, to name: String) {
        guard let i = prints.firstIndex(where: { $0.id == id }) else { return }
        prints[i].name = name
        prints[i].updatedAt = .now
        persist()
    }

    public func setMe(_ id: UUID) {
        for i in prints.indices { prints[i].isMe = prints[i].id == id }
        persist()
    }

    public func delete(_ id: UUID) {
        prints.removeAll { $0.id == id }
        persist()
    }

    private func persist() { JSON.write(prints, to: url) }
}

@MainActor
@Observable
public final class DictationStore {
    public private(set) var items: [Dictation] = []
    private let limit = 500

    public init() {
        items = JSON.read([Dictation].self, from: Paths.dictations) ?? []
    }

    public func add(_ d: Dictation) {
        items.insert(d, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        JSON.write(items, to: Paths.dictations)
    }

    public func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        JSON.write(items, to: Paths.dictations)
    }

    public func clear() {
        items.removeAll()
        JSON.write(items, to: Paths.dictations)
    }

    public var totalWords: Int { items.reduce(0) { $0 + $1.text.split(separator: " ").count } }
}
