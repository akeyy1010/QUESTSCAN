import Foundation

/// A deliberately small, Foundation-only ZIP writer for USDZ packages.
/// No compression, encryption, data descriptors, ZIP64, extraction, or filesystem paths.
struct StoredZIP {
    struct Entry {
        let name: String
        let data: Data

        init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    enum ArchiveError: Error, LocalizedError {
        case missingRootLayer
        case unsafeFilename(String)
        case duplicateFilename(String)
        case tooManyEntries
        case tooLarge
        case invalidDestination

        var errorDescription: String? {
            switch self {
            case .missingRootLayer: return "USDZ の先頭には scene.usda が必要です。"
            case .unsafeFilename: return "アーカイブ内のファイル名が安全ではありません。"
            case .duplicateFilename: return "アーカイブ内のファイル名が重複しています。"
            case .tooManyEntries: return "書き出すファイル数が上限を超えています。"
            case .tooLarge: return "書き出すデータが 200 MB の上限を超えています。"
            case .invalidDestination: return "書き出し先がローカルファイルではありません。"
            }
        }
    }

    static let maximumArchiveBytes = 200 * 1024 * 1024
    static let maximumEntries = 4097

    /// ASCII-only, relative file paths, with no directory entries or traversal.
    /// Case-insensitive duplicate rejection also protects case-insensitive extractors.
    static func isSafeFilename(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 1024,
              bytes.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                  (48...57).contains(byte) || byte == 45 || byte == 46 ||
                  byte == 47 || byte == 95
              }) else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
        }
    }

    /// ISO-HDLC CRC32, the checksum required by ZIP, not CRC32C.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB8_8320
        }
        return crc
    }

    static func archive(entries: [Entry]) throws -> Data {
        guard entries.first?.name == "scene.usda" else {
            throw ArchiveError.missingRootLayer
        }
        guard entries.count <= maximumEntries else { throw ArchiveError.tooManyEntries }
        var filenames = Set<String>()
        // Validate everything before allocating the archive or computing checksums.
        var estimatedBytes = 22
        for entry in entries {
            guard isSafeFilename(entry.name) else { throw ArchiveError.unsafeFilename(entry.name) }
            guard filenames.insert(entry.name.lowercased()).inserted else {
                throw ArchiveError.duplicateFilename(entry.name)
            }
            // 30-byte local header, <=67 bytes alignment, 46-byte central header.
            let overhead = 30 + 67 + 46 + entry.name.utf8.count * 2
            guard entry.data.count <= maximumArchiveBytes,
                  estimatedBytes <= maximumArchiveBytes - overhead,
                  entry.data.count <= maximumArchiveBytes - overhead - estimatedBytes else {
                throw ArchiveError.tooLarge
            }
            estimatedBytes += entry.data.count + overhead
        }

        struct Record {
            let name: Data
            let crc: UInt32
            let size: UInt32
            let offset: UInt32
        }
        var records: [Record] = []
        var archive = Data()
        archive.reserveCapacity(estimatedBytes)
        for entry in entries {
            let name = Data(entry.name.utf8)
            let offset = UInt32(archive.count)
            let size = UInt32(entry.data.count)
            let crc = crc32(entry.data)
            let base = archive.count + 30 + name.count
            var extraLength = (64 - (base % 64)) % 64
            // A ZIP extra field is an ID + length + payload; 1–3 raw padding bytes
            // would not be valid ZIP. Advance to the following boundary instead.
            if extraLength > 0 && extraLength < 4 { extraLength += 64 }

            appendLE(UInt32(0x04034B50), to: &archive)
            appendLE(UInt16(20), to: &archive) // version needed
            appendLE(UInt16(0x0800), to: &archive) // UTF-8 filenames
            appendLE(UInt16(0), to: &archive) // stored (uncompressed)
            appendLE(UInt16(0), to: &archive) // 00:00:00
            appendLE(UInt16(0x0021), to: &archive) // 1980-01-01, valid DOS date
            appendLE(crc, to: &archive)
            appendLE(size, to: &archive)
            appendLE(size, to: &archive)
            appendLE(UInt16(name.count), to: &archive)
            appendLE(UInt16(extraLength), to: &archive)
            archive.append(name)
            if extraLength > 0 {
                appendLE(UInt16(0x1986), to: &archive) // private alignment field
                appendLE(UInt16(extraLength - 4), to: &archive)
                archive.append(Data(repeating: 0, count: extraLength - 4))
            }
            assert(archive.count % 64 == 0)
            archive.append(entry.data)
            records.append(Record(name: name, crc: crc, size: size, offset: offset))
        }

        let directoryOffset = UInt32(archive.count)
        for record in records {
            appendLE(UInt32(0x02014B50), to: &archive)
            appendLE(UInt16(20), to: &archive) // made by DOS, ZIP 2.0
            appendLE(UInt16(20), to: &archive)
            appendLE(UInt16(0x0800), to: &archive)
            appendLE(UInt16(0), to: &archive) // method
            appendLE(UInt16(0), to: &archive) // time
            appendLE(UInt16(0x0021), to: &archive) // date
            appendLE(record.crc, to: &archive)
            appendLE(record.size, to: &archive)
            appendLE(record.size, to: &archive)
            appendLE(UInt16(record.name.count), to: &archive)
            appendLE(UInt16(0), to: &archive) // central extra length
            appendLE(UInt16(0), to: &archive) // comment length
            appendLE(UInt16(0), to: &archive) // start disk
            appendLE(UInt16(0), to: &archive) // internal attributes
            appendLE(UInt32(0), to: &archive) // regular file, no permissions
            appendLE(record.offset, to: &archive)
            archive.append(record.name)
        }
        let directorySize = UInt32(archive.count) - directoryOffset
        appendLE(UInt32(0x06054B50), to: &archive)
        appendLE(UInt16(0), to: &archive) // disk
        appendLE(UInt16(0), to: &archive) // directory disk
        appendLE(UInt16(records.count), to: &archive)
        appendLE(UInt16(records.count), to: &archive)
        appendLE(directorySize, to: &archive)
        appendLE(directoryOffset, to: &archive)
        appendLE(UInt16(0), to: &archive) // no archive comment
        guard archive.count <= maximumArchiveBytes else { throw ArchiveError.tooLarge }
        return archive
    }

    static func write(entries: [Entry], to url: URL) throws {
        guard url.isFileURL else { throw ArchiveError.invalidDestination }
        try archive(entries: entries).write(to: url, options: .atomic)
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
