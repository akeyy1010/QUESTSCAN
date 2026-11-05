import Foundation

// Standalone portable test executable (no XCTest or Apple rendering SDK required):
// swiftc -swift-version 5 -parse-as-library QUESTSCAN.swiftpm/Export/StoredZIP.swift \
//   Tests/ExportTests.swift -o /tmp/questscan-export-tests
// Optional complete integration suite:
// swiftc -swift-version 5 -D QUESTSCAN_MODEL_TESTS -parse-as-library QUESTSCAN.swiftpm/Models/ScanData.swift \
//   QUESTSCAN.swiftpm/Export/StoredZIP.swift QUESTSCAN.swiftpm/Export/ScanLibrary.swift \
//   QUESTSCAN.swiftpm/Export/USDZExporter.swift Tests/ExportTests.swift -o /tmp/questscan-export-tests
// /tmp/questscan-export-tests [optional-output-directory]
// Supplying an output directory leaves ZIP/USDZ fixtures for independent validators.
@main
enum ExportTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var assertions = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try condition() == false { throw Failure(description: message) }
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        assertions += 1
        do { try body() } catch { return }
        throw Failure(description: "Expected rejection: " + label)
    }

    static func main() throws {
        try testCRC()
        try testZIP()
        #if QUESTSCAN_MODEL_TESTS
        try testUSD()
        try testValidation()
        try testPersistence()
        if CommandLine.arguments.count > 1 { try writeFixtures(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        #endif
        print("PASS: \(assertions) export/persistence assertions")
    }

    #if QUESTSCAN_MODEL_TESTS
    static func document(textured: Bool = false) -> SceneDocument {
        let part = ScenePart(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            name: "壁 \"quoted\"\\path\n日本語", classification: .wall,
            vertices: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1.25, 0, 0), SIMD3<Float>(0, 1, 0)],
            normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: 3), indices: [0, 1, 2],
            textureCoordinates: textured ? [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(0, 1)] : [],
            textureJPEG: textured ? Data([0xFF, 0xD8, 0xFF, 0xD9]) : nil,
            adjustment: ColorAdjustment(red: 1, green: 0.25, blue: 0.5, tintAmount: 1,
                                        brightness: 0, contrast: 1, saturation: 1))
        return SceneDocument(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "部屋 \"name\"\\end\n", createdAt: Date(timeIntervalSince1970: 1_700_000_000), mode: .demo,
            parts: [part], photosCaptured: textured ? 1 : 0, coverage: textured ? 1 : 0, surfaceArea: 0.625)
    }
    #endif

    static func testCRC() throws {
        try check(StoredZIP.crc32(Data()) == 0, "empty CRC")
        try check(StoredZIP.crc32(Data("123456789".utf8)) == 0xCBF4_3926, "CRC32 standard vector")
        try check(StoredZIP.crc32(Data("hello".utf8)) == 0x3610_A686, "CRC32 hello")
        let binary = Data((0..<256).map { UInt8($0) })
        try check(StoredZIP.crc32(binary) == independentCRC(binary), "all byte values CRC")
        print("PASS CRC32")
    }

    static func testZIP() throws {
        var entries = [StoredZIP.Entry(name: "scene.usda", data: Data("#usda 1.0\n".utf8))]
        // Vary both local offset and filename length, including the 1–3 padding case.
        for count in 1...130 {
            entries.append(StoredZIP.Entry(name: "textures/" + String(repeating: "a", count: count) + ".jpeg",
                data: Data(repeating: UInt8(count), count: count)))
        }
        let archive = try StoredZIP.archive(entries: entries)
        let parsed = try parseZIP(archive)
        try check(parsed.count == entries.count, "ZIP entry count")
        for (actual, expected) in zip(parsed, entries) {
            try check(actual.name == expected.name && actual.data == expected.data, "ZIP data round trip")
            try check(actual.offset % 64 == 0, "USDZ absolute data alignment")
        }
        try check(try StoredZIP.archive(entries: entries) == archive, "deterministic ZIP bytes")
        for name in ["../bad.jpeg", "textures/../bad.jpeg", "/absolute.jpeg", "a//b", "a/./b",
                     "a\\b", "file:", "a\u{0000}", "a/", ".hidden", "å.jpeg", "a b.jpeg"] {
            try rejects("filename " + name) {
                _ = try StoredZIP.archive(entries: [entries[0], .init(name: name, data: Data())])
            }
        }
        try rejects("no root") { _ = try StoredZIP.archive(entries: []) }
        try rejects("wrong root") { _ = try StoredZIP.archive(entries: [.init(name: "other.usda", data: Data())]) }
        try rejects("duplicate") { _ = try StoredZIP.archive(entries: [entries[0], entries[0]]) }
        try rejects("case-insensitive duplicate") {
            _ = try StoredZIP.archive(entries: [entries[0], .init(name: "SCENE.USDA", data: Data())])
        }
        try rejects("too many entries") {
            _ = try StoredZIP.archive(entries: [entries[0]] + (0..<StoredZIP.maximumEntries).map {
                .init(name: "textures/t\($0).jpeg", data: Data())
            })
        }
        try rejects("remote destination") {
            try StoredZIP.write(entries: [entries[0]], to: URL(string: "https://example.com/model.usdz")!)
        }
        print("PASS ZIP headers, central directory, CRC, alignment, names")
    }

    #if QUESTSCAN_MODEL_TESTS
    static func testUSD() throws {
        var input = document(textured: true)
        var solid = document().parts[0]
        solid.id = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        input.parts.append(solid)
        let original = input.parts[0].textureJPEG!
        let adjusted = Data([0xFF, 0xD8, 17, 34, 51, 0xFF, 0xD9])
        var calls = 0
        let entries = try USDZExporter.makeEntries(input) { data, adjustment in
            calls += 1
            try check(data == original, "adjustment gets original JPEG")
            try check(adjustment == input.parts[0].adjustment, "adjustment gets selected part values")
            return adjusted
        }
        try check(calls == 1, "one adjustment per textured part")
        try check(entries[0].name == "scene.usda" && entries.count == 2, "root scene first, texture packaged")
        try check(entries[1].data == adjusted, "adjusted JPEG packaged instead of original")
        try check(input.parts[0].textureJPEG == original, "original texture immutable")
        let text = String(decoding: entries[0].data, as: UTF8.self)
        for expected in ["#usda 1.0", "defaultPrim = \"QuestScan\"", "metersPerUnit = 1", "upAxis = \"Y\"",
                         "UsdPreviewSurface", "MaterialBindingAPI", "rel material:binding",
                         "normal3f[] normals", "interpolation = \"vertex\"", "faceVertexIndices = [0, 1, 2]",
                         "faceVertexCounts = [3]", "texCoord2f[] primvars:st = [(0, 0), (1.0, 0), (0, 1.0)]",
                         "UsdPrimvarReader_float2", "string inputs:varname = \"st\"", "float2 outputs:result",
                         "float2 inputs:st.connect", "UsdUVTexture", "inputs:sourceColorSpace = \"sRGB\"",
                         "inputs:wrapS = \"clamp\"", "color3f inputs:emissiveColor.connect", "(1.25, 0, 0)",
                         "\\\"quoted\\\"\\\\path\\n日本語"] {
            try check(text.contains(expected), "USDA contains " + expected)
        }
        try check(text.contains("asset inputs:file = @./" + entries[1].name + "@"), "anchored texture reference")
        try check(!text.contains("nan") && !text.contains("inf,"), "no non-finite literals")
        let zipped = try USDZExporter.makeArchive(input) { _, _ in adjusted }
        let parsed = try parseZIP(zipped)
        try check(parsed[0].data == entries[0].data && parsed[1].data == adjusted, "USDZ archive matches scene/texture")
        try rejects("empty adjusted image") { _ = try USDZExporter.makeEntries(input) { _, _ in Data() } }
        try rejects("adjustment failure propagates") {
            _ = try USDZExporter.makeEntries(input) { _, _ in throw Failure(description: "image decode") }
        }
        try rejects("remote USDZ destination") {
            try USDZExporter.export(input, to: URL(string: "https://example.com/export.usdz")!)
        }
        print("PASS USDA geometry, UV network, binding and edited assets")
    }

    static func testValidation() throws {
        try ScanLibrary.validate(document())
        try ScanLibrary.validate(document(textured: true))
        let mutations: [(String, (inout SceneDocument) -> Void)] = [
            ("unsupported format", { $0.formatVersion += 1 }),
            ("empty scene", { $0.parts = [] }),
            ("empty name", { $0.name = " \n" }),
            ("control name", { $0.name = "bad\u{0000}" }),
            ("large name", { $0.name = String(repeating: "x", count: 1025) }),
            ("invalid date", { $0.createdAt = Date(timeIntervalSince1970: .infinity) }),
            ("NaN coverage", { $0.coverage = .nan }),
            ("negative photos", { $0.photosCaptured = -1 }),
            ("invalid area", { $0.surfaceArea = .infinity }),
            ("NaN vertex", { $0.parts[0].vertices[0].x = .nan }),
            ("unbounded vertex", { $0.parts[0].vertices[0].x = 10_001 }),
            ("missing normals", { $0.parts[0].normals = [] }),
            ("zero normal", { $0.parts[0].normals[0] = .zero }),
            ("infinite normal", { $0.parts[0].normals[0].z = .infinity }),
            ("partial face", { $0.parts[0].indices = [0, 1] }),
            ("out-of-range face", { $0.parts[0].indices = [0, 1, UInt32.max] }),
            ("repeated index", { $0.parts[0].indices = [0, 1, 1] }),
            ("collinear triangle", { $0.parts[0].vertices[2] = SIMD3<Float>(2.5, 0, 0) }),
            ("UV count", { $0.parts[0].textureCoordinates = [SIMD2<Float>(0, 0)] }),
            ("NaN UV", { $0.parts[0].textureCoordinates[0].y = .nan }),
            ("texture without UV", { $0.parts[0].textureCoordinates = [] }),
            ("empty texture", { $0.parts[0].textureJPEG = Data() }),
            ("empty thumbnail", { $0.thumbnailJPEG = Data() }),
            ("NaN adjustment", { $0.parts[0].adjustment.red = .nan }),
            ("unbounded adjustment", { $0.parts[0].adjustment.brightness = 2 }),
            ("duplicate part ID", { $0.parts.append($0.parts[0]) })
        ]
        for (label, mutation) in mutations {
            var invalid = document(textured: true)
            mutation(&invalid)
            try rejects(label) { try ScanLibrary.validate(invalid) }
            try rejects("export " + label) {
                _ = try USDZExporter.makeArchive(invalid) { _, _ in
                    throw Failure(description: "should validate before adjustment")
                }
            }
        }
        print("PASS finite/bounded input and malformed geometry guards")
    }

    static func testPersistence() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("questscan-tests-" + UUID().uuidString)
        let root = temporary.appendingPathComponent("QUESTSCAN", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try check(try ScanLibrary.entries(in: root).isEmpty, "new library empty")
        var value = document()
        try ScanLibrary.save(value, in: root)
        let entries = try ScanLibrary.entries(in: root)
        try check(entries.count == 1 && entries[0].id == value.id, "library save/list")
        let entry = entries[0]
        let loaded = try ScanLibrary.load(entry, in: root)
        try check(loaded.name == value.name && loaded.parts[0].indices == value.parts[0].indices, "JSON geometry round trip")
        value.name = "編集後"
        try ScanLibrary.save(value, in: root)
        try check(try ScanLibrary.load(entry, in: root).name == value.name, "atomic update")
        let goodBytes = try Data(contentsOf: entry.url)
        var invalid = value; invalid.parts[0].indices[2] = UInt32.max
        try rejects("invalid replacement") { try ScanLibrary.save(invalid, in: root) }
        try check(try Data(contentsOf: entry.url) == goodBytes, "failed save keeps previous document")

        var forged = entry; forged.id = UUID()
        try rejects("forged ID load") { _ = try ScanLibrary.load(forged, in: root) }
        try rejects("forged ID delete") { try ScanLibrary.delete(forged, in: root) }
        try check(FileManager.default.fileExists(atPath: entry.url.path), "forged deletion preserves file")

        let outside = temporary.appendingPathComponent("outside.questscan")
        try goodBytes.write(to: outside)
        var foreign = entry; foreign.url = outside
        try rejects("foreign load") { _ = try ScanLibrary.load(foreign, in: root) }
        try rejects("foreign delete") { try ScanLibrary.delete(foreign, in: root) }
        try check(FileManager.default.fileExists(atPath: outside.path), "foreign file preserved")
        foreign.url = root.appendingPathComponent("../outside.questscan")
        try rejects("traversal delete") { try ScanLibrary.delete(foreign, in: root) }

        let corruptID = UUID()
        let corruptURL = root.appendingPathComponent(corruptID.uuidString + ".questscan")
        let corruptBytes = Data("{broken JSON".utf8)
        try corruptBytes.write(to: corruptURL)
        let corruptEntry = LibraryEntry(id: corruptID, name: "broken", date: Date(), mode: .demo,
                                       triangleCount: 0, url: corruptURL, thumbnailJPEG: nil)
        try check(try ScanLibrary.entries(in: root).count == 1, "list skips corrupt file")
        try rejects("corrupt load") { _ = try ScanLibrary.load(corruptEntry, in: root) }
        try rejects("corrupt deletion") { try ScanLibrary.delete(corruptEntry, in: root) }
        try check(try Data(contentsOf: corruptURL) == corruptBytes, "corrupt file never silently deleted")
        var replacement = value; replacement.id = corruptID
        try rejects("overwrite corrupt file") { try ScanLibrary.save(replacement, in: root) }

        let mismatchID = UUID()
        let mismatchURL = root.appendingPathComponent(mismatchID.uuidString + ".questscan")
        try goodBytes.write(to: mismatchURL)
        let mismatch = LibraryEntry(id: mismatchID, name: "wrong", date: Date(), mode: .demo,
                                    triangleCount: 1, url: mismatchURL, thumbnailJPEG: nil)
        try rejects("embedded UUID mismatch") { _ = try ScanLibrary.load(mismatch, in: root) }
        try rejects("embedded UUID mismatch deletion") { try ScanLibrary.delete(mismatch, in: root) }

        let linkID = UUID()
        let link = root.appendingPathComponent(linkID.uuidString + ".questscan")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let linked = LibraryEntry(id: linkID, name: "link", date: Date(), mode: .demo,
                                  triangleCount: 1, url: link, thumbnailJPEG: nil)
        try rejects("symlink load") { _ = try ScanLibrary.load(linked, in: root) }
        try rejects("symlink delete") { try ScanLibrary.delete(linked, in: root) }
        var symlinkSave = value; symlinkSave.id = linkID
        try rejects("symlink save") { try ScanLibrary.save(symlinkSave, in: root) }
        let directoryLink = temporary.appendingPathComponent("linked-library")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        try rejects("symlink directory") { _ = try ScanLibrary.entries(in: directoryLink) }

        let hugeID = UUID()
        let hugeURL = root.appendingPathComponent(hugeID.uuidString + ".questscan")
        try Data([0]).write(to: hugeURL)
        let handle = try FileHandle(forWritingTo: hugeURL)
        try handle.truncate(atOffset: UInt64(ScanLibrary.maximumFileBytes) + 1)
        try handle.close()
        let huge = LibraryEntry(id: hugeID, name: "large", date: Date(), mode: .demo,
                               triangleCount: 0, url: hugeURL, thumbnailJPEG: nil)
        try rejects("200 MB file guard") { _ = try ScanLibrary.load(huge, in: root) }
        try rejects("oversized deletion") { try ScanLibrary.delete(huge, in: root) }
        try check(try ScanLibrary.entries(in: root).count == 1, "listing skips all unsafe entries")
        try check(FileManager.default.fileExists(atPath: hugeURL.path), "oversized file preserved")
        try ScanLibrary.delete(entry, in: root)
        try check(!FileManager.default.fileExists(atPath: entry.url.path), "validated delete works")
        print("PASS atomic JSON, corruption, IDs, traversal, symlinks and 200 MB limit")
    }
    #endif

    struct ParsedEntry { let name: String; let data: Data; let offset: Int }
    static func parseZIP(_ data: Data) throws -> [ParsedEntry] {
        let bytes = Array(data)
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        try check(bytes.count >= 22, "EOCD fits")
        let end = bytes.count - 22
        try check(u32(end) == 0x06054B50 && u16(end + 20) == 0, "EOCD signature/no comment")
        let count = u16(end + 10)
        try check(u16(end + 8) == count && u16(end + 4) == 0 && u16(end + 6) == 0, "single disk")
        let directoryOffset = Int(u32(end + 16)), directoryLength = Int(u32(end + 12))
        try check(directoryOffset + directoryLength == end, "central directory exact length")
        var directory = directoryOffset
        var result: [ParsedEntry] = []
        for _ in 0..<count {
            try check(directory + 46 <= end && u32(directory) == 0x02014B50, "central header")
            let nameLength = u16(directory + 28), extraLength = u16(directory + 30), commentLength = u16(directory + 32)
            let name = String(decoding: bytes[(directory + 46)..<(directory + 46 + nameLength)], as: UTF8.self)
            let local = Int(u32(directory + 42))
            try check(u32(local) == 0x04034B50 && u16(local + 8) == 0 && u16(directory + 10) == 0, "stored local/central method")
            try check(u16(local + 6) == 0x0800 && u16(directory + 8) == 0x0800, "UTF8/no encryption/no descriptor")
            try check(u16(local + 26) == nameLength, "name lengths agree")
            let localName = String(decoding: bytes[(local + 30)..<(local + 30 + nameLength)], as: UTF8.self)
            try check(localName == name, "local/central names agree")
            let extra = u16(local + 28)
            var extraOffset = local + 30 + nameLength
            let dataOffset = extraOffset + extra
            while extraOffset < dataOffset {
                try check(extraOffset + 4 <= dataOffset, "padding has real extra-field header")
                let payloadLength = u16(extraOffset + 2)
                extraOffset += 4 + payloadLength
                try check(extraOffset <= dataOffset, "extra field payload fits")
            }
            let size = Int(u32(local + 22))
            try check(u32(local + 18) == UInt32(size) && u32(directory + 20) == UInt32(size) &&
                      u32(directory + 24) == UInt32(size), "stored sizes agree")
            try check(dataOffset + size <= directoryOffset, "file payload inside local region")
            let payload = Data(bytes[dataOffset..<(dataOffset + size)])
            try check(u32(local + 14) == independentCRC(payload) && u32(directory + 16) == u32(local + 14), "independent local/central CRC")
            if result.isEmpty { try check(name == "scene.usda" && local == 0, "root layer first") }
            result.append(ParsedEntry(name: name, data: payload, offset: dataOffset))
            directory += 46 + nameLength + extraLength + commentLength
        }
        try check(directory == end, "all central records consumed")
        return result
    }

    static func independentCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }

    #if QUESTSCAN_MODEL_TESTS
    static func writeFixtures(to output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let untextured = document()
        try USDZExporter.export(untextured, to: output.appendingPathComponent("solid.usdz"))
        let textured = document(textured: true)
        let archive = try USDZExporter.makeArchive(textured) { data, _ in data }
        try archive.write(to: output.appendingPathComponent("textured-test.usdz"))
        let entries = try USDZExporter.makeEntries(untextured) { data, _ in data }
        try entries[0].data.write(to: output.appendingPathComponent("scene.usda"))
        print("Portable fixtures: " + output.path + " (textured fixture uses an injected test byte sequence, not a decoded photo)")
    }
    #endif
}
