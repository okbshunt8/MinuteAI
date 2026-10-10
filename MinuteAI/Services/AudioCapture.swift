import AVFoundation
import CoreAudio

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "マイクが見つかりません。"
        case .coreAudio(let what, let status):
            return "\(what)に失敗しました (OSStatus \(status))。システム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 で MinuteAI を許可してください。"
        }
    }
}

/// Converts buffers of any PCM format into mono Float32 samples at a fixed sample rate.
final class MonoResampler {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(sampleRate: Double) {
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return [] }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channels = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength)))
    }
}

/// Captures the default microphone as 48 kHz mono samples.
final class MicrophoneCapture {
    var onSamples: (([Float]) -> Void)?
    /// Called when capture could not be restarted after the input device changed.
    var onFailure: ((Error) -> Void)?

    private var engine: AVAudioEngine?
    private let resampler = MonoResampler(sampleRate: AudioRecorder.sampleRate)
    private var configObserver: NSObjectProtocol?
    /// True between start() and stop(); restarts after a device change only happen while it is set.
    private var isWanted = false
    private static let retryDelays: [TimeInterval] = [0.5, 1, 2, 4]

    func start() throws {
        isWanted = true
        do {
            try startEngine()
        } catch {
            isWanted = false
            throw error
        }
    }

    func stop() {
        isWanted = false
        stopEngine()
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInputDevice }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.resampler.convert(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        // The input device changed (e.g. headset plugged in): rebuild the tap with the new format.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.stopEngine()
            self.restart(attempt: 0)
        }
    }

    /// Right after a device is unplugged the new default input is often not ready yet, so try a few times.
    private func restart(attempt: Int) {
        // `engine == nil`: a retry left over from an earlier recording must not start a second engine.
        guard isWanted, engine == nil else { return }
        do {
            try startEngine()
        } catch {
            stopEngine()
            guard attempt < Self.retryDelays.count else {
                onFailure?(error)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in
                self?.restart(attempt: attempt + 1)
            }
        }
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

/// Captures everything the Mac is playing (the remote side of a call) with a Core Audio process tap,
/// delivered as 48 kHz mono samples. No virtual audio driver is needed.
final class SystemAudioCapture {
    var onSamples: (([Float]) -> Void)?
    /// Called when capture could not be restarted after the output device changed.
    var onFailure: ((Error) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let resampler = MonoResampler(sampleRate: AudioRecorder.sampleRate)
    private let queue = DispatchQueue(label: "minuteai.system-audio")
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() throws {
        try startTap()
        // Follow output device changes (e.g. switching to headphones mid-meeting).
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.stopTap()
            do {
                try self.startTap()
            } catch {
                self.onFailure?(error)
            }
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, listener)
    }

    func stop() {
        if let deviceListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, deviceListener)
        }
        deviceListener = nil
        queue.sync { stopTap() }
    }

    private func startTap() throws {
        // Leave out our own sound, or playing back another meeting would end up in this recording.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "MinuteAI"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw AudioCaptureError.coreAudio("システム音声の取得", status) }

        do {
            var streamDescription = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &streamDescription)
            guard status == noErr, let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw AudioCaptureError.coreAudio("システム音声のフォーマット取得", status)
            }

            let outputUID = try Self.defaultOutputDeviceUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MinuteAI Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
            guard status == noErr else { throw AudioCaptureError.coreAudio("録音用デバイスの作成", status) }

            status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
                [weak self] _, inputData, _, _, _ in
                guard let self,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
                else { return }
                let samples = self.resampler.convert(buffer)
                if !samples.isEmpty { self.onSamples?(samples) }
            }
            guard status == noErr else { throw AudioCaptureError.coreAudio("録音処理の登録", status) }

            status = AudioDeviceStart(aggregateID, ioProcID)
            guard status == noErr else { throw AudioCaptureError.coreAudio("システム音声の録音開始", status) }
        } catch {
            stopTap()
            throw error
        }
    }

    private func stopTap() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// The Core Audio object that stands for this process, if it has one.
    private static func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, 0, nil, &size, &deviceID)
        guard status == noErr else { throw AudioCaptureError.coreAudio("出力デバイスの取得", status) }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw AudioCaptureError.coreAudio("出力デバイスの取得", status) }
        return uid.takeRetainedValue() as String
    }
}
