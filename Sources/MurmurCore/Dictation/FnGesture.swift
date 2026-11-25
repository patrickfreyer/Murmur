import Foundation

/// Turns raw fn press/release events into dictation intents.
///
///  - Hold fn                → `.start` on press, `.finish` on release (push-to-talk)
///  - Double-tap fn          → `.start` on the first press, `.lock` on the second press.
///                             The recording keeps running through the gap, so nothing is lost.
///  - Tap fn while locked    → `.finish` (on press, so it feels instant)
///  - Single short tap       → `.cancel` once the double-tap window passes (an accidental tap)
///  - fn + another key       → `.cancel` (fn+arrows, fn+F-keys keep working)
///
/// Pure value type so the timing rules are unit-testable.
public struct FnGestureRecognizer: Sendable {
    public enum Action: Equatable, Sendable {
        case none, start, lock, finish, cancel
    }

    enum Phase: Equatable {
        case idle
        case holding(since: TimeInterval)
        case awaitingSecondTap(releasedAt: TimeInterval)
        /// Locked, but the second tap's finger is still down: ignore its release.
        case lockArming
        case locked
        /// Locked recording was just finished on press: swallow the matching release.
        case finishing
    }

    /// A press shorter than this is a tap, not push-to-talk.
    public var tapMaxDuration: TimeInterval = 0.3
    /// Maximum gap between the first tap's release and the second press.
    public var doubleTapWindow: TimeInterval = 0.35

    private(set) var phase: Phase = .idle

    public init() {}

    public var isLocked: Bool { phase == .locked || phase == .lockArming }

    /// When the recognizer is waiting to see whether a tap becomes a double-tap, the time at
    /// which `timeout(at:)` should be called.
    public var pendingDeadline: TimeInterval? {
        if case .awaitingSecondTap(let t) = phase { return t + doubleTapWindow }
        return nil
    }

    public mutating func press(at t: TimeInterval) -> Action {
        switch phase {
        case .idle, .finishing:
            phase = .holding(since: t)
            return .start
        case .awaitingSecondTap(let releasedAt):
            if t - releasedAt <= doubleTapWindow {
                phase = .lockArming
                return .lock
            }
            // Too slow for a double-tap: treat as a fresh hold of the ongoing recording.
            phase = .holding(since: t)
            return .none
        case .locked:
            phase = .finishing
            return .finish
        case .holding, .lockArming:
            return .none
        }
    }

    public mutating func release(at t: TimeInterval, interrupted: Bool) -> Action {
        switch phase {
        case .holding(let since):
            if interrupted {
                phase = .idle
                return .cancel
            }
            if t - since >= tapMaxDuration {
                phase = .idle
                return .finish
            }
            phase = .awaitingSecondTap(releasedAt: t)
            return .none
        case .lockArming:
            phase = .locked
            return .none
        case .finishing:
            phase = .idle
            return .none
        case .idle, .awaitingSecondTap, .locked:
            return .none
        }
    }

    /// Call at or after `pendingDeadline`.
    public mutating func timeout(at t: TimeInterval) -> Action {
        guard case .awaitingSecondTap(let releasedAt) = phase, t - releasedAt >= doubleTapWindow else { return .none }
        phase = .idle
        return .cancel
    }

    /// Lock without the gesture (menu bar / Home button).
    public mutating func forceLock() { phase = .locked }

    public mutating func reset() { phase = .idle }
}
