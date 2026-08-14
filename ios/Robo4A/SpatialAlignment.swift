import ARKit
import RealityKit
import RoomPlan
import simd

/// P4C-LongTermSpatialAlignment 第一步（专家批复，2026-08-14）：
/// 多 Anchor → 当前 ARWorld → RoomPlan 的刚体配准，估计 T_currentToRoom（world→room）。
/// 只做"配准变换估计 + 校正后 snapDistance 诊断"，不改测量算法；
/// 目标是验证：走动/长时间后，用 Anchor + 表面观测配准能否把漂移（如 80mm）压回小值（如 8mm）。

/// T_currentToRoom：当前 ARKit 世界坐标 → RoomPlan 长期业务坐标的刚体变换。
struct RoomAlignmentTransform {
    var matrix: simd_float4x4 = matrix_identity_float4x4
    var sampleCount = 0
    var residualMM: Double = .infinity
    var timestamp: Date?

    var isIdentity: Bool { sampleCount == 0 }
}

/// 刚体配准估计（Umeyama / SVD）。
enum DriftEstimator {

    /// src（当前 ARKit 世界观测）→ dst（RoomPlan 坐标）的刚体变换，最小二乘。
    static func estimateRigid(
        src: [SIMD3<Float>],
        dst: [SIMD3<Float>]
    ) -> simd_float4x4? {
        guard src.count == dst.count, src.count >= 3 else { return nil }
        let srcCenter = mean(src)
        let dstCenter = mean(dst)

        // 协方差 H = Σ (src_i - c_s)(dst_i - c_d)^T
        var h = simd_float3x3()
        for i in 0..<src.count {
            let s = src[i] - srcCenter
            let d = dst[i] - dstCenter
            h.columns.0 += s.x * d
            h.columns.1 += s.y * d
            h.columns.2 += s.z * d
        }

        guard let (u, _, v) = svd3x3(h) else { return nil }
        var r = v * u.transpose
        // 反射修正（保持右手系）
        if simd_determinant(r) < 0 {
            var vAdj = v
            vAdj.columns.2 = -vAdj.columns.2
            r = vAdj * u.transpose
        }
        let t = dstCenter - r * srcCenter
        return simd_float4x4(
            columns: (
                SIMD4<Float>(r.columns.0.x, r.columns.0.y, r.columns.0.z, 0),
                SIMD4<Float>(r.columns.1.x, r.columns.1.y, r.columns.1.z, 0),
                SIMD4<Float>(r.columns.2.x, r.columns.2.y, r.columns.2.z, 0),
                SIMD4<Float>(t.x, t.y, t.z, 1)
            )
        )
    }

    /// 应用 T（齐次坐标）。
    static func apply(_ t: simd_float4x4, to p: SIMD3<Float>) -> SIMD3<Float> {
        let v = t * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3<Float>(v.x, v.y, v.z)
    }

    static func mean(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !points.isEmpty else { return .zero }
        var sum = SIMD3<Float>()
        for p in points { sum += p }
        return sum / Float(points.count)
    }

    // MARK: - 3x3 SVD（Jacobi 迭代）

    private static func svd3x3(
        _ a: simd_float3x3
    ) -> (u: simd_float3x3, s: simd_float3x3, v: simd_float3x3)? {
        let ata = a.transpose * a
        guard let (values, vectors) = eigenSymmetric3x3(ata) else {
            return nil
        }
        let v = vectors
        let sDiag = SIMD3<Float>(
            max(sqrt(max(values.x, 0)), 1e-6),
            max(sqrt(max(values.y, 0)), 1e-6),
            max(sqrt(max(values.z, 0)), 1e-6)
        )
        var s = matrix_identity_float3x3
        s.columns.0.x = sDiag.x
        s.columns.1.y = sDiag.y
        s.columns.2.z = sDiag.z

        let vCols = [
            SIMD3<Float>(v.columns.0.x, v.columns.0.y, v.columns.0.z),
            SIMD3<Float>(v.columns.1.x, v.columns.1.y, v.columns.1.z),
            SIMD3<Float>(v.columns.2.x, v.columns.2.y, v.columns.2.z)
        ]
        var u = simd_float3x3()
        u.columns.0 = a * vCols[0] / sDiag.x
        u.columns.1 = a * vCols[1] / sDiag.y
        u.columns.2 = a * vCols[2] / sDiag.z
        u = orthonormalize(u)
        return (u, s, v)
    }

    /// 对称 3x3 矩阵的 Jacobi 特征分解，返回（特征值降序, 特征向量列）。
    private static func eigenSymmetric3x3(
        _ input: simd_float3x3,
        maxIter: Int = 60
    ) -> (values: SIMD3<Float>, vectors: simd_float3x3)? {
        var a = input
        var v = matrix_identity_float3x3
        let eps: Float = 1e-8

        for _ in 0..<maxIter {
            let p01 = abs(a.columns.0.y)
            let p02 = abs(a.columns.0.z)
            let p12 = abs(a.columns.1.z)
            let maxVal = max(p01, max(p02, p12))
            if maxVal < eps { break }

            let (p, q): (Int, Int)
            if maxVal == p01 {
                (p, q) = (0, 1)
            } else if maxVal == p02 {
                (p, q) = (0, 2)
            } else {
                (p, q) = (1, 2)
            }

            let apq = element(a, p, q)
            let app = element(a, p, p)
            let aqq = element(a, q, q)
            let theta = 0.5 * atan2(2 * apq, aqq - app)
            let c = cos(theta)
            let s = sin(theta)
            let jacobi = jacobiRotation(p, q, c, s)
            a = jacobi.transpose * a * jacobi
            v = v * jacobi
        }

        let values = SIMD3<Float>(a.columns.0.x, a.columns.1.y, a.columns.2.z)
        let order = [0, 1, 2].sorted {
            values[$0] > values[$1]
        }
        let sortedV = SIMD3<Float>(
            values[order[0]],
            values[order[1]],
            values[order[2]]
        )
        let vCols = [
            SIMD3<Float>(v.columns.0.x, v.columns.0.y, v.columns.0.z),
            SIMD3<Float>(v.columns.1.x, v.columns.1.y, v.columns.1.z),
            SIMD3<Float>(v.columns.2.x, v.columns.2.y, v.columns.2.z)
        ]
        let sortedVec = simd_float3x3(
            columns: (
                vCols[order[0]],
                vCols[order[1]],
                vCols[order[2]]
            )
        )
        return (sortedV, sortedVec)
    }

    private static func element(
        _ m: simd_float3x3,
        _ row: Int,
        _ col: Int
    ) -> Float {
        switch (row, col) {
        case (0, 0): return m.columns.0.x
        case (0, 1): return m.columns.1.x
        case (0, 2): return m.columns.2.x
        case (1, 0): return m.columns.0.y
        case (1, 1): return m.columns.1.y
        case (1, 2): return m.columns.2.y
        case (2, 0): return m.columns.0.z
        case (2, 1): return m.columns.1.z
        default: return m.columns.2.z
        }
    }

    private static func jacobiRotation(
        _ p: Int,
        _ q: Int,
        _ c: Float,
        _ s: Float
    ) -> simd_float3x3 {
        var j = matrix_identity_float3x3
        if p == 0, q == 1 {
            j.columns.0.x = c
            j.columns.1.x = s
            j.columns.0.y = -s
            j.columns.1.y = c
        } else if p == 0, q == 2 {
            j.columns.0.x = c
            j.columns.2.x = s
            j.columns.0.z = -s
            j.columns.2.z = c
        } else {
            j.columns.1.y = c
            j.columns.2.y = s
            j.columns.1.z = -s
            j.columns.2.z = c
        }
        return j
    }

    private static func orthonormalize(
        _ m: simd_float3x3
    ) -> simd_float3x3 {
        var result = simd_float3x3()
        var basis: [SIMD3<Float>] = []
        let cols = [
            SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        ]
        for col in 0..<3 {
            var vec = cols[col]
            for b in basis {
                vec -= simd_dot(vec, b) * b
            }
            let len = simd_length(vec)
            if len > 1e-6 {
                vec /= len
            } else {
                vec = SIMD3<Float>(
                    col == 0 ? 1 : 0,
                    col == 1 ? 1 : 0,
                    col == 2 ? 1 : 0
                )
            }
            basis.append(vec)
            switch col {
            case 0:
                result.columns.0 = vec
            case 1:
                result.columns.1 = vec
            default:
                result.columns.2 = vec
            }
        }
        return result
    }
}

/// 多锚点空间配准管理器：扫描完成时在墙/地面放置参考锚点，
/// 后台轮询用"锚点屏幕投影 → raycast 观测 → 刚体配准"估计 T_currentToRoom。
final class SpatialAlignmentManager {

    struct RegistryItem {
        let surfaceID: UUID
        let label: String
        let anchor: ARAnchor
        let roomPosition: SIMD3<Float>
    }

    private(set) var registry: [RegistryItem] = []
    private(set) var lastTransform = RoomAlignmentTransform()
    private(set) var lastDiagnostic = ""

    /// 放置 4~6 个参考锚点：前几个 wall 中心 + floor 中心。
    @discardableResult
    func buildRegistry(
        surfaces: [CapturedRoom.Surface],
        session: ARSession
    ) -> Int {
        removeAll(session: session)
        let walls = surfaces.filter { $0.category == .wall }
        let floors = surfaces.filter { $0.category == .floor }
        var items: [(label: String, surface: CapturedRoom.Surface)] = []
        for (index, wall) in walls.prefix(4).enumerated() {
            items.append(("墙\(index + 1)", wall))
        }
        if let floor = floors.first {
            items.append(("地面", floor))
        }
        for item in items {
            let anchor = ARAnchor(
                name: item.label,
                transform: item.surface.transform
            )
            session.add(anchor: anchor)
            registry.append(
                RegistryItem(
                    surfaceID: item.surface.identifier,
                    label: item.label,
                    anchor: anchor,
                    roomPosition: item.surface.transform.position
                )
            )
        }
        return registry.count
    }

    func removeAll(session: ARSession) {
        for item in registry {
            session.remove(anchor: item.anchor)
        }
        registry.removeAll()
        lastTransform = RoomAlignmentTransform()
        lastDiagnostic = ""
    }

    /// 后台轮询：可见锚点 → raycast 观测（当前 ARKit 世界）→ 刚体配准 → T。
    @MainActor
    func update(
        arView: ARView,
        surfaces: [CapturedRoom.Surface]
    ) {
        guard registry.count >= 3 else {
            lastDiagnostic = "锚点不足（\(registry.count)/3），无法配准"
            return
        }
        let viewport = arView.bounds
        var src: [SIMD3<Float>] = []
        var dst: [SIMD3<Float>] = []

        for item in registry {
            let worldPos = item.anchor.transform.position
            guard let screen = arView.project(worldPos) else { continue }
            guard screen.x >= 0, screen.x <= viewport.width,
                  screen.y >= 0, screen.y <= viewport.height else {
                continue
            }
            let results = arView.raycast(
                from: screen,
                allowing: .estimatedPlane,
                alignment: .any
            )
            guard let hit = results.first else { continue }
            src.append(hit.worldTransform.position)
            dst.append(item.roomPosition)
        }

        guard src.count >= 3,
              let transform = DriftEstimator.estimateRigid(
                  src: src,
                  dst: dst
              ) else {
            lastDiagnostic = "配准观测不足（\(src.count) 点），T 保持上次"
            return
        }

        var residualSum: Float = 0
        for i in 0..<src.count {
            let corrected = DriftEstimator.apply(transform, to: src[i])
            residualSum += simd_distance(corrected, dst[i])
        }
        let residual = Double(residualSum) / Double(src.count)
        let translation = transform.position

        lastTransform = RoomAlignmentTransform(
            matrix: transform,
            sampleCount: src.count,
            residualMM: residual * 1000,
            timestamp: Date()
        )
        lastDiagnostic = String(
            format: "配准 %d 点 · T平移 %.1f/%.1f/%.1f mm · 残差 %.1f mm",
            src.count,
            Double(translation.x) * 1000,
            Double(translation.y) * 1000,
            Double(translation.z) * 1000,
            residual * 1000
        )
    }

    /// 用当前 T 校正世界点（world → room）。
    func correct(_ world: SIMD3<Float>) -> SIMD3<Float> {
        guard !lastTransform.isIdentity else { return world }
        return DriftEstimator.apply(lastTransform.matrix, to: world)
    }

    /// 校正后的 snapDistance（world 点经 T 校正后与最近表面法向距离）。
    func correctedSnapDistanceMM(
        world: SIMD3<Float>,
        surfaces: [CapturedRoom.Surface]
    ) -> Double? {
        guard !lastTransform.isIdentity else { return nil }
        let corrected = correct(world)
        guard let mapped = SurfaceUV4C.map(
            world: corrected,
            surfaces: surfaces,
            toleranceM: 0.02,
            snapMaxM: 0.02
        ) else { return nil }
        let local = SurfaceUV4C.surfaceLocal(corrected, surface: mapped.surface)
        return Double(abs(local.z)) * 1000
    }
}

private extension simd_float3x3 {
    var transpose: simd_float3x3 {
        simd_transpose(self)
    }
}
