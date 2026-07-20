import AVFoundation
import Foundation
import Observation

/// Records composer voice messages (AAC/m4a) and samples a waveform.
@MainActor
@Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    private(set) var duration: TimeInterval = 0
    private(set) var levels: [Float] = []
    /// True when the system stops the recorder out from under us; ComposerView
    /// tears down the recording UI and surfaces an error.
    private(set) var interrupted = false

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var fileURL: URL?

    struct Recording {
        let data: Data
        let duration: TimeInterval
        /// 0…1 normalised amplitude samples.
        let waveform: [Float]
    }

    func start() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { return false }

        #if os(iOS)
        // AVAudioRecorder.record() returns false under the default category;
        // activate a record-capable session first (stop() deactivates it).
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            return false
        }
        #endif

        let url = FileManager.default.temporaryDirectory
            .appending(path: "discourse-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            #if os(iOS)
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            return false
        }
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            #if os(iOS)
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            return false
        }

        self.recorder = recorder
        self.fileURL = url
        self.levels = []
        self.duration = 0
        self.interrupted = false
        self.isRecording = true

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.recorder else { return }
                // The system can stop the recorder without telling us (call,
                // Siri, session flip); catch it here and finalize gracefully.
                guard recorder.isRecording else {
                    self.meterTimer?.invalidate()
                    self.meterTimer = nil
                    self.recorder = nil
                    self.isRecording = false
                    self.interrupted = true
                    #if os(iOS)
                    try? AVAudioSession.sharedInstance()
                        .setActive(false, options: .notifyOthersOnDeactivation)
                    #endif
                    if let fileURL = self.fileURL {
                        try? FileManager.default.removeItem(at: fileURL)
                        self.fileURL = nil
                    }
                    return
                }
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0) // -160…0
                let normalised = max(0, min(1, (db + 50) / 50))
                self.levels.append(normalised)
                self.duration = recorder.currentTime
            }
        }
        return true
    }

    /// Stops and returns the recording, or nil if cancelled/too short.
    func stop(cancelled: Bool = false) -> Recording? {
        meterTimer?.invalidate()
        meterTimer = nil
        // After an external stop currentTime reads 0; fall back to the last
        // sampled duration so a partial take still sends.
        let liveTime = recorder?.currentTime ?? 0
        let finalDuration = max(liveTime, duration)
        recorder?.stop()
        recorder = nil
        isRecording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        defer {
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            fileURL = nil
        }
        guard !cancelled, finalDuration >= 0.5, let fileURL,
              let data = try? Data(contentsOf: fileURL) else { return nil }

        // Downsample the level samples to ~100 waveform points.
        let target = 100
        var waveform: [Float] = []
        if levels.isEmpty {
            waveform = Array(repeating: 0.5, count: target)
        } else {
            let bucket = max(1, levels.count / target)
            for start in stride(from: 0, to: levels.count, by: bucket) {
                let slice = levels[start..<min(start + bucket, levels.count)]
                waveform.append(slice.max() ?? 0)
            }
        }
        return Recording(data: data, duration: finalDuration, waveform: waveform)
    }
}
