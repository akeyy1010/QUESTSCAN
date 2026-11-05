import Foundation

/// Native project storage. Corrupt files are skipped by listing, never silently removed.
/// Explicit deletion requires the same path, UUID and validated document as loading.
enum ScanLibrary {
    enum LibraryError: Error, LocalizedError {
        case documentsUnavailable
        case unsafeDirectory
        case unsafeEntry
        case oversizedFile
        case invalidFormat
        case invalidDocument(String)

        var errorDescription: String? {
            switch self {
            case .documentsUnavailable: return "書類フォルダを開けません。"
            case .unsafeDirectory: return "保存フォルダが安全なフォルダではありません。"
            case .unsafeEntry: return "保存ファイルの場所または ID が不正です。"
            case .oversizedFile: return "保存ファイルが 200 MB の上限を超えています。"
            case .invalidFormat: return "保存ファイルの形式またはバージョンに対応していません。"
            case .invalidDocument(let reason): return "スキャンデータが不正です: \(reason)"
            }
        }
    }

    static let maximumFileBytes = 200 * 1024 * 1024
    static let maximumTriangles = 60_000
    static let maximumVertices = 180_000
    static let maximumParts = 512 // Matches the projector's total grouping budget.
    static let maximumTextureBytes = 32 * 1024 * 1024
    private static let lock = NSLock()

    static func entries() throws -> [LibraryEntry] { try entries(in: directoryURL()) }
    static func save(_ document: SceneDocument) throws { try save(document, in: directoryURL()) }
    static func load(_ entry: LibraryEntry) throws -> SceneDocument { try load(entry, in: directoryURL()) }
    static func delete(_ entry: LibraryEntry) throws { try delete(entry, in: directoryURL()) }

    private static func directoryURL() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw LibraryError.documentsUnavailable
        }
        return documents.appendingPathComponent("QUESTSCAN", isDirectory: true)
    }

    // Directory-injected overloads keep real Documents untouched by portable tests.
    static func entries(in directory: URL) throws -> [LibraryEntry] {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory(directory)
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var result: [LibraryEntry] = []
        for url in urls {
            guard url.pathExtension == "questscan",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  url.lastPathComponent == filename(id) else { continue }
            // An invalid, oversized, symlinked or unsupported file remains on disk.
            guard let document = try? readDocument(at: url, expectedID: id, in: directory) else { continue }
            result.append(LibraryEntry(id: document.id, name: document.name,
                date: document.createdAt, mode: document.mode,
                triangleCount: document.triangleCount, url: url,
                thumbnailJPEG: document.thumbnailJPEG))
        }
        return result.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
        }
    }

    static func save(_ document: SceneDocument, in directory: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try validate(document)
        try ensureDirectory(directory)
        let destination = directory.appendingPathComponent(filename(document.id))
        if FileManager.default.fileExists(atPath: destination.path) || isSymlink(destination) {
            try requireRegularFile(destination)
            // Do not replace corrupt files or a file carrying another document's ID.
            _ = try readDocument(at: destination, expectedID: document.id, in: directory)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumFileBytes else { throw LibraryError.oversizedFile }
        // Foundation's atomic write writes a sibling temporary file then renames it.
        // A failed encode/validation/write leaves the previous project intact.
        try data.write(to: destination, options: [.atomic])
    }

    static func load(_ entry: LibraryEntry, in directory: URL) throws -> SceneDocument {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory(directory)
        return try readDocument(at: entry.url, expectedID: entry.id, in: directory)
    }

    static func delete(_ entry: LibraryEntry, in directory: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory(directory)
        // Never delete by a URL supplied by the UI without verifying file content.
        _ = try readDocument(at: entry.url, expectedID: entry.id, in: directory)
        try requireRegularFile(entry.url)
        try FileManager.default.removeItem(at: entry.url)
    }

    private static func filename(_ id: UUID) -> String { id.uuidString + ".questscan" }

    private static func ensureDirectory(_ url: URL) throws {
        guard url.isFileURL, !url.pathComponents.contains(".."),
              !url.pathComponents.contains("."), !isSymlink(url) else {
            throw LibraryError.unsafeDirectory
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw LibraryError.unsafeDirectory
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func requireRegularFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LibraryError.unsafeEntry
        }
        guard let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              size.int64Value <= Int64(maximumFileBytes) else {
            throw LibraryError.oversizedFile
        }
    }

    private static func readDocument(at url: URL, expectedID: UUID, in directory: URL) throws -> SceneDocument {
        let expected = directory.appendingPathComponent(filename(expectedID))
        // Apple platforms may enumerate /var as /private/var. Compare canonical paths,
        // while still rejecting final symlinks, traversal and mismatched file names.
        guard url.isFileURL, url.lastPathComponent == expected.lastPathComponent,
              !url.pathComponents.contains(".."), !url.pathComponents.contains("."),
              url.standardizedFileURL.resolvingSymlinksInPath().path == expected.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw LibraryError.unsafeEntry
        }
        try requireRegularFile(url) // rejects symbolic links, directories and devices
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        // Bound the actual bytes read too, not just potentially stale file metadata.
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            guard chunk.count <= maximumFileBytes - data.count else { throw LibraryError.oversizedFile }
            data.append(chunk)
        }
        guard !data.isEmpty else { throw LibraryError.invalidFormat }
        let document: SceneDocument
        do { document = try JSONDecoder().decode(SceneDocument.self, from: data) }
        catch { throw LibraryError.invalidFormat }
        guard document.id == expectedID else { throw LibraryError.unsafeEntry }
        try validate(document)
        return document
    }

    /// Shared by export and persistence: never serialize non-finite or unbounded data.
    static func validate(_ document: SceneDocument) throws {
        func fail(_ reason: String) throws { throw LibraryError.invalidDocument(reason) }
        guard document.formatVersion == SceneDocument.currentVersion else { throw LibraryError.invalidFormat }
        guard validName(document.name) else { try fail("名前"); return }
        let date = document.createdAt.timeIntervalSince1970
        guard date.isFinite, (-62_135_596_800...253_402_300_799).contains(date),
              (0...100_000).contains(document.photosCaptured),
              document.coverage.isFinite, (0...1).contains(document.coverage),
              document.surfaceArea.isFinite, (0...100_000_000).contains(document.surfaceArea) else {
            try fail("統計または日時"); return
        }
        guard !document.parts.isEmpty, document.parts.count <= maximumParts else {
            try fail("パーツ数"); return
        }
        if let thumbnail = document.thumbnailJPEG {
            guard !thumbnail.isEmpty, thumbnail.count <= 4 * 1024 * 1024 else {
                try fail("サムネイル"); return
            }
        }
        var partIDs = Set<UUID>()
        var triangles = 0
        var vertices = 0
        var imageBytes = document.thumbnailJPEG?.count ?? 0
        for part in document.parts {
            guard partIDs.insert(part.id).inserted, validName(part.name) else {
                try fail("パーツ ID または名前"); return
            }
            guard !part.vertices.isEmpty, !part.indices.isEmpty,
                  part.vertices.count <= maximumVertices,
                  part.indices.count <= maximumTriangles * 3,
                  part.indices.count % 3 == 0,
                  part.normals.count == part.vertices.count,
                  part.textureCoordinates.isEmpty || part.textureCoordinates.count == part.vertices.count else {
                try fail("メッシュ配列"); return
            }
            triangles += part.indices.count / 3
            vertices += part.vertices.count
            guard triangles <= maximumTriangles, vertices <= maximumVertices else {
                try fail("メッシュサイズ"); return
            }
            guard part.vertices.allSatisfy({ bounded($0.x, 10_000) && bounded($0.y, 10_000) && bounded($0.z, 10_000) }),
                  part.normals.allSatisfy(validNormal),
                  part.textureCoordinates.allSatisfy({ bounded($0.x, 10_000) && bounded($0.y, 10_000) }) else {
                try fail("頂点・法線・UV"); return
            }
            for offset in stride(from: 0, to: part.indices.count, by: 3) {
                let a = part.indices[offset], b = part.indices[offset + 1], c = part.indices[offset + 2]
                guard a < UInt32(part.vertices.count), b < UInt32(part.vertices.count), c < UInt32(part.vertices.count),
                      a != b, b != c, a != c else { try fail("三角形インデックス"); return }
                let p = part.vertices[Int(a)], q = part.vertices[Int(b)], r = part.vertices[Int(c)]
                // Double precision avoids overflow/cancellation in float validation.
                let ux = Double(q.x) - Double(p.x), uy = Double(q.y) - Double(p.y), uz = Double(q.z) - Double(p.z)
                let vx = Double(r.x) - Double(p.x), vy = Double(r.y) - Double(p.y), vz = Double(r.z) - Double(p.z)
                let cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx
                guard cx * cx + cy * cy + cz * cz > 1e-20 else { try fail("面積ゼロの三角形"); return }
            }
            let adjustment = part.adjustment
            guard unit(adjustment.red), unit(adjustment.green), unit(adjustment.blue), unit(adjustment.tintAmount),
                  adjustment.brightness.isFinite, (-1...1).contains(adjustment.brightness),
                  adjustment.contrast.isFinite, (0...3).contains(adjustment.contrast),
                  adjustment.saturation.isFinite, (0...3).contains(adjustment.saturation) else {
                try fail("色調整"); return
            }
            if let texture = part.textureJPEG {
                guard !texture.isEmpty, texture.count <= maximumTextureBytes,
                      part.textureCoordinates.count == part.vertices.count else {
                    try fail("テクスチャまたは UV"); return
                }
                imageBytes += texture.count
                // Base64 in JSON expands bytes by 4/3; leave room for geometry.
                guard imageBytes <= maximumFileBytes / 4 * 3 else { throw LibraryError.oversizedFile }
            }
        }
    }

    private static func validNormal(_ normal: SIMD3<Float>) -> Bool {
        guard bounded(normal.x, 2), bounded(normal.y, 2), bounded(normal.z, 2) else { return false }
        let x = Double(normal.x), y = Double(normal.y), z = Double(normal.z)
        let magnitudeSquared: Double = x * x + y * y + z * z
        return magnitudeSquared > 1e-12
    }

    private static func bounded(_ value: Float, _ limit: Float) -> Bool { value.isFinite && abs(value) <= limit }
    private static func unit(_ value: Float) -> Bool { value.isFinite && (0...1).contains(value) }
    private static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 1024 &&
        !name.unicodeScalars.contains { $0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13 }
    }
}
