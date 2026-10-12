import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    var whisperVariant: String { didSet { defaults.set(whisperVariant, forKey: "whisperVariant") } }
    /// "ja", "en" or "auto".
    var language: String { didSet { defaults.set(language, forKey: "language") } }
    var captureMicrophone: Bool { didSet { defaults.set(captureMicrophone, forKey: "captureMicrophone") } }
    var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: "captureSystemAudio") } }
    /// Boost applied to the microphone before recording and transcription, in dB. 0 leaves it as it is.
    var microphoneGain: Double { didSet { defaults.set(microphoneGain, forKey: "microphoneGain") } }
    static let microphoneGainRange: ClosedRange<Double> = 0...24

    /// The boost as a factor to multiply samples by.
    var microphoneGainFactor: Float { Float(pow(10, microphoneGain / 20)) }
    var llmModelID: String { didSet { defaults.set(llmModelID, forKey: "llmModelID") } }
    var categories: [NoteCategory] {
        didSet {
            if let data = try? JSONEncoder().encode(categories) { defaults.set(data, forKey: "categories") }
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        whisperVariant = defaults.string(forKey: "whisperVariant") ?? WhisperModelManager.catalog[0].variant
        language = defaults.string(forKey: "language") ?? "ja"
        captureMicrophone = defaults.object(forKey: "captureMicrophone") as? Bool ?? true
        captureSystemAudio = defaults.object(forKey: "captureSystemAudio") as? Bool ?? true
        microphoneGain = defaults.object(forKey: "microphoneGain") as? Double ?? 0
        llmModelID = defaults.string(forKey: "llmModelID") ?? LLMModelManager.catalog[0].id
        if let data = defaults.data(forKey: "categories"),
           let saved = try? JSONDecoder().decode([NoteCategory].self, from: data), !saved.isEmpty {
            categories = saved
        } else {
            categories = NoteCategory.defaults
        }
    }

    func category(_ id: String) -> NoteCategory {
        categories.first { $0.id == id }
            ?? NoteCategory(id: id, name: NoteCategory.name(for: id, in: categories), colorName: "gray")
    }
}
