import Foundation

struct CrackRecognitionConfig: Codable, Equatable {
    var mode: String = "normal"            // normal / hairline
    var modelSize: String = "n"            // n / s
    var engine: String = "yolo"            // yolo / mobilesam
    var computeMode: String = "neural"     // neural / cpu
    var inferenceBackend: String = "direct" // direct / vision
    var maxDetections: Int = 5
    var captureResolution: Int = 1024
    var confidence: Double = 0.5
    var iou: Double = 0.5
    var tileSize: Int = 1024
    var tileOverlap: Int = 192
    var minMaskArea: Int = 50
    var skeletonMode: String = "main"      // all / main
    var topCracks: Int = 3
    var minSpurLength: Int = 30
    var minSkeletonLength: Int = 80
    var lengthUnit: String = "pixel"       // pixel / known
    var mmPerPixel: Double = 0
    var dedupDistanceMM: Double = 20
    var minPhysicalLengthMM: Double = 5
    var arLineWidth: Int = 2

    static let defaultConfig = CrackRecognitionConfig()

    var displayMode: String {
        mode == "hairline" ? "发丝级" : "常规"
    }

    mutating func clamp() {
        mode = mode == "normal" ? "normal" : "hairline"
        modelSize = modelSize == "n" ? "n" : "s"
        engine = engine == "mobilesam" ? "mobilesam" : "yolo"
        computeMode = computeMode == "cpu" ? "cpu" : "neural"
        inferenceBackend = inferenceBackend == "vision" ? "vision" : "direct"
        maxDetections = min(max(maxDetections, 1), 10)
        captureResolution = min(max(captureResolution, 512), 2048)
        confidence = min(max(confidence, 0.1), 0.9)
        iou = min(max(iou, 0.1), 0.9)
        tileSize = min(max(tileSize, 512), 1600)
        tileOverlap = min(max(tileOverlap, 64), 512)
        minMaskArea = min(max(minMaskArea, 10), 500)
        skeletonMode = skeletonMode == "all" ? "all" : "main"
        topCracks = min(max(topCracks, 1), 5)
        minSpurLength = min(max(minSpurLength, 10), 200)
        minSkeletonLength = min(max(minSkeletonLength, 20), 500)
        lengthUnit = lengthUnit == "known" ? "known" : "pixel"
        mmPerPixel = max(mmPerPixel, 0)
        dedupDistanceMM = min(max(dedupDistanceMM, 1), 100)
        minPhysicalLengthMM = min(max(minPhysicalLengthMM, 1), 100)
        arLineWidth = min(max(arLineWidth, 1), 5)
    }
}

enum CrackRecognitionSettings {
    private static let key = "crackRecognitionConfig"
    private static let versionKey = "crackRecognitionConfigVersion"
    private static let currentVersion = 64

    static func load() -> CrackRecognitionConfig {
        let storedVersion = UserDefaults.standard.integer(forKey: versionKey)
        guard storedVersion == currentVersion,
              let data = UserDefaults.standard.data(forKey: key),
              var config = try? JSONDecoder().decode(
                CrackRecognitionConfig.self,
                from: data
              ) else {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.set(currentVersion, forKey: versionKey)
            return .defaultConfig
        }
        config.clamp()
        return config
    }

    static func save(_ config: CrackRecognitionConfig) {
        var config = config
        config.clamp()
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }

    static func apply(url: URL) {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return
        }
        var config = load()
        if let value = components.queryItems?.first(where: { $0.name == "mode" })?.value {
            config.mode = value == "normal" ? "normal" : "hairline"
        }
        if let value = components.queryItems?.first(where: { $0.name == "model" })?.value {
            config.modelSize = value == "n" ? "n" : "s"
        }
        if let value = components.queryItems?.first(where: { $0.name == "engine" })?.value {
            config.engine = value == "mobilesam" ? "mobilesam" : "yolo"
        }
        if let value = components.queryItems?.first(where: { $0.name == "compute" })?.value {
            config.computeMode = value == "cpu" ? "cpu" : "neural"
        }
        if let value = components.queryItems?.first(where: { $0.name == "backend" })?.value {
            config.inferenceBackend = value == "vision" ? "vision" : "direct"
        }
        if let value = components.queryItems?.first(where: { $0.name == "maxdet" })?.value,
           let number = Int(value) {
            config.maxDetections = number
        }
        if let value = components.queryItems?.first(where: { $0.name == "capture" })?.value,
           let number = Int(value) {
            config.captureResolution = number
        }
        if let value = components.queryItems?.first(where: { $0.name == "conf" })?.value,
           let number = Double(value) {
            config.confidence = number
        }
        if let value = components.queryItems?.first(where: { $0.name == "iou" })?.value,
           let number = Double(value) {
            config.iou = number
        }
        if let value = components.queryItems?.first(where: { $0.name == "tile" })?.value,
           let number = Int(value) {
            config.tileSize = number
        }
        if let value = components.queryItems?.first(where: { $0.name == "overlap" })?.value,
           let number = Int(value) {
            config.tileOverlap = number
        }
        if let value = components.queryItems?.first(where: { $0.name == "minarea" })?.value,
           let number = Int(value) {
            config.minMaskArea = number
        }
        if let value = components.queryItems?.first(where: { $0.name == "skeleton" })?.value {
            config.skeletonMode = value == "all" ? "all" : "main"
        }
        if let value = components.queryItems?.first(where: { $0.name == "top" })?.value,
           let number = Int(value) {
            config.topCracks = number
        }
        if let value = components.queryItems?.first(where: { $0.name == "spur" })?.value,
           let number = Int(value) {
            config.minSpurLength = number
        }
        if let value = components.queryItems?.first(where: { $0.name == "minlen" })?.value,
           let number = Int(value) {
            config.minSkeletonLength = number
        }
        if let value = components.queryItems?.first(where: { $0.name == "unit" })?.value {
            config.lengthUnit = value == "known" ? "known" : "pixel"
        }
        if let value = components.queryItems?.first(where: { $0.name == "mmpp" })?.value,
           let number = Double(value) {
            config.mmPerPixel = number
        }
        if let value = components.queryItems?.first(where: { $0.name == "dedup" })?.value,
           let number = Double(value) {
            config.dedupDistanceMM = number
        }
        if let value = components.queryItems?.first(where: { $0.name == "physlen" })?.value,
           let number = Double(value) {
            config.minPhysicalLengthMM = number
        }
        if let value = components.queryItems?.first(where: { $0.name == "arwidth" })?.value,
           let number = Int(value) {
            config.arLineWidth = number
        }
        save(config)
    }
}
