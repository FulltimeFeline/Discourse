import AVFoundation
import Foundation

/// Loops a synthesized telephone ring (440+480 Hz, 2s on / 4s off) for
/// incoming calls, generated in code so we ship no audio asset.
@MainActor
final class RingtonePlayer {
    static let shared = RingtonePlayer()
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        guard let data = Self.ringWavData else { return }
        #if os(iOS)
        // .playback rings through the silent switch; the default category
        // would ring silently.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
        #endif
        player = try? AVAudioPlayer(data: data)
        player?.numberOfLoops = -1
        player?.volume = 0.6
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// One 6-second ring cycle as a 16-bit mono WAV.
    private static let ringWavData: Data? = {
        let sampleRate = 22050.0
        let toneSeconds = 2.0
        let totalSeconds = 6.0
        let frameCount = Int(sampleRate * totalSeconds)
        let toneFrames = Int(sampleRate * toneSeconds)
        let fadeFrames = Int(sampleRate * 0.02)

        var samples = [Int16](repeating: 0, count: frameCount)
        for i in 0..<toneFrames {
            let t = Double(i) / sampleRate
            var value = 0.22 * sin(2 * .pi * 440 * t) + 0.22 * sin(2 * .pi * 480 * t)
            // Short fades avoid clicks at the tone edges.
            if i < fadeFrames { value *= Double(i) / Double(fadeFrames) }
            if i > toneFrames - fadeFrames { value *= Double(toneFrames - i) / Double(fadeFrames) }
            samples[i] = Int16(max(-1, min(1, value)) * 32767)
        }

        let dataSize = frameCount * 2
        var wav = Data(capacity: 44 + dataSize)
        func append(_ string: String) { wav.append(contentsOf: string.utf8) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + dataSize)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate) * 2)
        append16(2); append16(16)
        append("data"); append32(UInt32(dataSize))
        samples.withUnsafeBytes { wav.append(contentsOf: $0) }
        return wav
    }()
}
