import AVFoundation
import Observation
import SwiftUI

/// Owns voice-message playback for a whole timeline so audio keeps playing while
/// its row scrolls out of the lazy viewport (the row is destroyed, this isn't).
/// Keyed by timeline item id — two events can share one mxc URL.
@MainActor
@Observable
final class AudioPlaybackController {
    private(set) var activeItemId: String?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private(set) var playerDuration: TimeInterval?
    /// In-flight / failed download, surfaced per row so the spinner and retry
    /// survive row recycling.
    private(set) var loadingItemId: String?
    private(set) var failedItemIds: Set<String> = []

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    func isActive(_ itemId: String) -> Bool { activeItemId == itemId }

    func toggle(itemId: String, source: MediaSourceBox, loader: MediaLoader) {
        if activeItemId == itemId, let player {
            if isPlaying {
                player.pause()
                isPlaying = false
                progressTimer?.invalidate()
                deactivateAudioSession()
            } else {
                activateAudioSession()
                player.play()
                isPlaying = true
                startProgressTimer()
            }
            return
        }
        guard loadingItemId == nil else { return }
        // Switching items: silence the current one before loading the next.
        stopAll()
        loadingItemId = itemId
        failedItemIds.remove(itemId)
        Task {
            defer { loadingItemId = nil }
            guard let data = await loader.fullContent(for: source),
                  let newPlayer = try? AVAudioPlayer(data: data) else {
                failedItemIds.insert(itemId)
                return
            }
            player = newPlayer
            activeItemId = itemId
            playerDuration = newPlayer.duration
            progress = 0
            activateAudioSession()
            newPlayer.play()
            isPlaying = true
            startProgressTimer()
        }
    }

    /// Stops playback and tears the session down. Called on a hard stop and on
    /// room-leave / thread-dismiss / park.
    func stopAll() {
        progressTimer?.invalidate()
        progressTimer = nil
        let wasPlaying = isPlaying
        player?.stop()
        player = nil
        activeItemId = nil
        playerDuration = nil
        isPlaying = false
        progress = 0
        if wasPlaying { deactivateAudioSession() }
    }

    /// Playback category so voice messages are audible with the silent switch
    /// on. No-op on macOS (no AVAudioSession).
    private func activateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
                if !player.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.progress = 0
                    self.progressTimer?.invalidate()
                    self.deactivateAudioSession()
                }
            }
        }
    }
}

/// Inline voice-message (and audio file) player: play/pause, waveform, time.
struct VoiceMessageView: View {
    let itemId: String
    let audio: AudioItem
    let loader: MediaLoader
    let controller: AudioPlaybackController

    private var isActive: Bool { controller.isActive(itemId) }
    private var isPlaying: Bool { isActive && controller.isPlaying }
    private var progress: Double { isActive ? controller.progress : 0 }
    private var isLoading: Bool { controller.loadingItemId == itemId }
    private var loadFailed: Bool { controller.failedItemIds.contains(itemId) }

    private var duration: TimeInterval {
        (isActive ? controller.playerDuration : nil) ?? audio.duration ?? 0
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: togglePlayback) {
                ZStack {
                    Circle().fill(.tint.opacity(0.85))
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else if loadFailed {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 32, height: 32)
                #if os(iOS)
                // 44pt touch target.
                .padding(6)
                .contentShape(Rectangle())
                .padding(-6)
                #endif
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityPlayLabel)
            // Time rides the button as its value; the visible time text and
            // waveform are hidden so they don't double-read.
            .accessibilityValue(Text(accessibilityTimeValue))
            .accessibilityAddTraits(isPlaying ? .updatesFrequently : [])

            WaveformBars(samples: audio.waveform, progress: progress)
                .frame(width: 140, height: 26)
                .accessibilityHidden(true)

            Text(timeLabel)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private var timeLabel: String {
        let seconds = isPlaying || progress > 0 ? duration * (1 - progress) : duration
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private var accessibilityPlayLabel: Text {
        if loadFailed {
            return Text("Couldn't load audio. Retry")
        }
        if isPlaying {
            return Text("Pause")
        }
        return audio.isVoiceMessage ? Text("Play voice message") : Text("Play audio")
    }

    /// Spelled-out duration; the visible "1:23" reads poorly when spoken.
    private var accessibilityTimeValue: String {
        let seconds = isPlaying || progress > 0 ? duration * (1 - progress) : duration
        let formatted = Duration.seconds(seconds.rounded())
            .formatted(.units(allowed: [.minutes, .seconds], width: .wide))
        return isPlaying || progress > 0
            ? String(localized: "\(formatted) remaining")
            : formatted
    }

    private func togglePlayback() {
        controller.toggle(itemId: itemId, source: audio.source, loader: loader)
    }
}

/// Static waveform with played-portion tinting.
struct WaveformBars: View {
    let samples: [Float]
    var progress: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let barCount = 36
            let display = resampled(to: barCount)
            let barWidth = proxy.size.width / CGFloat(barCount)
            HStack(alignment: .center, spacing: barWidth * 0.35) {
                ForEach(0..<barCount, id: \.self) { index in
                    let played = Double(index) / Double(barCount) < progress
                    Capsule()
                        .fill(played ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.5)))
                        .frame(width: barWidth * 0.65,
                               height: max(3, proxy.size.height * CGFloat(display[index])))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func resampled(to count: Int) -> [Float] {
        guard !samples.isEmpty else {
            return (0..<count).map { Float(0.25 + 0.6 * abs(sin(Double($0) * 12.9898))) }
        }
        return (0..<count).map { index in
            let position = Float(index) / Float(count) * Float(samples.count)
            let sample = samples[min(samples.count - 1, Int(position))]
            return max(0.12, min(1, sample))
        }
    }
}
