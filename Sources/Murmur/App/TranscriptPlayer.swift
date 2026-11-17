import AVFoundation
import MurmurCore
import Observation

/// Plays a meeting's mic and system tracks in sync so you can tap any line to hear it.
@MainActor
@Observable
final class TranscriptPlayer {
    private(set) var meetingID: UUID?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    @ObservationIgnored private var players: [AVAudioPlayer] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var stopAt: TimeInterval?

    func load(_ id: UUID) {
        guard meetingID != id else { return }
        unload()
        players = AudioTrack.allCases.compactMap { try? AVAudioPlayer(contentsOf: Paths.track($0, meeting: id)) }
        players.forEach { $0.prepareToPlay() }
        duration = players.map(\.duration).max() ?? 0
        meetingID = id
    }

    func unload() {
        pause()
        players = []
        meetingID = nil
        currentTime = 0
        duration = 0
    }

    func play(meeting id: UUID, from time: TimeInterval, until end: TimeInterval? = nil) {
        load(id)
        seek(time)
        stopAt = end
        resume()
    }

    func toggle(meeting id: UUID) {
        load(id)
        isPlaying ? pause() : resume()
    }

    func seek(_ time: TimeInterval) {
        currentTime = max(0, min(time, duration))
        for p in players { p.currentTime = min(currentTime, p.duration) }
    }

    func resume() {
        guard !players.isEmpty else { return }
        let start = (players.first?.deviceCurrentTime ?? 0) + 0.05
        for p in players where p.currentTime < p.duration { p.play(atTime: start) }
        isPlaying = true
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isPlaying {
                self.currentTime = self.players.map(\.currentTime).max() ?? 0
                if let stop = self.stopAt, self.currentTime >= stop { self.pause() }
                if !self.players.contains(where: \.isPlaying) { self.pause() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func pause() {
        players.forEach { $0.pause() }
        isPlaying = false
        stopAt = nil
        ticker?.cancel()
    }
}
