// Builds a realistic two-track meeting from macOS voices:
//   mic.caf    – "you" (Samantha)
//   system.caf – two remote participants (Daniel, Karen)
// Usage: swift Scripts/make-test-meeting.swift <outdir> [variant]
import AVFoundation
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "a"
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let scripts: [String: [(String, String, String)]] = [
    "a": [
        ("Samantha", "mic", "Good morning everyone. Thanks for joining the weekly product sync. Let's start with the launch timeline."),
        ("Daniel", "system", "Sure. The beta build is ready and we are planning to ship it to testers on Thursday."),
        ("Karen", "system", "From the design side, the onboarding screens are finished, but we still need the final icons."),
        ("Samantha", "mic", "Great. Karen, can you send the icons to Daniel by Wednesday?"),
        ("Karen", "system", "Yes, I will send them by Wednesday afternoon."),
        ("Daniel", "system", "One risk is the server migration. If it slips, we should move the beta to Monday."),
        ("Samantha", "mic", "Agreed. Let's decide on Wednesday. Thanks everyone, talk soon."),
    ],
    "b": [
        ("Daniel", "system", "Hi, quick follow up on the beta. The server migration finished last night without problems."),
        ("Samantha", "mic", "That is great news. So we are still on track for Thursday?"),
        ("Karen", "system", "Yes, and the icons are in the build now. I also updated the app store screenshots."),
        ("Daniel", "system", "I will send the invitation emails to the testers tomorrow morning."),
        ("Samantha", "mic", "Perfect. Let's meet again after the first feedback comes in."),
    ],
]

let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
var tracks: [String: [Float]] = ["mic": [], "system": []]
var cursor = 16_000  // 1 s lead-in

for (voice, track, text) in scripts[variant]! {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "undersay-say-\(UUID()).caf")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", voice, "-o", tmp.path, "--data-format=LEF32@16000", text]
    try p.run(); p.waitUntilExit()
    let f = try AVAudioFile(forReading: tmp)
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    for k in tracks.keys where tracks[k]!.count < cursor { tracks[k]! += [Float](repeating: 0, count: cursor - tracks[k]!.count) }
    tracks[track]! += samples
    cursor += samples.count + 8_000  // 0.5 s gap between turns
    try? FileManager.default.removeItem(at: tmp)
}
for (name, samples) in tracks {
    let padded = samples + [Float](repeating: 0, count: max(0, cursor - samples.count))
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    let file = try AVAudioFile(forWriting: out.appending(path: "\(name).caf"), settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(padded.count))!
    b.frameLength = AVAudioFrameCount(padded.count)
    padded.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: padded.count) }
    try file.write(from: b)
}
print("Wrote \(Double(cursor) / 16_000) s meeting to \(out.path)")
