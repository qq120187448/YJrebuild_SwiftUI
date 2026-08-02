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

    static func makeWorkbook(sheetName: String, rows: [[Cell]]) throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
        """

        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """

        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="\(xmlEscaped(sheetName))" sheetId="1" r:id="rId1"/>
          </sheets>
        </workbook>
        """

        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
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

        var sheetXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        """

        for (rowIndex, row) in rows.enumerated() {
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

        sheetXML += "</sheetData></worksheet>"

        let entries = [
            MiniZIPWriter.Entry(name: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            MiniZIPWriter.Entry(name: "_rels/.rels", data: Data(rootRels.utf8)),
            MiniZIPWriter.Entry(name: "xl/workbook.xml", data: Data(workbook.utf8)),
            MiniZIPWriter.Entry(name: "xl/_rels/workbook.xml.rels", data: Data(workbookRels.utf8)),
            MiniZIPWriter.Entry(name: "xl/worksheets/sheet1.xml", data: Data(sheetXML.utf8)),
            MiniZIPWriter.Entry(name: "xl/styles.xml", data: Data(styles.utf8))
        ]

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
