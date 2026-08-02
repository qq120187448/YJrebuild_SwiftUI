import Foundation

enum UnitPriceStore {
    private static let key = "unitPriceMap"

    static func load() -> [String: Double] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return map
    }

    static func save(_ map: [String: Double]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func importCSV(_ text: String) -> (count: Int, message: String) {
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count > 1 else {
            return (0, "单价表为空")
        }

        let header = parseCSVLine(lines[0]).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        let codeIndex = header.firstIndex { $0.contains("编码") } ?? 0
        let nameIndex = header.firstIndex { $0.contains("名称") || $0.contains("项目") } ?? 1
        let priceIndex = header.firstIndex { $0.contains("单价") || $0.contains("价格") } ?? 2

        var map = load()
        var count = 0
        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            guard fields.count > max(codeIndex, nameIndex, priceIndex) else { continue }
            let code = fields[codeIndex].trimmingCharacters(in: .whitespaces)
            let name = fields[nameIndex].trimmingCharacters(in: .whitespaces)
            let price = Double(fields[priceIndex].trimmingCharacters(in: .whitespaces))
            guard let price, price > 0 else { continue }
            if !code.isEmpty {
                map[code] = price
                count += 1
            }
            if !name.isEmpty {
                map[name] = price
                count += 1
            }
        }
        save(map)
        return (count, "已导入 \(count) 条单价")
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }
}
