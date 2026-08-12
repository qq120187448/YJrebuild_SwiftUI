import Foundation

/// 4A 采样点规则：把有序中心线转换成供 4B（ARView.raycast）使用的等距像素采样点。
enum CrackSamplePoints {

    /// 沿折线等距采样（像素坐标）。
    /// - 保证首尾点；不足一段时插值取整。
    /// - 若折线长度过长，自动增大间隔，使点数不超过 `maxPoints`。
    static func evenlySpaced(
        _ polyline: [CrackPoint],
        spacingPx: Double,
        maxPoints: Int = 64
    ) -> [CrackPoint] {
        guard polyline.count >= 2, spacingPx > 0, maxPoints > 1 else {
            return polyline
        }

        var totalLength = 0.0
        for i in 1..<polyline.count {
            totalLength += hypot(
                Double(polyline[i].x - polyline[i - 1].x),
                Double(polyline[i].y - polyline[i - 1].y)
            )
        }
        guard totalLength > 0 else {
            return [polyline[0]]
        }

        let minSpacing = totalLength / Double(maxPoints - 1)
        let step = max(spacingPx, minSpacing)

        var result: [CrackPoint] = [polyline[0]]
        var accumulated = 0.0
        var nextDistance = step
        var segmentStart = polyline[0]
        var index = 1

        while index < polyline.count && result.count < maxPoints {
            let segmentEnd = polyline[index]
            let segmentLength = hypot(
                Double(segmentEnd.x - segmentStart.x),
                Double(segmentEnd.y - segmentStart.y)
            )
            if segmentLength > 0 {
                var t = (nextDistance - accumulated) / segmentLength
                while t <= 1.0 && result.count < maxPoints {
                    let x = Int(
                        (Double(segmentStart.x)
                            + t * Double(segmentEnd.x - segmentStart.x)).rounded()
                    )
                    let y = Int(
                        (Double(segmentStart.y)
                            + t * Double(segmentEnd.y - segmentStart.y)).rounded()
                    )
                    let point = CrackPoint(x: x, y: y)
                    if result.last != point {
                        result.append(point)
                    }
                    nextDistance += step
                    t = (nextDistance - accumulated) / segmentLength
                }
                accumulated += segmentLength
            }
            segmentStart = segmentEnd
            index += 1
        }

        if let last = polyline.last, result.last != last, result.count < maxPoints {
            result.append(last)
        }
        return result
    }
}
