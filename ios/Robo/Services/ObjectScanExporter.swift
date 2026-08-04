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

        let summary = [
            "对象名称：\(input.objectName)",
            "扫描时间：\(formatter.string(from: input.capturedAt))",
            "原始点数：\(input.rawPointCount)",
            "目标点数：\(input.metrics.targetPointCount ?? input.metrics.processedPointCount)",
            "AABB 外包围：\(two(aabb.sizeX)) × \(two(aabb.sizeY)) × \(two(aabb.sizeZ)) m",
            "OBB 长宽高：\(two(obbLength)) × \(two(obbWidth)) × \(two(obbHeight)) m",
            "高度场体积：\(three(input.metrics.heightfieldVolumeM3)) m³",
            "表面积：\(three(input.metrics.heightfieldSurfaceAreaM2)) m²",
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
        add("高度场体积", three(input.metrics.heightfieldVolumeM3), "m³")
        add("高度场表面积", three(input.metrics.heightfieldSurfaceAreaM2), "m²")
        add("不规则物体表面积（不含地面/墙面接触）", three(input.metrics.heightfieldSurfaceAreaM2), "m²")
        add("地面接触面积（投影面积）", two(input.metrics.groundContactAreaM2 ?? input.metrics.footprintAreaM2 ?? 0), "m²")
        add("靠墙接触面积", two(input.metrics.wallContactAreaM2 ?? 0), "m²")
        add("占地面积（投影面积）", two(footprint), "m²")
        rows.append([
            XLSXWriter.Cell("备注"),
            XLSXWriter.Cell("不规则物体表面积按高度场顶部表面计算，已扣除地面接触面积与靠墙接触面积。")
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
