import AVFoundation
import Testing
@testable import MurmurCore

@Suite struct ResamplerTests {
    /// Streams a 48 kHz interleaved stereo sine through the resampler in 512-frame callbacks (like
    /// the system-audio tap) and checks the output is continuous: same length and same frequency.
    @Test func streamingChunksStayContinuous() throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let r = Resampler()
        var out: [Float] = []
        let freq = 440.0
        var n = 0
        for _ in 0..<300 {
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 512)!
            buf.frameLength = 512
            let p = buf.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<512 {
                let v = Float(sin(2 * .pi * freq * Double(n) / 48_000)) * 0.5
                p[2 * i] = v; p[2 * i + 1] = v
                n += 1
            }
            out += r.convert(buf)
        }
        let expected = 300 * 512 / 3
        #expect(abs(out.count - expected) < 200, "got \(out.count) expected ~\(expected)")
        // Zero crossings ≈ 2 * freq * seconds, so a glitchy stream would show up as extra crossings.
        let seconds = Double(out.count) / 16_000
        let crossings = zip(out, out.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        #expect(abs(Double(crossings) - 2 * freq * seconds) < 20, "crossings \(crossings)")
    }
}
