import AVFoundation

/// Mixes the microphone and system audio into one mono stream, writes it to an .m4a file
/// and hands 16 kHz samples to the transcriber.
final class AudioRecorder {
    static let sampleRate: Double = 48_000
    static let transcriptionSampleRate: Double = 16_000

    /// 16 kHz mono samples of the mix, called on the mixer queue.
    var onTranscriptionSamples: (([Float]) -> Void)?
    /// RMS level (0...1) of the microphone and system audio, called on the mixer queue.
    var onLevels: ((Float, Float) -> Void)?

    private let microphone = MicrophoneCapture()
    private let systemAudio = SystemAudioCapture()
    private let lock = NSLock()
    private var micQueue: [Float] = []
    private var systemQueue: [Float] = []
    private var useMic = false
    private var useSystem = false

    private let mixQueue = DispatchQueue(label: "minuteai.mixer")
    private var timer: DispatchSourceTimer?
    private var file: AVAudioFile?
    /// Raw copy of the recording, written as it happens. The .m4a only becomes playable once it is
    /// closed, so this is what survives if the app dies mid-recording. Deleted after a clean stop.
    private var safetyCopy: FileHandle?
    private var safetyURL: URL?
    private var ticksSinceSync = 0
    private let mixFormat = AVAudioFormat(standardFormatWithSampleRate: AudioRecorder.sampleRate, channels: 1)!
    private let downsampler = MonoResampler(sampleRate: AudioRecorder.transcriptionSampleRate)
    private var framesWritten: Int64 = 0

    /// Seconds of audio written so far.
    var duration: TimeInterval { Double(framesWritten) / Self.sampleRate }

    func start(to url: URL, microphone useMic: Bool, systemAudio useSystem: Bool) throws {
        self.useMic = useMic
        self.useSystem = useSystem
        micQueue.removeAll()
        systemQueue.removeAll()
        framesWritten = 0

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let safetyURL = Self.safetyCopyURL(for: url)
        FileManager.default.createFile(atPath: safetyURL.path, contents: nil)
        safetyCopy = try? FileHandle(forWritingTo: safetyURL)
        self.safetyURL = safetyURL

        do {
            if useMic {
                microphone.onSamples = { [weak self] samples in
                    guard let self else { return }
                    self.lock.lock()
                    self.micQueue.append(contentsOf: samples)
                    self.lock.unlock()
                }
                try microphone.start()
            }
            if useSystem {
                systemAudio.onSamples = { [weak self] samples in
                    guard let self else { return }
                    self.lock.lock()
                    self.systemQueue.append(contentsOf: samples)
                    self.lock.unlock()
                }
                try systemAudio.start()
            }
        } catch {
            microphone.stop()
            systemAudio.stop()
            file = nil
            try? safetyCopy?.close()
            safetyCopy = nil
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: safetyURL)
            throw error
        }

        let timer = DispatchSource.makeTimerSource(queue: mixQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.mix(flush: false) }
        timer.resume()
        self.timer = timer
    }

    /// Stops capturing and finalizes the audio file. Returns the recorded duration in seconds.
    @discardableResult
    func stop() -> TimeInterval {
        microphone.stop()
        systemAudio.stop()
        timer?.cancel()
        timer = nil
        mixQueue.sync {
            mix(flush: true)
            file?.close()
            file = nil
            // The .m4a is complete now, so the raw copy is no longer needed.
            try? safetyCopy?.close()
            safetyCopy = nil
            if let safetyURL { try? FileManager.default.removeItem(at: safetyURL) }
        }
        return duration
    }

    private func mix(flush: Bool) {
        let stallLimit = Int(Self.sampleRate / 2)
        let maxBacklog = Int(Self.sampleRate)

        lock.lock()
        var count: Int
        if useMic && useSystem {
            count = min(micQueue.count, systemQueue.count)
            let longest = max(micQueue.count, systemQueue.count)
            // One source stopped delivering: don't hold the other one back.
            if flush || (count == 0 && longest > stallLimit) { count = longest }
        } else {
            count = useMic ? micQueue.count : systemQueue.count
        }
        let mic = Array(micQueue.prefix(count))
        let system = Array(systemQueue.prefix(count))
        micQueue.removeFirst(mic.count)
        systemQueue.removeFirst(system.count)
        // The two devices run on different clocks; drop backlog instead of drifting apart.
        if micQueue.count > maxBacklog { micQueue.removeFirst(micQueue.count - maxBacklog) }
        if systemQueue.count > maxBacklog { systemQueue.removeFirst(systemQueue.count - maxBacklog) }
        lock.unlock()

        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: AVAudioFrameCount(count)),
              let output = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count {
            let sample = (i < mic.count ? mic[i] : 0) + (i < system.count ? system[i] : 0)
            output[i] = max(-1, min(1, sample))
        }

        do {
            try file?.write(from: buffer)
            framesWritten += Int64(count)
        } catch {
            NSLog("MinuteAI: failed to write audio: \(error)")
        }
        writeSafetyCopy(output, count: count)
        onLevels?(Self.rms(mic), Self.rms(system))
        let samples = downsampler.convert(buffer)
        if !samples.isEmpty { onTranscriptionSamples?(samples) }
    }

    private func writeSafetyCopy(_ samples: UnsafePointer<Float>, count: Int) {
        guard let safetyCopy else { return }
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count { pcm[i] = Int16(samples[i] * Float(Int16.max)) }
        try? pcm.withUnsafeBytes { try safetyCopy.write(contentsOf: Data($0)) }
        // Push it to disk every ~10 s so even a power loss costs only a few seconds.
        ticksSinceSync += 1
        if ticksSinceSync >= 100 {
            ticksSinceSync = 0
            try? safetyCopy.synchronize()
        }
    }

    static func safetyCopyURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("pcm")
    }

    /// Rebuilds the .m4a of a recording that was cut off (crash, forced quit, power loss) from its
    /// raw copy. Returns the recovered duration in seconds.
    @discardableResult
    static func recover(audioURL: URL) throws -> TimeInterval {
        let safetyURL = safetyCopyURL(for: audioURL)
        let temporaryURL = audioURL.deletingLastPathComponent().appendingPathComponent("recovering.m4a")
        let input = try FileHandle(forReadingFrom: safetyURL)
        defer { try? input.close() }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        try? FileManager.default.removeItem(at: temporaryURL)
        let output = try AVAudioFile(
            forWriting: temporaryURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunkFrames = Int(sampleRate) * 10
        var frames: Int64 = 0
        while let data = try input.read(upToCount: chunkFrames * 2), data.count >= 2 {
            let count = data.count / 2
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let samples = buffer.floatChannelData?[0]
            else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            data.withUnsafeBytes { raw in
                let pcm = raw.bindMemory(to: Int16.self)
                for i in 0..<count { samples[i] = Float(pcm[i]) / Float(Int16.max) }
            }
            try output.write(from: buffer)
            frames += Int64(count)
        }
        output.close()

        guard frames > 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: safetyURL)
            return 0
        }
        try? FileManager.default.removeItem(at: audioURL)
        try FileManager.default.moveItem(at: temporaryURL, to: audioURL)
        try FileManager.default.removeItem(at: safetyURL)
        return Double(frames) / sampleRate
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
