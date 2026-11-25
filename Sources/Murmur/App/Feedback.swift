import AppKit
import MurmurCore

/// Small, quiet confirmations: a sound you can feel in the trackpad too.
@MainActor
enum Feedback {
    private static var sounds: [String: NSSound] = [:]

    static func play(_ cue: DictationController.Cue, sound enabled: Bool) {
        let haptics = NSHapticFeedbackManager.defaultPerformer
        switch cue {
        case .started:
            haptics.perform(.levelChange, performanceTime: .now)
            if enabled { sound("Tink", volume: 0.18) }
        case .locked:
            haptics.perform(.alignment, performanceTime: .now)
            if enabled { sound("Pop", volume: 0.22) }
        case .stopped:
            haptics.perform(.levelChange, performanceTime: .now)
        case .inserted:
            if enabled { sound("Glass", volume: 0.12) }
        case .cancelled:
            haptics.perform(.generic, performanceTime: .now)
        }
    }

    static func meeting(started: Bool, sound enabled: Bool) {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        if enabled { sound(started ? "Morse" : "Bottle", volume: 0.15) }
    }

    private static func sound(_ name: String, volume: Float) {
        let s = sounds[name] ?? NSSound(named: NSSound.Name(name))?.copy() as? NSSound
        guard let s else { return }
        sounds[name] = s
        s.volume = volume
        s.stop()
        s.play()
    }
}
