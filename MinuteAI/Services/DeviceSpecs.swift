import Foundation
import Metal

/// How well a language model of a given size runs on this Mac.
enum ModelFit {
    case comfortable
    case heavy
    case tooLarge

    var label: String {
        switch self {
        case .comfortable: return "快適"
        case .heavy: return "重い"
        case .tooLarge: return "メモリ不足"
        }
    }
}

/// The hardware facts that decide which language models are practical on this Mac.
struct DeviceSpecs {
    let chip: String
    let cores: Int
    let performanceCores: Int
    let efficiencyCores: Int
    let memoryGB: Double
    /// Memory the GPU may use. Apple Silicon has no separate VRAM; the GPU shares the main memory.
    let gpuMemoryGB: Double?

    static let current = DeviceSpecs(
        chip: sysctlString("machdep.cpu.brand_string") ?? "不明",
        cores: ProcessInfo.processInfo.processorCount,
        performanceCores: sysctlInt("hw.perflevel0.physicalcpu") ?? 0,
        efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu") ?? 0,
        memoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
        gpuMemoryGB: MTLCreateSystemDefaultDevice().map { Double($0.recommendedMaxWorkingSetSize) / 1_073_741_824 })

    /// The model's weights have to fit in memory next to the transcription model, the app and macOS.
    var comfortableModelGB: Double { memoryGB * 0.35 }
    var largestModelGB: Double { memoryGB * 0.55 }

    func fit(sizeGB: Double?) -> ModelFit? {
        guard let sizeGB else { return nil }
        if sizeGB <= comfortableModelGB { return .comfortable }
        if sizeGB <= largestModelGB { return .heavy }
        return .tooLarge
    }

    var freeDiskGB: Double? {
        let values = try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Double($0) / 1_000_000_000 }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
