import AVFoundation
import AudioToolbox
import CoreAudio
import os

/// Records everything the Mac plays (Zoom, Meet, Teams, …) through a Core Audio process tap.
/// Needs only the "System Audio Recording" permission — no screen recording.
public final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "murmur.system-audio", qos: .userInitiated)
    private let resampler = Resampler()
    private let log = Logger(subsystem: "com.patrickfreyer.murmur", category: "SystemAudio")

    /// Called on a private queue with 16 kHz mono samples.
    public var onSamples: (([Float]) -> Void)?

    public init() {}

    public func start() throws {
        guard tapID == kAudioObjectUnknown else { return }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Murmur meeting tap"

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw CaptureError.coreAudio("Creating the system audio tap", status) }
        tapID = tap

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw CaptureError.coreAudio("Reading the tap format", status)
        }

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Murmur Meeting Capture",
            kAudioAggregateDeviceUIDKey: "com.patrickfreyer.murmur.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice)
        guard status == noErr else {
            stop()
            throw CaptureError.coreAudio("Creating the capture device", status)
        }
        aggregateID = aggregateDevice

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDevice, queue) {
            [weak self] _, inputData, _, _, _ in
            guard let self,
                let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
            else { return }
            let samples = self.resampler.convert(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        guard status == noErr else {
            stop()
            throw CaptureError.coreAudio("Creating the audio callback", status)
        }
        status = AudioDeviceStart(aggregateDevice, ioProcID)
        guard status == noErr else {
            stop()
            throw CaptureError.coreAudio("Starting system audio capture", status)
        }
        log.info("System audio capture started at \(format.sampleRate) Hz, \(format.channelCount) ch")
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { throw CaptureError.coreAudio("Finding the output device", status) }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw CaptureError.coreAudio("Reading the output device", status) }
        return uid.takeRetainedValue() as String
    }

    /// Excludes Murmur's own audio (e.g. transcript playback) from the recording.
    private static func ownProcessObjects() -> [AudioObjectID] {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size,
            &object)
        return status == noErr && object != kAudioObjectUnknown ? [object] : []
    }
}
