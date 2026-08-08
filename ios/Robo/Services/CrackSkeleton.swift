import Foundation
import simd

struct CrackPoint: Hashable {
    let x: Int
    let y: Int
}

struct CrackComponent: Identifiable, Equatable {
    let id: Int
    let pixelLength: Double
    let mmLength: Double?

    init(id: Int, pixelLength: Double, mmPerPixel: Double?) {
        self.id = id
        self.pixelLength = pixelLength
        self.mmLength = mmPerPixel.map { pixelLength * $0 }
    }
}

struct CrackAnalysis: Equatable {
    var mask: [Bool]?
    var components: [CrackComponent] = []
    var totalPixelLength: Double = 0
    var totalMMLength: Double?
    var longestPixelLength: Double = 0
    var longestMMLength: Double?
}

struct CrackSparseAnalysis {
    var skeletonPoints: Set<CrackPoint> = []
    var components: [CrackComponent] = []
    var totalPixelLength: Double = 0
    var longestPixelLength: Double = 0
}

enum CrackSkeleton {

    static func analyzeSparse(
        points: Set<CrackPoint>,
        spacing: Int,
        width: Int,
        height: Int,
        config: CrackRecognitionConfig
    ) -> CrackSparseAnalysis {
        let bounded = Set(
            points.filter {
                $0.x >= 0 && $0.y >= 0 && $0.x < width && $0.y < height
            }
        )
        let minSparseArea = max(
            4,
            config.minMaskArea / max(1, spacing * spacing)
        )
        guard bounded.count >= minSparseArea else {
            return CrackSparseAnalysis()
        }

        let skeleton = skeletonizeSparse(
            bounded,
            spacing: max(1, spacing),
            width: width,
            height: height
        )
        let groups = componentPointsSparse(
            skeleton,
            spacing: max(1, spacing)
        )
        let mmPerPixel = config.lengthUnit == "known"
            ? config.mmPerPixel
            : nil

        if config.skeletonMode == "main" {
            let pruned = pruneSpursSparse(
                skeleton,
                spacing: max(1, spacing),
                width: width,
                height: height,
                minSpurLength: Double(config.minSpurLength)
            )
            let prunedGroups = componentPointsSparse(
                pruned,
                spacing: max(1, spacing)
            )
            var components = prunedGroups.enumerated().map { index, points in
                CrackComponent(
                    id: index + 1,
                    pixelLength: graphLength(points, width: width),
                    mmPerPixel: mmPerPixel
                )
            }
            components = components
                .filter {
                    $0.pixelLength >= Double(config.minSkeletonLength)
                }
                .sorted { $0.pixelLength > $1.pixelLength }
            if components.count > config.topCracks {
                components = Array(components.prefix(config.topCracks))
            }

            let keptIDs = Set(components.map(\.id))
            var display = Set<CrackPoint>()
            for (index, points) in prunedGroups.enumerated()
                where keptIDs.contains(index + 1) {
                display.formUnion(points)
            }
            let totalPixel = components.reduce(0) { $0 + $1.pixelLength }
            let longest = components.map(\.pixelLength).max() ?? 0
            return CrackSparseAnalysis(
                skeletonPoints: display,
                components: components,
                totalPixelLength: totalPixel,
                longestPixelLength: longest
            )
        }

        let components = groups.enumerated().map { index, points in
            CrackComponent(
                id: index + 1,
                pixelLength: graphLength(points, width: width),
                mmPerPixel: mmPerPixel
            )
        }
        let totalPixel = components.reduce(0) { $0 + $1.pixelLength }
        let longest = components.map(\.pixelLength).max() ?? 0
        return CrackSparseAnalysis(
            skeletonPoints: skeleton,
            components: components,
            totalPixelLength: totalPixel,
            longestPixelLength: longest
        )
    }

    static func componentPointsSparse(
        _ input: Set<CrackPoint>,
        spacing: Int = 1
    ) -> [[CrackPoint]] {
        guard !input.isEmpty else { return [] }
        var visited = Set<CrackPoint>()
        var groups: [[CrackPoint]] = []

        for start in input where !visited.contains(start) {
            var queue = [start]
            visited.insert(start)
            var points: [CrackPoint] = []
            var queueIndex = 0
            while queueIndex < queue.count {
                let current = queue[queueIndex]
                queueIndex += 1
                points.append(current)
                for dy in -spacing...spacing where dy % spacing == 0 {
                    for dx in -spacing...spacing where dx % spacing == 0 {
                        if dy == 0 && dx == 0 { continue }
                        let neighbor = CrackPoint(
                            x: current.x + dx,
                            y: current.y + dy
                        )
                        if input.contains(neighbor),
                           !visited.contains(neighbor) {
                            visited.insert(neighbor)
                            queue.append(neighbor)
                        }
                    }
                }
            }
            groups.append(points)
        }
        return groups
    }

    private static func skeletonizeSparse(
        _ input: Set<CrackPoint>,
        spacing: Int,
        width: Int,
        height: Int
    ) -> Set<CrackPoint> {
        var current = input
        var changed = true

        while changed {
            changed = false
            var toRemove = Set<CrackPoint>()
            for point in current {
                guard point.x >= spacing, point.y >= spacing,
                      point.x < width - spacing,
                      point.y < height - spacing else {
                    continue
                }
                let neighbors = sparseNeighbors(
                    point,
                    in: current,
                    spacing: spacing
                )
                let b = neighbors.filter { $0 }.count
                if b < 2 || b > 6 { continue }
                if countTransitions(neighbors) != 1 { continue }
                if neighbors[0] && neighbors[2] && neighbors[4] { continue }
                if neighbors[2] && neighbors[4] && neighbors[6] { continue }
                toRemove.insert(point)
            }
            if !toRemove.isEmpty {
                current.subtract(toRemove)
                changed = true
            }
        }
        return current
    }

    private static func pruneSpursSparse(
        _ input: Set<CrackPoint>,
        spacing: Int,
        width: Int,
        height: Int,
        minSpurLength: Double
    ) -> Set<CrackPoint> {
        var current = input
        for _ in 0..<30 {
            var removed = Set<CrackPoint>()
            for point in current {
                guard sparseNeighborCount(
                    point,
                    in: current,
                    spacing: spacing
                ) == 1 else {
                    continue
                }
                let path = traceEndpointSparse(
                    current,
                    start: point,
                    spacing: spacing,
                    width: width,
                    height: height,
                    limit: minSpurLength
                )
                if !path.isEmpty {
                    removed.formUnion(path)
                }
            }
            if removed.isEmpty { break }
            current.subtract(removed)
        }
        return current
    }

    private static func traceEndpointSparse(
        _ input: Set<CrackPoint>,
        start: CrackPoint,
        spacing: Int,
        width: Int,
        height: Int,
        limit: Double
    ) -> [CrackPoint] {
        var previous: CrackPoint?
        var current = start
        var path = [start]
        var distance = 0.0

        while true {
            var neighbors: [CrackPoint] = []
            for dy in -spacing...spacing where dy % spacing == 0 {
                for dx in -spacing...spacing where dx % spacing == 0 {
                    if dy == 0 && dx == 0 { continue }
                    let point = CrackPoint(
                        x: current.x + dx,
                        y: current.y + dy
                    )
                    if point.x >= 0, point.x < width,
                       point.y >= 0, point.y < height,
                       input.contains(point),
                       previous != point {
                        neighbors.append(point)
                    }
                }
            }
            guard let next = neighbors.first else {
                return path
            }
            distance += hypot(
                Double(next.x - current.x),
                Double(next.y - current.y)
            )
            if distance > limit {
                return []
            }
            path.append(next)
            let degree = sparseNeighborCount(
                next,
                in: input,
                spacing: spacing
            )
            if degree == 1 {
                return path
            }
            if degree != 2 {
                return path.dropLast().map { $0 }
            }
            previous = current
            current = next
        }
    }

    private static func sparseNeighborCount(
        _ point: CrackPoint,
        in input: Set<CrackPoint>,
        spacing: Int
    ) -> Int {
        sparseNeighbors(
            point,
            in: input,
            spacing: spacing
        ).filter { $0 }.count
    }

    private static func sparseNeighbors(
        _ point: CrackPoint,
        in input: Set<CrackPoint>,
        spacing: Int
    ) -> [Bool] {
        [
            input.contains(CrackPoint(x: point.x, y: point.y - spacing)),
            input.contains(CrackPoint(x: point.x + spacing, y: point.y - spacing)),
            input.contains(CrackPoint(x: point.x + spacing, y: point.y)),
            input.contains(CrackPoint(x: point.x + spacing, y: point.y + spacing)),
            input.contains(CrackPoint(x: point.x, y: point.y + spacing)),
            input.contains(CrackPoint(x: point.x - spacing, y: point.y + spacing)),
            input.contains(CrackPoint(x: point.x - spacing, y: point.y)),
            input.contains(CrackPoint(x: point.x - spacing, y: point.y - spacing))
        ]
    }

    static func analyze(
        mask: [Bool],
        width: Int,
        height: Int,
        config: CrackRecognitionConfig
    ) -> CrackAnalysis {
        guard width > 0, height > 0, mask.count == width * height else {
            return CrackAnalysis(mask: mask)
        }

        let binary = cleanMask(mask, width: width, height: height, minArea: config.minMaskArea)
        let skeleton = skeletonize(binary, width: width, height: height)
        let groups = componentPoints(skeleton, width: width, height: height)
        if config.skeletonMode == "main" {
            let pruned = pruneSpurs(
                skeleton,
                width: width,
                height: height,
                minSpurLength: Double(config.minSpurLength)
            )
            let prunedGroups = componentPoints(pruned, width: width, height: height)
            var components = prunedGroups.enumerated().map { index, points in
                CrackComponent(
                    id: index + 1,
                    pixelLength: graphLength(points, width: width),
                    mmPerPixel: config.lengthUnit == "known" ? config.mmPerPixel : nil
                )
            }
            components = components
                .filter { $0.pixelLength >= Double(config.minSkeletonLength) }
                .sorted { $0.pixelLength > $1.pixelLength }
            if components.count > config.topCracks {
                components = Array(components.prefix(config.topCracks))
            }
            let keptIDs = Set(components.map(\.id))
            var displayMask = [Bool](repeating: false, count: width * height)
            for (index, points) in prunedGroups.enumerated() where keptIDs.contains(index + 1) {
                for point in points {
                    displayMask[point.y * width + point.x] = true
                }
            }
            let mmPerPixel = config.lengthUnit == "known" ? config.mmPerPixel : nil
            let totalPixel = components.reduce(0) { $0 + $1.pixelLength }
            let totalMM = mmPerPixel.map { totalPixel * $0 }
            let longest = components.map(\.pixelLength).max() ?? 0
            return CrackAnalysis(
                mask: displayMask,
                components: components,
                totalPixelLength: totalPixel,
                totalMMLength: totalMM,
                longestPixelLength: longest,
                longestMMLength: mmPerPixel.map { longest * $0 }
            )
        }

        let mmPerPixel = config.lengthUnit == "known" ? config.mmPerPixel : nil
        let components = groups.enumerated().map { index, points in
            CrackComponent(
                id: index + 1,
                pixelLength: graphLength(points, width: width),
                mmPerPixel: mmPerPixel
            )
        }

        let totalPixel = components.reduce(0) { $0 + $1.pixelLength }
        let totalMM = mmPerPixel.map { totalPixel * $0 }
        let longest = components.map(\.pixelLength).max() ?? 0
        return CrackAnalysis(
            mask: skeleton,
            components: components,
            totalPixelLength: totalPixel,
            totalMMLength: totalMM,
            longestPixelLength: longest,
            longestMMLength: mmPerPixel.map { longest * $0 }
        )
    }

    static func cleanMask(
        _ input: [Bool],
        width: Int,
        height: Int,
        minArea: Int
    ) -> [Bool] {
        var output = input
        var area = output.filter { $0 }.count
        if area < max(10, minArea) {
            output = Array(repeating: false, count: width * height)
        }
        return output
    }

    static func skeletonize(_ input: [Bool], width: Int, height: Int) -> [Bool] {
        var current = input
        var changed = true
        while changed {
            changed = false
            var toRemove = Set<Int>()
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let index = y * width + x
                    guard current[index] else { continue }
                    let p2 = current[(y - 1) * width + x]
                    let p3 = current[(y - 1) * width + x + 1]
                    let p4 = current[y * width + x + 1]
                    let p5 = current[(y + 1) * width + x + 1]
                    let p6 = current[(y + 1) * width + x]
                    let p7 = current[(y + 1) * width + x - 1]
                    let p8 = current[y * width + x - 1]
                    let p9 = current[(y - 1) * width + x - 1]
                    let neighbors = [p2, p3, p4, p5, p6, p7, p8, p9]
                    let b = neighbors.filter { $0 }.count
                    if b < 2 || b > 6 { continue }
                    let transitions = countTransitions(neighbors)
                    if transitions != 1 { continue }
                    if p2 && p4 && p6 { continue }
                    if p4 && p6 && p8 { continue }
                    toRemove.insert(index)
                }
            }
            if !toRemove.isEmpty {
                for index in toRemove {
                    current[index] = false
                }
                changed = true
            }
        }
        return current
    }

    static func pruneSpurs(
        _ input: [Bool],
        width: Int,
        height: Int,
        minSpurLength: Double
    ) -> [Bool] {
        var current = input
        for _ in 0..<30 {
            var removed = Set<Int>()
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    guard current[index] else { continue }
                    let degree = neighborCount(current, x: x, y: y, width: width, height: height)
                    guard degree == 1 else { continue }
                    let path = traceEndpoint(
                        current,
                        startX: x,
                        startY: y,
                        width: width,
                        height: height,
                        limit: minSpurLength
                    )
                    if !path.isEmpty {
                        for point in path {
                            removed.insert(point.y * width + point.x)
                        }
                    }
                }
            }
            if removed.isEmpty { break }
            for index in removed {
                current[index] = false
            }
        }
        return current
    }

    static func measureComponents(
        _ input: [Bool],
        width: Int,
        height: Int,
        mmPerPixel: Double?
    ) -> [CrackComponent] {
        let groups = componentPoints(input, width: width, height: height)
        var components: [CrackComponent] = []
        for (index, points) in groups.enumerated() {
            let length = graphLength(points, width: width)
            components.append(
                CrackComponent(
                    id: index + 1,
                    pixelLength: length,
                    mmPerPixel: mmPerPixel
                )
            )
        }
        return components
    }

    static func pixelLength(of points: [CrackPoint]) -> Double {
        graphLength(points, width: 0)
    }

    static func componentPoints(
        _ input: [Bool],
        width: Int,
        height: Int
    ) -> [[CrackPoint]] {
        guard width > 0, height > 0, input.count == width * height else {
            return []
        }
        var visited = Set<Int>()
        var groups: [[CrackPoint]] = []

        for y in 0..<height {
            for x in 0..<width {
                let start = y * width + x
                guard input[start], !visited.contains(start) else { continue }
                var queue = [start]
                visited.insert(start)
                var points: [CrackPoint] = []
                while !queue.isEmpty {
                    let current = queue.removeFirst()
                    points.append(CrackPoint(x: current % width, y: current / width))
                    let cx = current % width
                    let cy = current / width
                    for dy in -1...1 {
                        for dx in -1...1 {
                            if dy == 0 && dx == 0 { continue }
                            let nx = cx + dx
                            let ny = cy + dy
                            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                            let neighbor = ny * width + nx
                            if input[neighbor], !visited.contains(neighbor) {
                                visited.insert(neighbor)
                                queue.append(neighbor)
                            }
                        }
                    }
                }
                groups.append(points)
            }
        }
        return groups
    }

    static func physicalGraphLength(
        _ points: [CrackPoint],
        uvByPoint: [CrackPoint: SIMD2<Double>]
    ) -> Double? {
        guard !points.isEmpty else { return nil }
        let pointSet = Set(points)
        var length = 0.0
        var edgeCount = 0
        for point in points {
            guard let currentUV = uvByPoint[point] else { continue }
            for dy in -1...1 {
                for dx in -1...1 {
                    if dy == 0 && dx == 0 { continue }
                    let neighbor = CrackPoint(x: point.x + dx, y: point.y + dy)
                    guard pointSet.contains(neighbor),
                          let neighborUV = uvByPoint[neighbor] else {
                        continue
                    }
                    length += simd_distance(currentUV, neighborUV)
                    edgeCount += 1
                }
            }
        }
        guard edgeCount > 0 else { return nil }
        return length / 2.0
    }

    private static func graphLength(_ points: [CrackPoint], width: Int) -> Double {
        var length = 0.0
        let pointSet = Set(points)
        for point in points {
            for dy in -1...1 {
                for dx in -1...1 {
                    if dy == 0 && dx == 0 { continue }
                    let neighbor = CrackPoint(x: point.x + dx, y: point.y + dy)
                    guard pointSet.contains(neighbor) else { continue }
                    length += (dy == 0 || dx == 0) ? 1.0 : 2.0.squareRoot()
                }
            }
        }
        return length / 2.0
    }

    private static func neighborCount(
        _ input: [Bool],
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> Int {
        var count = 0
        for dy in -1...1 {
            for dx in -1...1 {
                if dy == 0 && dx == 0 { continue }
                let nx = x + dx
                let ny = y + dy
                if nx >= 0, nx < width, ny >= 0, ny < height, input[ny * width + nx] {
                    count += 1
                }
            }
        }
        return count
    }

    private static func traceEndpoint(
        _ input: [Bool],
        startX: Int,
        startY: Int,
        width: Int,
        height: Int,
        limit: Double
    ) -> [CrackPoint] {
        var previous: CrackPoint?
        var current = CrackPoint(x: startX, y: startY)
        var path: [CrackPoint] = [current]
        var distance = 0.0

        while true {
            var neighbors: [CrackPoint] = []
            for dy in -1...1 {
                for dx in -1...1 {
                    if dy == 0 && dx == 0 { continue }
                    let nx = current.x + dx
                    let ny = current.y + dy
                    if nx >= 0, nx < width, ny >= 0, ny < height,
                       input[ny * width + nx] {
                        let point = CrackPoint(x: nx, y: ny)
                        if previous != point {
                            neighbors.append(point)
                        }
                    }
                }
            }
            guard let next = neighbors.first else {
                return path
            }
            distance += hypot(Double(next.x - current.x), Double(next.y - current.y))
            if distance > limit {
                return []
            }
            path.append(next)
            let degree = neighborCount(
                input,
                x: next.x,
                y: next.y,
                width: width,
                height: height
            )
            if degree == 1 {
                return path
            }
            if degree != 2 {
                return path.dropLast().map { $0 }
            }
            previous = current
            current = next
        }
    }

    private static func countTransitions(_ neighbors: [Bool]) -> Int {
        var count = 0
        for i in 0..<8 {
            let next = (i + 1) % 8
            if neighbors[i] && !neighbors[next] {
                count += 1
            }
        }
        return count
    }
}
