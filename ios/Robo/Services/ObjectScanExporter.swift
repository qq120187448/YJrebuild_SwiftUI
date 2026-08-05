import Foundation
import UIKit

enum ObjectScanExporter {
    struct Input {
        let objectName: String
        let capturedAt: Date
        let metrics: ObjectScanMetrics
        let rawPointCount: Int
        let thumbnail: UIImage?
    }

    static func makeExcelFile(input: Input) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObjectScanExcel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("物体工程测量表.xlsx")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let aabb = input.metrics.aabb
        let aabbVolume = aabb.sizeX * aabb.sizeY * aabb.sizeZ
        let obbLength = input.metrics.obbLengthM ?? 0
        let obbWidth = input.metrics.obbWidthM ?? 0
        let obbHeight = input.metrics.obbHeightM ?? 0
        let obbVolume = obbLength * obbWidth * obbHeight
        let footprint = input.metrics.footprintAreaM2 ?? 0
        let voxelVolume = input.metrics.voxelMeshVolumeM3 ?? input.metrics.heightfieldVolumeM3
        let voxelSurface = input.metrics.voxelMeshSurfaceAreaM2 ?? input.metrics.heightfieldSurfaceAreaM2
        let voxelTotalSurface = input.metrics.voxelMeshTotalSurfaceAreaM2 ?? voxelSurface
        let voxelOK = input.metrics.voxelReconstructionSucceeded
            ?? (input.metrics.voxelMeshVolumeM3 != nil)
        let coveragePercent = Int((input.metrics.voxelCoverageEstimate ?? 1) * 100)

        let summary = [
            "对象名称：\(input.objectName)",
            "扫描时间：\(formatter.string(from: input.capturedAt))",
            "原始点数：\(input.rawPointCount)",
            "目标点数：\(input.metrics.targetPointCount ?? input.metrics.processedPointCount)",
            "已剔除背景点：\(input.metrics.backgroundRemovedCount ?? 0)（\(String(format: "%.1f%%", (input.metrics.backgroundRemovedRatio ?? 0) * 100))）",
            "AABB 外包围：\(two(aabb.sizeX)) × \(two(aabb.sizeY)) × \(two(aabb.sizeZ)) m",
            "OBB 长宽高：\(two(obbLength)) × \(two(obbWidth)) × \(two(obbHeight)) m",
            voxelOK
                ? "体素网格体积：\(three(voxelVolume)) m³"
                : "体素网格体积：未生成（请参考高度场）",
            voxelOK
                ? "不规则物体表面积：\(three(voxelSurface)) m²"
                : "不规则物体表面积：未生成（请参考高度场）",
            "点云覆盖率：\(coveragePercent)%",
            "占地面积：\(two(footprint)) m²"
        ].joined(separator: "；")

        var rows: [[XLSXWriter.Cell]] = [
            [XLSXWriter.Cell("物体工程扫描测量表", bold: true)],
            [XLSXWriter.Cell("对象概要", bold: true), XLSXWriter.Cell(summary)],
            [XLSXWriter.Cell("")]
        ]

        rows.append([
            XLSXWriter.Cell("指标", bold: true, section: true),
            XLSXWriter.Cell("数值", bold: true, section: true),
            XLSXWriter.Cell("单位", bold: true, section: true)
        ])

        func add(_ name: String, _ value: String, _ unit: String) {
            rows.append([
                XLSXWriter.Cell(name),
                XLSXWriter.Cell(value),
                XLSXWriter.Cell(unit)
            ])
        }

        add("AABB 长", two(aabb.sizeX), "m")
        add("AABB 宽", two(aabb.sizeY), "m")
        add("AABB 高", two(aabb.sizeZ), "m")
        add("AABB 体积", three(aabbVolume), "m³")
        add("OBB 长", two(obbLength), "m")
        add("OBB 宽", two(obbWidth), "m")
        add("OBB 高", two(obbHeight), "m")
        add("OBB 体积", three(obbVolume), "m³")
        add("凸包体积", three(input.metrics.convexHullVolumeM3), "m³")
        add("凸包表面积", three(input.metrics.convexHullSurfaceAreaM2), "m²")
        if voxelOK {
            add("体素网格体积（Surface Nets 闭合封口）", three(voxelVolume), "m³")
            add("体素网格总表面积", three(voxelTotalSurface), "m²")
            add("不规则物体表面积（不含地面/墙面接触）", three(voxelSurface), "m²")
            if let voxelSize = input.metrics.voxelSizeM {
                add("体素尺寸", String(format: "%.4f", voxelSize), "m")
            }
            if let coverage = input.metrics.voxelCoverageEstimate {
                add("点云覆盖率", "\(Int((coverage * 100).rounded()))%", "%")
            }
            if let note = input.metrics.voxelNote {
                add("体素说明", note, "—")
            }
        } else {
            add(
                "体素重建状态",
                input.metrics.voxelFailureReason ?? "未生成",
                "—"
            )
        }
        if let removedCount = input.metrics.backgroundRemovedCount {
            add(
                "已剔除背景点",
                "\(removedCount)（\(String(format: "%.1f%%", (input.metrics.backgroundRemovedRatio ?? 0) * 100))）",
                "个"
            )
        }
        if let value = input.metrics.classificationRemovedCount {
            add("分类剔除", "\(value)", "点")
        }
        if let value = input.metrics.planeAnchorRemovedCount {
            add("AR 平面剔除", "\(value)", "点")
        }
        if let value = input.metrics.groundRemovedCount {
            add("地面剔除", "\(value)", "点")
        }
        if let value = input.metrics.ransacRemovedCount {
            add("RANSAC 平面剔除", "\(value)", "点")
        }
        if let value = input.metrics.localPlaneRemovedCount {
            add("局部平面剔除", "\(value)", "点")
        }
        if let vertexCount = input.metrics.voxelMeshVertexCount,
           let triangleCount = input.metrics.voxelMeshTriangleCount {
            add("网格顶点/三角面", "\(vertexCount) / \(triangleCount)", "个")
        }
        add("高度场体积", three(input.metrics.heightfieldVolumeM3), "m³")
        add("高度场表面积", three(input.metrics.heightfieldSurfaceAreaM2), "m²")
        add("地面接触面积（投影面积）", two(input.metrics.groundContactAreaM2 ?? input.metrics.footprintAreaM2 ?? 0), "m²")
        add("靠墙接触面积", two(input.metrics.wallContactAreaM2 ?? 0), "m²")
        add("占地面积（投影面积）", two(footprint), "m²")
        rows.append([
            XLSXWriter.Cell("备注"),
            XLSXWriter.Cell(
                "不规则物体表面积按体素表面重建计算，已扣除地面接触面积与靠墙接触面积；空白区域按最近邻点云高度估算，点云覆盖率 \(coveragePercent)%。体素重建失败时请以高度场数据为准。"
            )
        ])

        var images: [XLSXWriter.ImageAttachment] = []
        if let thumbnail = input.thumbnail {
            let resized = ImageResizer.resized(thumbnail, maxDimension: 512)
            if let png = resized.pngData() {
            images.append(XLSXWriter.ImageAttachment(
                label: "3D预览",
                data: png,
                fileExtension: "png",
                anchorRow: 2,
                displayWidth: 280,
                displayHeight: 210
            ))
            }
        }

        let sheet = XLSXWriter.Sheet(
            name: "物体工程测量表",
            rows: rows,
            images: images,
            columnWidths: [26, 14, 8],
            rowHeights: [2: 130]
        )
        let workbook = try XLSXWriter.makeWorkbook(sheets: [sheet])
        try workbook.write(to: url)
        return url
    }

    private static func two(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func three(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
