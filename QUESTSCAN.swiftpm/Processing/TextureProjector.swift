import Foundation
import simd
import ImageIO

/// Operates exclusively on copied, world-space values, never live ARGeometry/Metal buffers.
/// Suitable for a detached/background task. The caller must dispatch progress to its UI actor.
enum TextureProjector {
    static let maximumTriangles = 60_000
    private static let maximumPhotos = 128
    // 48 source anchors * 8 fallback classes + 128 textured groups <= 512 stored parts.
    private static let maximumSources = 48
    private static let maximumTexturedGroups = 128
    private static let maximumStoredTextureBytes = 64 * 1024 * 1024

    enum ProjectionError: LocalizedError {
        case emptyGeometry, cancelled
        var errorDescription: String? {
            switch self {
            case .emptyGeometry: return "有効な三角形がありません。別の角度からスキャンしてください。"
            case .cancelled: return "処理をキャンセルしました。"
            }
        }
    }

    static func build(meshes: [MeshSnapshot], photos: [CameraSnapshot], mode: ScanMode,
                      name: String, progress: @escaping (Double) -> Void) throws -> BuildResult {
        progress(0)
        var warnings: [String] = []
        let nonempty = meshes.indices.filter { meshes[$0].indices.count >= 3 }
        guard !nonempty.isEmpty else { throw ProjectionError.emptyGeometry }
        // Bound anchor overhead, not just triangles. Uniform sampling avoids a first-anchor bias.
        let sourceIndices = sampleIndices(count: nonempty.count, limit: maximumSources).map { nonempty[$0] }
        if nonempty.count > maximumSources {
            warnings.append("保存できる部分数の上限に合わせ、最大48アンカーを均等に選んで処理しました。選択した面の形状は未投影でも保持します。")
        }
        let photoIndices = sampleIndices(count: photos.count, limit: maximumPhotos)
        var cameras: [PreparedCamera] = []
        for index in photoIndices {
            if let camera = PreparedCamera(snapshot: photos[index]) { cameras.append(camera) }
        }
        if photos.count > maximumPhotos {
            warnings.append("撮影写真はすべて保持しています。3D生成時は処理負荷を抑えるため、時間順に均等選択した最大128枚を写真投影に使用しました。")
        }
        if cameras.count < photoIndices.count {
            warnings.append("画像またはカメラ情報が不正な写真は投影から除外しました。")
        }
        progress(0.04)
        let counts = sourceIndices.map { meshes[$0].indices.count / 3 }
        let totalFaces = counts.reduce(0.0) { $0 + Double($1) }
        let quotas = allocateQuotas(counts: counts, budget: maximumTriangles)
        let workCount = quotas.reduce(0, +)
        if totalFaces > Double(maximumTriangles) {
            warnings.append("表示を軽くするため、観測メッシュを最大60,000面に間引きました。")
        }

        var parts: [ScenePart] = []
        var texturedGroups = 0
        var storedTextureBytes = 0
        var limitedGroups = false
        var droppedFaces = 0
        var processed = 0
        var area: Double = 0
        var texturedArea: Double = 0
        for (sourceOffset, sourceIndex) in sourceIndices.enumerated() {
            let mesh = meshes[sourceIndex]
            let quota = quotas[sourceOffset]
            var groups: [GroupKey: PartBuilder] = [:]
            var groupOrder: [GroupKey] = []
            // Sampling computes only selected indices; it never walks unlimited face geometry.
            for sample in 0..<quota {
                if processed % 256 == 0 {
                    if Task.isCancelled || Thread.current.isCancelled { throw ProjectionError.cancelled }
                    progress(0.04 + 0.92 * Double(processed) / Double(max(1, workCount)))
                }
                processed += 1
                let face = min(counts[sourceOffset] - 1,
                               Int((Double(sample) + 0.5) * Double(counts[sourceOffset]) / Double(quota)))
                let offset = face * 3
                let original = [mesh.indices[offset], mesh.indices[offset + 1], mesh.indices[offset + 2]]
                guard original.allSatisfy({ Int($0) < mesh.vertices.count }) else {
                    droppedFaces += 1; continue
                }
                let p = original.map { mesh.vertices[Int($0)] }
                guard p.allSatisfy(isFinite) else { droppedFaces += 1; continue }
                let cross = simd_cross(p[1] - p[0], p[2] - p[0])
                let twiceArea = simd_length(cross)
                guard twiceArea.isFinite, twiceArea > 0.0000001 else { droppedFaces += 1; continue }
                let geometricNormal = cross / twiceArea
                let normals = original.map { sourceNormal(mesh, index: Int($0), fallback: geometricNormal) }
                let normal = normalized(normals[0] + normals[1] + normals[2], fallback: geometricNormal)
                let centroid = (p[0] + p[1] + p[2]) / 3
                var bestPhoto: Int? = nil
                var bestUVs = [SIMD2<Float>](repeating: .zero, count: 3)
                var bestScore: Float = 0
                for (cameraIndex, camera) in cameras.enumerated() {
                    let direction = camera.position - centroid
                    let distance = simd_length(direction)
                    guard distance.isFinite, distance > 0.01 else { continue }
                    let facing = simd_dot(normal, direction / distance)
                    guard facing > 0.08 else { continue }
                    guard let a = camera.project(p[0]), let b = camera.project(p[1]),
                          let c = camera.project(p[2]) else { continue }
                    // Reject inconsistent vertices, not merely a centroid. Interior samples catch
                    // some foreground occluders wholly inside a large wall triangle as well.
                    guard camera.depthAgrees(a), camera.depthAgrees(b), camera.depthAgrees(c) else { continue }
                    if camera.hasDepth {
                        let interior = [centroid, (p[0] + p[1]) / 2,
                                        (p[1] + p[2]) / 2, (p[2] + p[0]) / 2]
                        guard interior.allSatisfy({ point in
                            guard let sample = camera.project(point) else { return false }
                            return camera.depthAgrees(sample)
                        }) else { continue }
                    }
                    let ab = b.rawUV - a.rawUV
                    let ac = c.rawUV - a.rawUV
                    let pixelArea = abs(ab.x * ac.y - ab.y * ac.x) * 0.5 * camera.pixelCount
                    guard pixelArea.isFinite, pixelArea > 0.2 else { continue }
                    let center = (a.rawUV + b.rawUV + c.rawUV) / 3
                    let centerWeight = max(0.2, 1 - simd_length(center - SIMD2<Float>(repeating: 0.5)))
                    let score = pixelArea * facing * centerWeight / (1 + distance * distance * 0.12)
                    if score > bestScore {
                        bestScore = score
                        bestPhoto = cameraIndex
                        bestUVs = [a.textureUV, b.textureUV, c.textureUV]
                    }
                }
                let kind = face < mesh.classifications.count ? mesh.classifications[face] : .unknown
                var key = GroupKey(kind: kind, photo: bestPhoto)
                if groups[key] == nil, bestPhoto != nil {
                    let imageBytes = bestPhoto.map { cameras[$0].jpeg.count } ?? 0
                    if texturedGroups >= maximumTexturedGroups ||
                        imageBytes > maximumStoredTextureBytes - storedTextureBytes {
                        // Never merge anchors or classifications to meet the group budget.
                        // Keep the geometry in its own anchor/class untextured fallback group.
                        bestPhoto = nil
                        bestUVs = [SIMD2<Float>](repeating: .zero, count: 3)
                        key = GroupKey(kind: kind, photo: nil)
                        limitedGroups = true
                    } else { texturedGroups += 1; storedTextureBytes += imageBytes }
                }
                if groups[key] == nil {
                    let sourceLabel = String(mesh.id.uuidString.prefix(6))
                    let suffix = bestPhoto.map { "・写真\($0 + 1)" } ?? "・未投影"
                    groups[key] = PartBuilder(name: "\(kind.title)・\(sourceLabel)\(suffix)", kind: kind,
                                              texture: bestPhoto.map { cameras[$0].jpeg })
                    groupOrder.append(key)
                }
                groups[key]?.append(indices: original, positions: p, normals: normals, uvs: bestUVs)
                let faceArea = Double(twiceArea) * 0.5
                area += faceArea
                if bestPhoto != nil { texturedArea += faceArea }
            }
            for key in groupOrder {
                if let builder = groups[key], !builder.indices.isEmpty { parts.append(builder.part) }
            }
        }
        guard !parts.isEmpty else { throw ProjectionError.emptyGeometry }
        if droppedFaces > 0 {
            warnings.append("不正な頂点・縮退した三角形を\(droppedFaces)面除外しました。")
        }
        if limitedGroups {
            warnings.append("部分数または写真データの上限を超えた面は、分類を保持した未投影メッシュとして残しました。")
        }
        if texturedArea == 0 {
            warnings.append("投影できる写真がありません。形状は保存されますが、写真テクスチャは付いていません。")
        } else if cameras.contains(where: { !$0.hasDepth }) {
            warnings.append("深度のない写真では、隠れた面の完全な判定はできません。写真投影に映り込みが残る場合があります。")
        }
        if totalFaces > Double(workCount) {
            warnings.append("面積と写真カバー率は、表示用に残した観測面に基づく値です。部屋全体の完成率ではありません。")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = SceneDocument(name: trimmedName.isEmpty ? "新しいスキャン" : trimmedName,
                                     mode: mode, parts: parts, photosCaptured: photos.count,
                                     coverage: area > 0 ? min(1, texturedArea / area) : 0,
                                     surfaceArea: Float(min(area, Double(Float.greatestFiniteMagnitude))),
                                     thumbnailJPEG: cameras.first.flatMap { $0.jpeg.count <= 4 * 1024 * 1024 ? $0.jpeg : nil })
        progress(1)
        return BuildResult(document: document, warnings: warnings)
    }

    private struct GroupKey: Hashable {
        let kind: SurfaceKind
        let photo: Int?
    }

    private struct PartBuilder {
        let name: String
        let kind: SurfaceKind
        let texture: Data?
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var uvs: [SIMD2<Float>] = []
        var remap: [UInt32: UInt32] = [:]
        mutating func append(indices source: [UInt32], positions: [SIMD3<Float>],
                             normals incomingNormals: [SIMD3<Float>], uvs incomingUVs: [SIMD2<Float>]) {
            for corner in 0..<3 {
                let old = source[corner]
                if let mapped = remap[old] { indices.append(mapped) }
                else {
                    let mapped = UInt32(vertices.count)
                    remap[old] = mapped
                    vertices.append(positions[corner])
                    normals.append(incomingNormals[corner])
                    uvs.append(incomingUVs[corner])
                    indices.append(mapped)
                }
            }
        }
        var part: ScenePart {
            ScenePart(name: name, classification: kind, vertices: vertices, normals: normals,
                      indices: indices, textureCoordinates: uvs, textureJPEG: texture)
        }
    }

    private struct ProjectedPoint {
        let rawUV: SIMD2<Float>
        let depth: Float
        var textureUV: SIMD2<Float> { SIMD2<Float>(rawUV.x, 1 - rawUV.y) }
    }

    private struct PreparedCamera {
        let worldToCamera: simd_float4x4
        let intrinsics: simd_float3x3
        let position: SIMD3<Float>
        let width: Float
        let height: Float
        let pixelCount: Float
        let jpeg: Data
        let depth: [Float]?
        let depthWidth: Int
        let depthHeight: Int
        var hasDepth: Bool { depth != nil }

        init?(snapshot: CameraSnapshot) {
            guard snapshot.transform.count == 16, snapshot.intrinsics.count == 9,
                  snapshot.transform.allSatisfy({ $0.isFinite }),
                  snapshot.intrinsics.allSatisfy({ $0.isFinite }),
                  snapshot.width > 0, snapshot.height > 0,
                  snapshot.width <= 32_768, snapshot.height <= 32_768,
                  snapshot.intrinsics[0] > 0, snapshot.intrinsics[4] > 0,
                  !snapshot.jpeg.isEmpty, snapshot.jpeg.count <= 25_000_000,
                  let source = CGImageSourceCreateWithData(snapshot.jpeg as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let imageWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let imageHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  imageWidth.intValue > 0, imageHeight.intValue > 0,
                  imageWidth.intValue <= 8192, imageHeight.intValue <= 8192,
                  imageWidth.intValue * imageHeight.intValue <= 24_000_000 else { return nil }
            // Resizing must retain the original aspect ratio (allow one-pixel rounding).
            let originalAspect = Float(snapshot.width) / Float(snapshot.height)
            let imageAspect = imageWidth.floatValue / imageHeight.floatValue
            guard abs(originalAspect - imageAspect) < max(0.005, originalAspect * 0.005) else { return nil }
            let t = snapshot.transform
            let transform = simd_float4x4(columns: (
                SIMD4<Float>(t[0], t[1], t[2], t[3]), SIMD4<Float>(t[4], t[5], t[6], t[7]),
                SIMD4<Float>(t[8], t[9], t[10], t[11]), SIMD4<Float>(t[12], t[13], t[14], t[15])))
            let determinant = simd_determinant(transform)
            guard determinant.isFinite, abs(determinant) > 0.000001 else { return nil }
            worldToCamera = simd_inverse(transform)
            position = SIMD3<Float>(t[12], t[13], t[14])
            let k = snapshot.intrinsics
            intrinsics = simd_float3x3(columns: (SIMD3<Float>(k[0], k[1], k[2]),
                SIMD3<Float>(k[3], k[4], k[5]), SIMD3<Float>(k[6], k[7], k[8])))
            width = Float(snapshot.width); height = Float(snapshot.height)
            pixelCount = imageWidth.floatValue * imageHeight.floatValue
            jpeg = snapshot.jpeg
            if let values = snapshot.depth, snapshot.depthWidth > 0, snapshot.depthHeight > 0,
               snapshot.depthWidth <= 4096, snapshot.depthHeight <= 4096,
               values.count == snapshot.depthWidth * snapshot.depthHeight {
                depth = values; depthWidth = snapshot.depthWidth; depthHeight = snapshot.depthHeight
            } else { depth = nil; depthWidth = 0; depthHeight = 0 }
        }

        func project(_ world: SIMD3<Float>) -> ProjectedPoint? {
            let view = worldToCamera * SIMD4<Float>(world.x, world.y, world.z, 1)
            // ARKit optical direction is -Z; native image Y increases downward.
            let z = -view.z
            guard z.isFinite, z > 0.03 else { return nil }
            let pixel = intrinsics * SIMD3<Float>(view.x, -view.y, z)
            guard pixel.z.isFinite, pixel.z > 0.000001 else { return nil }
            let uv = SIMD2<Float>(pixel.x / pixel.z / width, pixel.y / pixel.z / height)
            // A small border guards filtering against an image edge. No displayTransform is used.
            guard uv.x.isFinite, uv.y.isFinite, uv.x >= 0.001, uv.x <= 0.999,
                  uv.y >= 0.001, uv.y <= 0.999 else { return nil }
            return ProjectedPoint(rawUV: uv, depth: z)
        }

        func depthAgrees(_ projected: ProjectedPoint) -> Bool {
            guard let values = depth else { return true }
            let x = min(depthWidth - 1, max(0, Int(projected.rawUV.x * Float(depthWidth))))
            let y = min(depthHeight - 1, max(0, Int(projected.rawUV.y * Float(depthHeight))))
            let observed = values[y * depthWidth + x]
            // Zero/NaN depth means unknown, not an occluder. A real measurement must agree
            // on BOTH sides of the surface, allowing LiDAR noise and slight reconstruction drift.
            guard observed.isFinite, observed > 0.03 else { return true }
            let tolerance = max(0.08, projected.depth * 0.04)
            return abs(observed - projected.depth) <= tolerance
        }
    }

    private static func sampleIndices(count: Int, limit: Int) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        let kept = min(count, limit)
        return (0..<kept).map { min(count - 1, Int((Double($0) + 0.5) * Double(count) / Double(kept))) }
    }

    private static func allocateQuotas(counts: [Int], budget: Int) -> [Int] {
        let total = counts.reduce(0.0) { $0 + Double($1) }
        guard total > Double(budget) else { return counts }
        // Reserve one sample for each retained source, then distribute remaining work proportionally.
        let remaining = max(0, budget - counts.count)
        let weights = counts.map { max(0, $0 - 1) }
        let weightTotal = weights.reduce(0.0) { $0 + Double($1) }
        var quotas = weights.map { 1 + Int(floor(Double($0) / max(1, weightTotal) * Double(remaining))) }
        var leftover = budget - quotas.reduce(0, +)
        // At most one additional sample per source is needed after rounding down.
        let order = counts.indices.sorted { a, b in
            let af = Double(weights[a]) / max(1, weightTotal) * Double(remaining)
            let bf = Double(weights[b]) / max(1, weightTotal) * Double(remaining)
            let ar = af - floor(af), br = bf - floor(bf)
            return ar == br ? a < b : ar > br
        }
        for index in order where leftover > 0 {
            if quotas[index] < counts[index] { quotas[index] += 1; leftover -= 1 }
        }
        return quotas
    }

    private static func isFinite(_ vector: SIMD3<Float>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
    private static func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        return length.isFinite && length > 0.00001 ? vector / length : fallback
    }
    private static func sourceNormal(_ mesh: MeshSnapshot, index: Int, fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard index < mesh.normals.count, isFinite(mesh.normals[index]) else { return fallback }
        // Retain the supplied per-vertex normal direction rather than replacing everything
        // with flat triangle normals; normalize only to satisfy rendering expectations.
        return normalized(mesh.normals[index], fallback: fallback)
    }
}
