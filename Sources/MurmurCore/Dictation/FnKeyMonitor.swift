import AppKit
import ApplicationServices
import CoreGraphics
import os

/// Watches the fn / 🌐 key system-wide through a CGEvent tap.
///
/// Gestures:
///  - hold fn          → push-to-talk (release to transcribe)
///  - double-tap fn    → hands-free (tap fn again to finish)
///  - fn + any key     → ignored (fn+arrows, fn+F-keys keep working)
///  - esc while active → cancel
public final class FnKeyMonitor {
    public enum Event {
        case pressed
        case released(heldFor: TimeInterval, interrupted: Bool)
        case escape
    }

    public var onEvent: ((Event) -> Void)?
    /// When set, the monitor swallows Escape (only while dictation is active).
    public var isCapturingEscape: () -> Bool = { false }
    /// Suppress fn so macOS doesn't also open the emoji picker / Apple dictation.
    public var suppressSystemFnAction = true

    private let log = Logger(subsystem: "com.patrickfreyer.murmur", category: "FnKey")
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fnDown = false
    private var fnDownAt: TimeInterval = 0
    private var otherKeyDuringFn = false
    /// Logs every modifier change for the first minutes after launch (diagnosing keyboards).
    private let debugUntil = ProcessInfo.processInfo.systemUptime + 600
    private var debugEvents: Bool { ProcessInfo.processInfo.systemUptime < debugUntil }

    public init() {}

    public var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Requires Accessibility permission (for an active tap that can suppress events).
    @discardableResult
    public func start() -> Bool {
        if tap != nil { return isRunning }
        let mask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    return monitor.handle(type: type, event: event)
                }, userInfo: refcon)
        else {
            log.error("Could not create event tap (Accessibility permission missing?)")
            DiagnosticLog.write("tap: create FAILED (AX=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess()) post=\(CGPreflightPostEventAccess()))")
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.info("fn key monitor running")
        DiagnosticLog.write("tap: created, enabled=\(CGEvent.tapIsEnabled(tap: tap))")
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            DiagnosticLog.write("tap: disabled by system (\(type.rawValue)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if debugEvents {
                DiagnosticLog.write("flagsChanged key=\(keyCode) flags=0x\(String(event.flags.rawValue, radix: 16))")
            }
            guard keyCode == 63 || keyCode == 179 else {  // kVK_Function, globe on newer keyboards
                if fnDown { otherKeyDuringFn = true }
                return Unmanaged.passUnretained(event)
            }
            let isDown = event.flags.contains(.maskSecondaryFn)
            let now = ProcessInfo.processInfo.systemUptime
            if isDown, !fnDown {
                fnDown = true
                fnDownAt = now
                otherKeyDuringFn = false
                emit(.pressed)
            } else if !isDown, fnDown {
                fnDown = false
                emit(.released(heldFor: now - fnDownAt, interrupted: otherKeyDuringFn))
            }
            return suppressSystemFnAction && !otherKeyDuringFn ? nil : Unmanaged.passUnretained(event)

        case .keyDown:
            if fnDown { otherKeyDuringFn = true }
            if event.getIntegerValueField(.keyboardEventKeycode) == 53, isCapturingEscape() {
                emit(.escape)
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func emit(_ event: Event) {
        // The tap callback runs on the main run loop; hop asynchronously so the tap returns fast.
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
