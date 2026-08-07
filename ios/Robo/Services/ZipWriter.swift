import Foundation

final class ZipWriter {
    private let fileHandle: FileHandle
    private var entries: [(path: String, offset: UInt64, size: UInt64, crc: UInt32)] = []

    init?(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        fileHandle = handle
    }

    func addFile(at url: URL, path: String) throws {
        let data = try Data(contentsOf: url)
        try addData(data, path: path)
    }

    func addData(_ data: Data, path: String) throws {
        let crc = ZipWriter.crc32(data)
        let offset = try fileHandle.offset()
        var local = Data()
        local.appendUInt32(0x0403_4b50)
        local.appendUInt16(20)
        local.appendUInt16(0)
        local.appendUInt16(0)
        local.appendUInt16(0)
        local.appendUInt16(0)
        local.appendUInt32(crc)
        local.appendUInt32(UInt32(data.count))
        local.appendUInt32(UInt32(data.count))
        local.appendUInt16(UInt16(path.utf8.count))
        local.appendUInt16(0)
        local.append(Data(path.utf8))
        try fileHandle.write(contentsOf: local)
        try fileHandle.write(contentsOf: data)
        entries.append((path, offset, UInt64(data.count), crc))
    }

    func finish() throws {
        let centralStart = try fileHandle.offset()
        for entry in entries {
            var central = Data()
            central.appendUInt32(0x0201_4b50)
            central.appendUInt16(20)
            central.appendUInt16(20)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(entry.crc)
            central.appendUInt32(UInt32(entry.size))
            central.appendUInt32(UInt32(entry.size))
            central.appendUInt16(UInt16(entry.path.utf8.count))
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(0)
            central.appendUInt32(UInt32(entry.offset))
            central.append(Data(entry.path.utf8))
            try fileHandle.write(contentsOf: central)
        }
        let centralEnd = try fileHandle.offset()
        var end = Data()
        end.appendUInt32(0x0605_4b50)
        end.appendUInt16(0)
        end.appendUInt16(0)
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt32(UInt32(centralEnd - centralStart))
        end.appendUInt32(UInt32(centralStart))
        end.appendUInt16(0)
        try fileHandle.write(contentsOf: end)
        try fileHandle.close()
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) == 1 ? 0xedb8_8320 : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return crc ^ 0xffff_ffff
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { buffer in
            append(contentsOf: buffer)
        }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { buffer in
            append(contentsOf: buffer)
        }
    }
}
