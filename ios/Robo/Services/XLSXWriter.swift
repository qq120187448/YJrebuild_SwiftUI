import Foundation

enum XLSXWriter {
    struct Cell {
        let text: String
        let bold: Bool

        init(_ text: String, bold: Bool = false) {
            self.text = text
            self.bold = bold
        }
    }

    struct ImageAttachment {
        let label: String
        let data: Data
        let fileExtension: String
    }

    struct Sheet {
        let name: String
        let rows: [[Cell]]
        let images: [ImageAttachment]

        init(name: String, rows: [[Cell]], images: [ImageAttachment] = []) {
            self.name = name
            self.rows = rows
            self.images = images
        }
    }

    static func makeWorkbook(sheets: [Sheet]) throws -> Data {
        var contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Default Extension="jpg" ContentType="image/jpeg"/>
          <Default Extension="png" ContentType="image/png"/>
        """

        for (index, _) in sheets.enumerated() {
            let sheetNumber = index + 1
            contentTypes += """
            <Override PartName="/xl/worksheets/sheet\(sheetNumber).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            """
            if !sheets[index].images.isEmpty {
                contentTypes += """
                <Override PartName="/xl/drawings/drawing\(sheetNumber).xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>
                """
            }
        }
        contentTypes += """
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
        """

        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """

        var workbookSheets = ""
        for (index, sheet) in sheets.enumerated() {
            let sheetNumber = index + 1
            workbookSheets += """
            <sheet name="\(xmlEscaped(sheet.name))" sheetId="\(sheetNumber)" r:id="rId\(sheetNumber)"/>
            """
        }

        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>\(workbookSheets)</sheets>
        </workbook>
        """

        var workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """
        for (index, _) in sheets.enumerated() {
            let sheetNumber = index + 1
            workbookRels += """
            <Relationship Id="rId\(sheetNumber)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\(sheetNumber).xml"/>
            """
        }
        workbookRels += """
          <Relationship Id="rId\(sheets.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """

        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="2">
            <font><sz val="11"/><name val="Calibri"/></font>
            <font><b/><sz val="11"/><name val="Calibri"/></font>
          </fonts>
          <fills count="2">
            <fill><patternFill patternType="none"/></fill>
            <fill><patternFill patternType="gray125"/></fill>
          </fills>
          <borders count="1"><border/></borders>
          <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
          <cellXfs count="2">
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
            <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
          </cellXfs>
        </styleSheet>
        """

        var entries: [MiniZIPWriter.Entry] = [
            MiniZIPWriter.Entry(name: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            MiniZIPWriter.Entry(name: "_rels/.rels", data: Data(rootRels.utf8)),
            MiniZIPWriter.Entry(name: "xl/workbook.xml", data: Data(workbook.utf8)),
            MiniZIPWriter.Entry(name: "xl/_rels/workbook.xml.rels", data: Data(workbookRels.utf8)),
            MiniZIPWriter.Entry(name: "xl/styles.xml", data: Data(styles.utf8))
        ]

        var mediaIndex = 1
        for (sheetIndex, sheet) in sheets.enumerated() {
            let sheetNumber = sheetIndex + 1
            var sheetXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheetData>
            """

            for (rowIndex, row) in sheet.rows.enumerated() {
                let rowNumber = rowIndex + 1
                sheetXML += "<row r=\"\(rowNumber)\">"
                for (colIndex, cell) in row.enumerated() {
                    let ref = columnName(colIndex) + "\(rowNumber)"
                    let style = cell.bold ? " s=\"1\"" : ""
                    let value = xmlEscaped(cell.text)
                    sheetXML += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(value)</t></is></c>"
                }
                sheetXML += "</row>"
            }

            if sheet.images.isEmpty {
                sheetXML += "</sheetData></worksheet>"
            } else {
                sheetXML += "</sheetData>"

                var drawingXML = """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
                """

                var drawingRels = """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                """

                var sheetRels = """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing\(sheetNumber).xml"/>
                </Relationships>
                """

                let baseRow = sheet.rows.count + 1
                for (imageIndex, image) in sheet.images.enumerated() {
                    let imageNumber = mediaIndex
                    let fileName = "image\(imageNumber).\(image.fileExtension)"
                    let startRow = baseRow + imageIndex * 13
                    let endRow = startRow + 12
                    let imageId = imageIndex + 1

                    drawingXML += """
                    <xdr:twoCellAnchor editAs="oneCell">
                      <xdr:from><xdr:col>1</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(startRow)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>
                      <xdr:to><xdr:col>7</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(endRow)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>
                      <xdr:pic>
                        <xdr:nvPicPr>
                          <xdr:cNvPr id="\(imageId)" name="\(xmlEscaped(image.label))"/>
                          <xdr:cNvPicPr><a:picLocks noChangeAspect="1"/></xdr:cNvPicPr>
                        </xdr:nvPicPr>
                        <xdr:blipFill><a:blip r:embed="rId\(imageId)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>
                        <xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1524000" cy="1143000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr>
                      </xdr:pic>
                      <xdr:clientData/>
                    </xdr:twoCellAnchor>
                    """

                    drawingRels += """
                    <Relationship Id="rId\(imageId)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/\(fileName)"/>
                    """

                    entries.append(MiniZIPWriter.Entry(name: "xl/media/\(fileName)", data: image.data))
                    mediaIndex += 1
                }

                drawingXML += "</xdr:wsDr>"
                drawingRels += "</Relationships>"

                entries.append(MiniZIPWriter.Entry(
                    name: "xl/drawings/drawing\(sheetNumber).xml",
                    data: Data(drawingXML.utf8)
                ))
                entries.append(MiniZIPWriter.Entry(
                    name: "xl/drawings/_rels/drawing\(sheetNumber).xml.rels",
                    data: Data(drawingRels.utf8)
                ))
                entries.append(MiniZIPWriter.Entry(
                    name: "xl/worksheets/_rels/sheet\(sheetNumber).xml.rels",
                    data: Data(sheetRels.utf8)
                ))

                sheetXML += "<drawing r:id=\"rId1\"/></worksheet>"
            }

            entries.append(MiniZIPWriter.Entry(
                name: "xl/worksheets/sheet\(sheetNumber).xml",
                data: Data(sheetXML.utf8)
            ))
        }

        return MiniZIPWriter.archive(entries: entries)
    }

    private static func columnName(_ index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var result = ""
        var value = index
        repeat {
            result = String(letters[value % 26]) + result
            value = value / 26 - 1
        } while value >= 0
        return result
    }

    private static func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

enum MiniZIPWriter {
    struct Entry {
        let name: String
        let data: Data
    }

    static func archive(entries: [Entry]) -> Data {
        var output = Data()
        var centralDirectory = Data()
        var offset: UInt32 = 0
        let now = Date()
        let time = dosTime(from: now)
        let date = dosDate(from: now)

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = crc32(entry.data)

            var local = Data()
            local.appendLittleEndian(UInt32(0x04034b50))
            local.appendLittleEndian(UInt16(20))
            local.appendLittleEndian(UInt16(0x0800))
            local.appendLittleEndian(UInt16(0))
            local.appendLittleEndian(time)
            local.appendLittleEndian(date)
            local.appendLittleEndian(crc)
            local.appendLittleEndian(UInt32(entry.data.count))
            local.appendLittleEndian(UInt32(entry.data.count))
            local.appendLittleEndian(UInt16(nameData.count))
            local.appendLittleEndian(UInt16(0))

            output.append(local)
            output.append(nameData)
            output.append(entry.data)

            var central = Data()
            central.appendLittleEndian(UInt32(0x02014b50))
            central.appendLittleEndian(UInt16(20))
            central.appendLittleEndian(UInt16(20))
            central.appendLittleEndian(UInt16(0x0800))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(time)
            central.appendLittleEndian(date)
            central.appendLittleEndian(crc)
            central.appendLittleEndian(UInt32(entry.data.count))
            central.appendLittleEndian(UInt32(entry.data.count))
            central.appendLittleEndian(UInt16(nameData.count))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt32(0))
            central.appendLittleEndian(UInt32(offset))

            centralDirectory.append(central)
            centralDirectory.append(nameData)

            offset += UInt32(local.count + nameData.count + entry.data.count)
        }

        let centralSize = UInt32(centralDirectory.count)
        let entryCount = UInt16(entries.count)

        var end = Data()
        end.appendLittleEndian(UInt32(0x06054b50))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(entryCount)
        end.appendLittleEndian(entryCount)
        end.appendLittleEndian(centralSize)
        end.appendLittleEndian(offset)
        end.appendLittleEndian(UInt16(0))

        output.append(centralDirectory)
        output.append(end)
        return output
    }

    private static func dosTime(from date: Date) -> UInt16 {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let hour = UInt16(components.hour ?? 0)
        let minute = UInt16(components.minute ?? 0)
        let second = UInt16((components.second ?? 0) / 2)
        return (hour << 11) | (minute << 5) | second
    }

    private static func dosDate(from date: Date) -> UInt16 {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = UInt16(max(0, (components.year ?? 1980) - 1980))
        let month = UInt16(components.month ?? 1)
        let day = UInt16(components.day ?? 1)
        return (year << 9) | (month << 5) | day
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var crc = UInt32(index)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
            return crc
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
