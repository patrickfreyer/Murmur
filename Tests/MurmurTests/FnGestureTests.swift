import Testing
@testable import MurmurCore

@Suite struct FnGestureTests {
    typealias A = FnGestureRecognizer.Action

    @Test func holdIsPushToTalk() {
        var g = FnGestureRecognizer()
        #expect(g.press(at: 0) == .start)
        #expect(g.release(at: 2.0, interrupted: false) == .finish)
    }

    @Test func doubleTapLocksOnSecondPressAndKeepsRecording() {
        var g = FnGestureRecognizer()
        #expect(g.press(at: 0) == .start)
        #expect(g.release(at: 0.12, interrupted: false) == A.none)
        #expect(g.press(at: 0.30) == .lock)               // locks on the second press, no restart
        #expect(g.release(at: 0.40, interrupted: false) == A.none)
        #expect(g.isLocked)
        #expect(g.timeout(at: 5) == A.none)               // stale timer from the first tap is harmless
        #expect(g.press(at: 20) == .finish)               // one tap ends it
        #expect(g.release(at: 20.1, interrupted: false) == A.none)
        #expect(g.press(at: 30) == .start)                // and the next press starts fresh
    }

    @Test func singleStrayTapCancelsAfterWindow() {
        var g = FnGestureRecognizer()
        #expect(g.press(at: 0) == .start)
        #expect(g.release(at: 0.1, interrupted: false) == A.none)
        #expect(g.timeout(at: 0.2) == A.none)             // too early
        #expect(g.timeout(at: 0.46) == .cancel)
    }

    @Test func slowSecondPressDoesNotLock() {
        var g = FnGestureRecognizer()
        _ = g.press(at: 0)
        _ = g.release(at: 0.1, interrupted: false)
        #expect(g.press(at: 0.9) != .lock)
    }

    @Test func fnComboCancels() {
        var g = FnGestureRecognizer()
        _ = g.press(at: 0)
        #expect(g.release(at: 1, interrupted: true) == .cancel)
    }

    @Test func holdingLongAfterTapStillFinishes() {
        var g = FnGestureRecognizer()
        _ = g.press(at: 0)
        _ = g.release(at: 0.1, interrupted: false)
        _ = g.press(at: 0.9)                               // late second press becomes a hold
        #expect(g.release(at: 3, interrupted: false) == .finish)
    }
}
