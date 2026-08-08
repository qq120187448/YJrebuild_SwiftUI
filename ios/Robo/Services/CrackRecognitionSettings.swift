import Foundation

struct CrackRecognitionConfig: Codable, Equatable {
    var mode: String = "hairline"          // normal / hairline
    var modelSize: String = "n"            // n / s
    var engine: String = "yolo"            // yolo / mobilesam
    var computeMode: String = "neural"     // neural / cpu
    var inferenceBackend: String = "direct" // direct / vision
    var confidence: Double = 0.15
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
    }
}

enum CrackRecognitionSettings {
    private static let key = "crackRecognitionConfig"

    static func load() -> CrackRecognitionConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              var config = try? JSONDecoder().decode(
                CrackRecognitionConfig.self,
                from: data
              ) else {
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
        save(config)
    }
}
