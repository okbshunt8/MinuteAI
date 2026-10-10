import AVFoundation
import Observation

/// Plays back a meeting's recording, with a gain control because meeting recordings are often quiet.
@MainActor
@Observable
final class AudioPlayer {
    static let gainRange: ClosedRange<Float> = -12...24

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?
    /// Playback gain in dB; 0 plays the recording as it is.
    var gain: Float {
        didSet {
            equalizer.globalGain = gain
            UserDefaults.standard.set(gain, forKey: "playbackGain")
        }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    /// Used only for its global gain, which can amplify (the player node's volume cannot go above 1).
    @ObservationIgnored private let equalizer = AVAudioUnitEQ(numberOfBands: 1)
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var timer: Timer?
    /// Position the current playback run started from.
    @ObservationIgnored private var startTime: TimeInterval = 0

    init() {
        gain = UserDefaults.standard.object(forKey: "playbackGain") as? Float ?? 0
        engine.attach(node)
        engine.attach(equalizer)
        equalizer.globalGain = gain
        // The output device changed (e.g. headphones unplugged): the engine has stopped by itself.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.outputChanged() }
        }
    }

    /// Carries on from the same position on the new output device, or shows the player as paused.
    private func outputChanged() {
        guard isPlaying else { return }
        let position = currentTime
        pause()
        currentTime = position
        play(from: position)
    }

    /// Makes the file ready to play. Does nothing if it is already loaded.
    func load(_ url: URL) {
        if file != nil, loadedURL == url { return }
        stop()
        do {
            let file = try AVAudioFile(forReading: url)
            engine.connect(node, to: equalizer, format: file.processingFormat)
            engine.connect(equalizer, to: engine.mainMixerNode, format: file.processingFormat)
            self.file = file
            loadedURL = url
            duration = Double(file.length) / file.processingFormat.sampleRate
            errorMessage = nil
        } catch {
            duration = 0
            errorMessage = "音声を読み込めませんでした: \(error.localizedDescription)"
        }
        currentTime = 0
    }

    func toggle() {
        if isPlaying {
            pause()
        } else {
            play(from: currentTime >= duration - 0.05 ? 0 : currentTime)
        }
    }

    func seek(to time: TimeInterval, play: Bool = false) {
        guard file != nil else { return }
        currentTime = max(0, min(time, duration))
        if isPlaying || play { self.play(from: currentTime) }
    }

    func stop() {
        pause()
        engine.stop()
        file = nil
        loadedURL = nil
        currentTime = 0
    }

    private func play(from time: TimeInterval) {
        guard let file else { return }
        let sampleRate = file.processingFormat.sampleRate
        let frame = AVAudioFramePosition(time * sampleRate)
        let remaining = file.length - frame
        guard remaining > 0 else { return }
        node.stop()
        node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil)
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            errorMessage = "音声を再生できませんでした: \(error.localizedDescription)"
            return
        }
        node.play()
        errorMessage = nil
        startTime = time
        currentTime = time
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
        node.stop()
        isPlaying = false
    }

    private func tick() {
        guard isPlaying, let renderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: renderTime)
        else { return }
        currentTime = startTime + Double(playerTime.sampleTime) / playerTime.sampleRate
        if currentTime >= duration {
            pause()
            currentTime = 0
        }
    }
}
