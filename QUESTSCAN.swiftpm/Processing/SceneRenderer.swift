import Foundation
import UIKit
import RealityKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import simd

/// RealityKit resources/entities are created on the main actor. Image processing is thread-safe
/// and can run off-main, including when the exporter calls adjustedJPEG.
enum SceneRenderer {
    enum RenderError: LocalizedError {
        case invalidGeometry, geometryTooLarge, invalidImage, imageTooLarge, imageEncoding
        var errorDescription: String? {
            switch self {
            case .invalidGeometry: return "メッシュの頂点・インデックスが不正です。"
            case .geometryTooLarge: return "表示メッシュが上限の60,000面を超えています。"
            case .invalidImage: return "写真を読み込めませんでした。"
            case .imageTooLarge: return "写真のサイズが大きすぎます。"
            case .imageEncoding: return "調整済み写真を保存できませんでした。"
            }
        }
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // Core Image's color controls operate in sRGB here, not an implicit extended-linear space.
    // The same context/pipeline is used for both rendered and exported pixels.
    private static let imageContext = CIContext(options: [
        .workingColorSpace: colorSpace, .outputColorSpace: colorSpace, .cacheIntermediates: false
    ])
    private final class TextureBox: NSObject {
        let resource: TextureResource
        init(_ resource: TextureResource) { self.resource = resource }
    }
    private static let textures: NSCache<NSString, TextureBox> = {
        let cache = NSCache<NSString, TextureBox>()
        cache.countLimit = 32
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    @MainActor
    static func makeEntity(for part: ScenePart, wireframe: Bool = false) throws -> ModelEntity {
        guard part.indices.count % 3 == 0, !part.vertices.isEmpty, !part.indices.isEmpty else {
            throw RenderError.invalidGeometry
        }
        guard part.triangleCount <= TextureProjector.maximumTriangles,
              part.vertices.count <= TextureProjector.maximumTriangles * 3 else {
            throw RenderError.geometryTooLarge
        }
        guard part.vertices.allSatisfy(finite),
              part.indices.allSatisfy({ Int($0) < part.vertices.count }) else {
            throw RenderError.invalidGeometry
        }
        var descriptor = MeshDescriptor(name: part.id.uuidString)
        descriptor.positions = MeshBuffer(part.vertices)
        descriptor.primitives = .triangles(part.indices)
        if part.normals.count == part.vertices.count, part.normals.allSatisfy(finite) {
            descriptor.normals = MeshBuffer(part.normals)
        } // MeshResource generates normals if legacy/imported data does not contain them.
        let material: any Material
        if let jpeg = part.textureJPEG {
            guard part.textureCoordinates.count == part.vertices.count,
                  part.textureCoordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw RenderError.invalidGeometry
            }
            descriptor.textureCoordinates = MeshBuffer(part.textureCoordinates)
            let texture = try textureResource(jpeg, adjustment: part.adjustment)
            // Tint is ALREADY baked into this photo. A second material tint would make an
            // edited scene differ from USDPreviewSurface in the exported USDZ.
            var photoMaterial = UnlitMaterial()
            photoMaterial.color = .init(tint: .white, texture: .init(texture))
            material = photoMaterial
        } else {
            let rgb = adjustedDiffuseRGB(part.adjustment)
            var solidMaterial = PhysicallyBasedMaterial()
            solidMaterial.baseColor = .init(tint: UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y),
                                                         blue: CGFloat(rgb.z), alpha: 1))
            solidMaterial.roughness = .init(floatLiteral: 0.85)
            solidMaterial.metallic = .init(floatLiteral: 0)
            material = solidMaterial
        }
        let mesh = try MeshResource.generate(from: [descriptor])
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = part.id.uuidString
        if wireframe {
            let overlay = try makeWireframe(vertices: part.vertices, indices: part.indices,
                                            color: UIColor(red: 0.22, green: 0.91, blue: 1, alpha: 1))
            // The editor may hit the child, so selection can resolve either name to the part.
            overlay.name = part.id.uuidString
            entity.addChild(overlay)
        }
        return entity
    }

    /// A real ribbon mesh rather than RealityKit's environment/debug visualization.
    /// `limit` counts unique edges; both inspected faces and generated geometry are bounded.
    @MainActor
    static func makeWireframe(vertices: [SIMD3<Float>], indices: [UInt32], color: UIColor,
                              limit: Int = 1200) throws -> ModelEntity {
        let edgeLimit = min(6000, max(0, limit))
        let triangleCount = indices.count / 3
        guard edgeLimit > 0, triangleCount > 0, !vertices.isEmpty else { return ModelEntity() }
        let sampledFaces = min(triangleCount, edgeLimit * 2)
        var seen: Set<UInt64> = []
        var positions: [SIMD3<Float>] = []
        var triangles: [UInt32] = []
        positions.reserveCapacity(edgeLimit * 8)
        triangles.reserveCapacity(edgeLimit * 24)
        for sample in 0..<sampledFaces {
            if seen.count >= edgeLimit { break }
            let face = min(triangleCount - 1,
                           Int((Double(sample) + 0.5) * Double(triangleCount) / Double(sampledFaces)))
            let base = face * 3
            let ids = [indices[base], indices[base + 1], indices[base + 2]]
            guard ids.allSatisfy({ Int($0) < vertices.count }) else { continue }
            let p = ids.map { vertices[Int($0)] }
            guard p.allSatisfy(finite) else { continue }
            let cross = simd_cross(p[1] - p[0], p[2] - p[0])
            let crossLength = simd_length(cross)
            guard crossLength.isFinite, crossLength > 0.000001 else { continue }
            let normal = cross / crossLength
            for corner in 0..<3 {
                if seen.count >= edgeLimit { break }
                let next = (corner + 1) % 3
                let low = min(ids[corner], ids[next]), high = max(ids[corner], ids[next])
                let key = (UInt64(low) << 32) | UInt64(high)
                guard !seen.contains(key) else { continue }
                let a = p[corner], b = p[next]
                let length = simd_length(b - a)
                guard length.isFinite, length > 0.0001 else { continue }
                seen.insert(key)
                let direction = (b - a) / length
                let side = simd_normalize(simd_cross(normal, direction))
                let halfWidth = min(0.0035, max(0.0008, length * 0.003))
                let lift = normal * 0.002
                // Two crossed, double-sided ribbons keep an edge visible from oblique views.
                for axis in [side, normal] {
                    let offset = axis * halfWidth
                    let start = UInt32(positions.count)
                    positions.append(contentsOf: [a + lift - offset, b + lift - offset,
                                                  b + lift + offset, a + lift + offset])
                    triangles.append(contentsOf: [start, start + 1, start + 2,
                                                  start, start + 2, start + 3,
                                                  start + 2, start + 1, start,
                                                  start + 3, start + 2, start])
                }
            }
        }
        guard !triangles.isEmpty else { return ModelEntity() }
        var descriptor = MeshDescriptor(name: "QUESTSCAN.edge-ribbons")
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(triangles)
        var material = UnlitMaterial()
        material.color = .init(tint: color)
        let mesh = try MeshResource.generate(from: [descriptor])
        return ModelEntity(mesh: mesh, materials: [material])
    }

    /// Original Data remains untouched. Preserves native camera orientation (ignores EXIF),
    /// aspect ratio and pixel dimensions. Uses ImageIO/CIContext, never UIKit drawing.
    static func adjustedJPEG(_ data: Data, adjustment: ColorAdjustment) throws -> Data {
        let source = try decodedImage(data)
        let a = sanitized(adjustment)
        if a == .identity { return data }
        let output = adjustedImage(CIImage(cgImage: source), adjustment: a)
        guard let image = imageContext.createCGImage(output, from: output.extent,
                                                     format: .RGBA8, colorSpace: colorSpace) else {
            throw RenderError.invalidImage
        }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RenderError.imageEncoding
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.93] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.imageEncoding }
        return result as Data
    }

    /// Shared solid diffuse rule for USDPreviewSurface exporters. White is the neutral
    /// untextured base; saturation cannot change gray. Tint multiplies after color controls.
    static func adjustedDiffuseRGB(_ adjustment: ColorAdjustment) -> SIMD3<Float> {
        let a = sanitized(adjustment)
        let neutral = (0.5 * a.contrast + 0.5 + a.brightness)
        let tint = SIMD3<Float>(repeating: 1 - a.tintAmount) +
            SIMD3<Float>(a.red, a.green, a.blue) * a.tintAmount
        let result = tint * neutral
        return SIMD3<Float>(clamp(result.x, 0, 1), clamp(result.y, 0, 1), clamp(result.z, 0, 1))
    }

    @MainActor
    private static func textureResource(_ jpeg: Data, adjustment: ColorAdjustment) throws -> TextureResource {
        let a = sanitized(adjustment)
        let colorKey = [a.red, a.green, a.blue, a.tintAmount, a.brightness, a.contrast, a.saturation]
            .map { String($0.bitPattern, radix: 16) }.joined(separator: ":")
        let digest = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        let key = (digest + ":" + colorKey) as NSString
        if let cached = textures.object(forKey: key) { return cached.resource }
        // Use the same final JPEG that export embeds, not a separately tinted GPU material.
        let adjusted = try adjustedJPEG(jpeg, adjustment: a)
        let image = try decodedImage(adjusted)
        let texture = try TextureResource.generate(from: image, options: .init(semantic: .color))
        textures.setObject(TextureBox(texture), forKey: key, cost: image.width * image.height * 4)
        return texture
    }

    private static func decodedImage(_ data: Data) throws -> CGImage {
        guard !data.isEmpty, data.count <= 25_000_000 else { throw RenderError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw RenderError.invalidImage }
        guard w.intValue > 0, h.intValue > 0, w.intValue <= 8192, h.intValue <= 8192,
              w.intValue * h.intValue <= 24_000_000 else { throw RenderError.imageTooLarge }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw RenderError.invalidImage
        }
        return image
    }

    private static func adjustedImage(_ source: CIImage, adjustment a: ColorAdjustment) -> CIImage {
        let controls = source.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: a.brightness, kCIInputContrastKey: a.contrast,
            kCIInputSaturationKey: a.saturation
        ])
        let r = CGFloat(1 - a.tintAmount + a.tintAmount * a.red)
        let g = CGFloat(1 - a.tintAmount + a.tintAmount * a.green)
        let b = CGFloat(1 - a.tintAmount + a.tintAmount * a.blue)
        return controls.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]).cropped(to: source.extent)
    }

    private static func sanitized(_ a: ColorAdjustment) -> ColorAdjustment {
        ColorAdjustment(red: safe(a.red, fallback: 1, 0, 1), green: safe(a.green, fallback: 1, 0, 1),
                        blue: safe(a.blue, fallback: 1, 0, 1), tintAmount: safe(a.tintAmount, fallback: 0, 0, 1),
                        brightness: safe(a.brightness, fallback: 0, -1, 1),
                        contrast: safe(a.contrast, fallback: 1, 0, 3),
                        saturation: safe(a.saturation, fallback: 1, 0, 3))
    }
    private static func safe(_ value: Float, fallback: Float, _ low: Float, _ high: Float) -> Float {
        clamp(value.isFinite ? value : fallback, low, high)
    }
    private static func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float { min(high, max(low, value)) }
    private static func finite(_ value: SIMD3<Float>) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
}
