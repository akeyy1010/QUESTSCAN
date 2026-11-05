// Run on macOS from the repository root (no UIKit/RealityKit or device required):
// swiftc -swift-version 5 -parse-as-library QUESTSCAN.swiftpm/Models/ScanData.swift \
//   QUESTSCAN.swiftpm/Processing/DemoScene.swift QUESTSCAN.swiftpm/Processing/TextureProjector.swift \
//   QUESTSCAN.swiftpm/Export/ScanLibrary.swift QUESTSCAN.swiftpm/Export/StoredZIP.swift \
//   QUESTSCAN.swiftpm/Export/USDZExporter.swift Tests/ProcessingTests.swift -o /tmp/questscan-processing-tests
// /tmp/questscan-processing-tests
import Foundation
import CoreGraphics
import ImageIO
import simd

@main
struct ProcessingTests {
    static func main() throws {
        try demoGeometry()
        let red = try jpeg(width: 100, height: 80, red: 0.8, blue: 0.1)
        let blue = try jpeg(width: 100, height: 80, red: 0.1, blue: 0.8)
        try projectionAndDepth(red: red)
        try cameraTransformAndResize(red: red)
        try bestPhotoAndAttributes(red: red, blue: blue)
        try budgetsAndMalformedGeometry(red: red)
        if CommandLine.arguments.count > 1 {
            let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try USDZExporter.export(DemoScene.make(), to: output.appendingPathComponent("demo-room.usdz"))
            let realPhoto = try build([triangle()], [snapshot(jpeg: red)]).document
            let archive = try USDZExporter.makeArchive(realPhoto) { data, adjustment in
                try expect(adjustment == .identity, "Fixture must use original photo colors")
                return data
            }
            try archive.write(to: output.appendingPathComponent("real-photo.usdz"), options: [.atomic])
        }
        print("PASS: demo, winding/normals, raw-camera UVs, transform/resize, depth, best photo, grouping, 60k/512 budgets")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "ProcessingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private static func near(_ a: Float, _ b: Float, tolerance: Float = 0.0001) -> Bool {
        abs(a - b) < tolerance
    }

    private static func demoGeometry() throws {
        let demo = DemoScene.make()
        try ScanLibrary.validate(demo)
        try expect(demo.mode == .demo, "Demo must not claim to be a captured scan")
        try expect(demo.photosCaptured == 0 && demo.coverage == 0 && demo.surfaceArea == 0,
                   "Demo must not fabricate capture metrics")
        try expect(demo.parts.count >= 20 && demo.parts.count <= 512, "Demo should be designed but bounded")
        try expect(demo.triangleCount < 60_000, "Demo exceeds rendering limit")
        try expect(demo.parts.allSatisfy { $0.name.hasPrefix("デモ・") && $0.textureJPEG == nil },
                   "Every demo piece must be clearly labeled and procedural")
        for part in demo.parts {
            for normal in part.normals {
                try expect(near(simd_length(normal), 1, tolerance: 0.0002), "Non-unit demo normal in \(part.name)")
            }
            for offset in stride(from: 0, to: part.indices.count, by: 3) {
                let a = Int(part.indices[offset]), b = Int(part.indices[offset + 1]), c = Int(part.indices[offset + 2])
                let cross = simd_cross(part.vertices[b] - part.vertices[a], part.vertices[c] - part.vertices[a])
                try expect(simd_length_squared(cross) > 1e-20, "Degenerate demo triangle in \(part.name)")
                let meanNormal = part.normals[a] + part.normals[b] + part.normals[c]
                try expect(simd_dot(cross, meanNormal) > 0, "Winding disagrees with outward normals in \(part.name)")
            }
        }
        let encoded = try JSONEncoder().encode(demo)
        let decoded = try JSONDecoder().decode(SceneDocument.self, from: encoded)
        try ScanLibrary.validate(decoded)
        try expect(decoded.triangleCount == demo.triangleCount, "Demo JSON round-trip changed geometry")
        print("Demo: \(demo.parts.count) parts, \(demo.triangleCount) triangles, \(encoded.count) JSON bytes")
    }

    private static func projectionAndDepth(red: Data) throws {
        let mesh = triangle()
        let camera = snapshot(jpeg: red)
        var progressValues: [Double] = []
        let result = try TextureProjector.build(meshes: [mesh], photos: [camera], mode: .lidar, name: " UV ") {
            progressValues.append($0)
        }
        try ScanLibrary.validate(result.document)
        try expect(result.document.name == "UV", "Name should be trimmed")
        try expect(result.document.parts.count == 1 && result.document.texturedTriangleCount == 1, "Front-facing triangle should project")
        try expect(result.document.coverage == 1, "Coverage must be observed textured surface fraction")
        let part = result.document.parts[0]
        // Original 100x80 intrinsics: raw top-left coordinates are (.3,.75), (.7,.75), (.5,.25).
        let expected: [SIMD2<Float>] = [[0.3, 0.25], [0.7, 0.25], [0.5, 0.75]]
        for index in 0..<3 {
            try expect(near(part.textureCoordinates[index].x, expected[index].x) &&
                       near(part.textureCoordinates[index].y, expected[index].y), "UV must flip raw image Y exactly once")
            try expect(part.vertices[index] == mesh.vertices[index], "Projection must preserve copied world positions")
        }
        try expect(progressValues.first == 0 && progressValues.last == 1, "Progress endpoints missing")
        try expect(zip(progressValues, progressValues.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 }, "Progress must be monotonic")

        var depthCamera = camera
        depthCamera.depthWidth = 10; depthCamera.depthHeight = 8
        depthCamera.depth = Array(repeating: 2, count: 80)
        let consistent = try build([mesh], [depthCamera])
        try expect(consistent.document.texturedTriangleCount == 1, "Depth agreement should keep texture")
        depthCamera.depth = Array(repeating: 1, count: 80)
        let occluded = try build([mesh], [depthCamera])
        try expect(occluded.document.triangleCount == 1 && occluded.document.texturedTriangleCount == 0,
                   "Foreground depth must reject texture, not discard geometry")
        try expect(occluded.warnings.contains { $0.contains("投影できる写真") }, "No-texture warning missing")
        depthCamera.depth = Array(repeating: 3, count: 80)
        try expect(try build([mesh], [depthCamera]).document.texturedTriangleCount == 0,
                   "Depth disagreement in front of the measured surface must also reject texture")
        depthCamera.depth = Array(repeating: 0, count: 80)
        try expect(try build([mesh], [depthCamera]).document.texturedTriangleCount == 1,
                   "Invalid depth is unknown, not automatic occlusion")
        depthCamera.depth = Array(repeating: .nan, count: 80)
        try expect(try build([mesh], [depthCamera]).document.texturedTriangleCount == 1, "NaN depth must be safe")
        depthCamera.depth = [2] // Mismatched depth shape is ignored safely.
        try expect(try build([mesh], [depthCamera]).document.texturedTriangleCount == 1, "Malformed depth shape must be ignored")

        var outside = mesh
        outside.vertices[0].x = -3
        try expect(try build([outside], [camera]).document.texturedTriangleCount == 0, "Any off-frame vertex rejects the photo")
        var behind = mesh
        behind.vertices = mesh.vertices.map { SIMD3<Float>($0.x, $0.y, 2) }
        behind.normals = Array(repeating: [0, 0, -1], count: 3)
        try expect(try build([behind], [camera]).document.texturedTriangleCount == 0, "Positive camera Z must not project")
        var corruptCamera = camera
        corruptCamera.transform = Array(repeating: 0, count: 16)
        try expect(try build([mesh], [corruptCamera]).document.texturedTriangleCount == 0, "Singular camera transform must be ignored")
    }

    private static func cameraTransformAndResize(red: Data) throws {
        let original = triangle()
        var moved = original
        moved.vertices = original.vertices.map { $0 + SIMD3<Float>(1, 0.2, -0.3) }
        var translated = snapshot(jpeg: red)
        translated.transform[12] = 1; translated.transform[13] = 0.2; translated.transform[14] = -0.3
        let expected = try build([original], [snapshot(jpeg: red)]).document.parts[0].textureCoordinates
        let actual = try build([moved], [translated]).document.parts[0].textureCoordinates
        for index in expected.indices {
            try expect(simd_length(expected[index] - actual[index]) < 0.0001, "World-to-camera inverse translation is incorrect")
        }
        // Original sensor image was 200x160; stored JPEG is 100x80 with identical aspect.
        var resized = snapshot(jpeg: red)
        resized.width = 200; resized.height = 160
        resized.intrinsics = [160, 0, 0, 0, 160, 0, 100, 80, 1]
        let resizedUVs = try build([original], [resized]).document.parts[0].textureCoordinates
        for index in expected.indices {
            try expect(simd_length(expected[index] - resizedUVs[index]) < 0.0001, "JPEG resizing must not alter normalized UVs")
        }
        // A +90 degree world Y camera rotation looks toward -X. Rotate the triangle too.
        var rotated = original
        rotated.vertices = original.vertices.map { SIMD3<Float>($0.z, $0.y, -$0.x) }
        rotated.normals = Array(repeating: [1, 0, 0], count: 3)
        var rotatedCamera = snapshot(jpeg: red)
        rotatedCamera.transform = [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1]
        let rotatedUVs = try build([rotated], [rotatedCamera]).document.parts[0].textureCoordinates
        for index in expected.indices {
            try expect(simd_length(expected[index] - rotatedUVs[index]) < 0.0001, "Column-major camera rotation inverse is incorrect")
        }
    }

    private static func bestPhotoAndAttributes(red: Data, blue: Data) throws {
        var mesh = triangle()
        let custom = simd_normalize(SIMD3<Float>(0.2, 0, 1))
        mesh.normals = Array(repeating: custom, count: 3)
        var sharper = snapshot(jpeg: blue)
        sharper.intrinsics[0] = 100; sharper.intrinsics[4] = 100
        let result = try build([mesh], [snapshot(jpeg: red), sharper])
        try expect(result.document.parts[0].textureJPEG == blue, "Best projected pixel area should win, not the first photo")
        try expect(simd_length(result.document.parts[0].normals[0] - custom) < 0.0001,
                   "Per-vertex normal attribute was flattened")
        var classified = mesh
        classified.indices += mesh.indices
        classified.classifications = [.wall, .floor]
        var secondAnchor = mesh
        secondAnchor.id = UUID()
        let grouped = try build([classified, secondAnchor], [snapshot(jpeg: red)])
        try ScanLibrary.validate(grouped.document)
        try expect(grouped.document.parts.count == 3, "Anchor and classification boundaries must remain separate")
        try expect(grouped.document.parts.filter { $0.classification == .floor }.count == 1, "Classification was lost")
        try expect(grouped.document.triangleCount == 3, "Grouping lost geometry")
    }

    private static func budgetsAndMalformedGeometry(red: Data) throws {
        var large = triangle()
        large.indices = []
        large.classifications = []
        for _ in 0..<61_001 { large.indices.append(contentsOf: [0, 1, 2]) }
        let capped = try build([large], [])
        try ScanLibrary.validate(capped.document)
        try expect(capped.document.triangleCount == 60_000, "Global face cap must be exactly enforced")
        try expect(capped.document.parts[0].vertices.count == 3, "Source-index remapping should preserve shared vertices")
        try expect(capped.warnings.contains { $0.contains("60,000") }, "Decimation must be disclosed")
        var malformed = triangle()
        malformed.indices += [0, 1, 999]
        let repaired = try build([malformed], [])
        try expect(repaired.document.triangleCount == 1 && !repaired.warnings.isEmpty, "Malformed sampled face should be skipped safely")

        // 48 anchors * 8 classifications. Each class has one visible and one out-of-frame
        // face: 128 textured buckets + 384 untextured buckets must fit exactly 512 parts.
        var anchors: [MeshSnapshot] = []
        for _ in 0..<48 {
            var mesh = triangle()
            mesh.vertices = mesh.vertices + mesh.vertices.map { $0 + SIMD3<Float>(-4, 0, 0) }
            mesh.normals = mesh.normals + mesh.normals
            mesh.indices = []
            mesh.classifications = []
            for kind in SurfaceKind.allCases {
                mesh.indices.append(contentsOf: [0, 1, 2, 3, 4, 5])
                mesh.classifications.append(contentsOf: [kind, kind])
            }
            anchors.append(mesh)
        }
        let grouped = try build(anchors, [snapshot(jpeg: red)])
        try ScanLibrary.validate(grouped.document)
        try expect(grouped.document.parts.count == 512, "Projected + fallback groups must fit the library limit")
        try expect(grouped.document.triangleCount == 768, "Group-budget fallback must not drop selected geometry")
        try expect(grouped.document.texturedTriangleCount == 128, "Global textured-group budget is incorrect")
        try expect(grouped.warnings.contains { $0.contains("未投影メッシュ") }, "Group-budget downgrade must be disclosed")
        print("Budget: \(grouped.document.parts.count) parts, all \(grouped.document.triangleCount) selected faces retained")
    }

    private static func build(_ meshes: [MeshSnapshot], _ photos: [CameraSnapshot]) throws -> BuildResult {
        try TextureProjector.build(meshes: meshes, photos: photos, mode: .lidar, name: "テスト", progress: { _ in })
    }
    private static func triangle() -> MeshSnapshot {
        MeshSnapshot(id: UUID(), vertices: [[-0.5, -0.5, -2], [0.5, -0.5, -2], [0, 0.5, -2]],
                     normals: Array(repeating: [0, 0, 1], count: 3), indices: [0, 1, 2], classifications: [.wall])
    }
    private static func snapshot(jpeg: Data) -> CameraSnapshot {
        CameraSnapshot(timestamp: 0,
                       transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                       intrinsics: [80, 0, 0, 0, 80, 0, 50, 40, 1], width: 100, height: 80, jpeg: jpeg)
    }
    private static func jpeg(width: Int, height: Int, red: CGFloat, blue: CGFloat) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "ProcessingTests", code: 2)
        }
        context.setFillColor(CGColor(red: red, green: 0.25, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard let image = context.makeImage() else { throw NSError(domain: "ProcessingTests", code: 3) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            throw NSError(domain: "ProcessingTests", code: 4)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "ProcessingTests", code: 5) }
        return data as Data
    }
}
