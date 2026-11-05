import Foundation
import simd

/// An estimate of PHOTO ELIGIBILITY on retained, observed geometry, never room completion.
/// Native ARKit camera looks along -Z; intrinsics use original image pixels and a
/// top-left origin. Depth inconsistency rejects occluded samples when depth exists.
/// Without usable depth, frustum/facing eligibility is only an estimate of visibility.
/// Apple: https://developer.apple.com/documentation/arkit/arcamera/intrinsics
/// https://developer.apple.com/documentation/arkit/ardepthdata/depthmap
enum CoverageEstimator {
    struct Estimate {
        var coverage: Double = 0
        var surfaceArea: Float = 0
    }

    static func estimate(meshes: [MeshSnapshot], photos: [CameraSnapshot], sampleLimit: Int = 1_200) -> Estimate {
        let totalFaces = meshes.reduce(0) { $0 + $1.indices.count / 3 }
        guard totalFaces > 0 else { return Estimate() }
        let cameras = photos.compactMap { PhotoProjection($0) }
        let step = max(1, (totalFaces + max(1, sampleLimit) - 1) / max(1, sampleLimit))
        var totalArea: Double = 0
        var sampledArea: Double = 0
        var eligibleArea: Double = 0
        var ordinal = 0
        for mesh in meshes {
            for face in 0..<(mesh.indices.count / 3) {
                defer { ordinal += 1 }
                let base = face * 3
                let aIndex = Int(mesh.indices[base]), bIndex = Int(mesh.indices[base + 1]), cIndex = Int(mesh.indices[base + 2])
                guard aIndex < mesh.vertices.count, bIndex < mesh.vertices.count, cIndex < mesh.vertices.count else { continue }
                let a = mesh.vertices[aIndex], b = mesh.vertices[bIndex], c = mesh.vertices[cIndex]
                let cross = simd_cross(b - a, c - a)
                let twiceArea = simd_length(cross)
                guard twiceArea.isFinite, twiceArea > 1e-8 else { continue }
                let area = Double(twiceArea) * 0.5
                totalArea += area
                guard !cameras.isEmpty, ordinal % step == step / 2 else { continue }
                // Systematic distributed triangle sampling, weighted by each sampled
                // triangle's real area (not triangle count, elapsed time, or motion).
                sampledArea += area
                let center = (a + b + c) / 3
                let normal = cross / twiceArea
                if cameras.contains(where: { $0.accepts(a: a, b: b, c: c, center: center, normal: normal) }) {
                    eligibleArea += area
                }
            }
        }
        let fraction = sampledArea > 0 ? eligibleArea / sampledArea : 0
        return Estimate(coverage: min(1, max(0, fraction)), surfaceArea: Float(totalArea))
    }

    private struct PhotoProjection {
        let inverse: simd_float4x4
        let position: SIMD3<Float>
        let fx: Float, fy: Float, cx: Float, cy: Float
        let width: Float, height: Float
        let depth: [Float]?
        let depthWidth: Int, depthHeight: Int

        init?(_ photo: CameraSnapshot) {
            guard photo.transform.count == 16, photo.intrinsics.count == 9,
                  photo.transform.allSatisfy({ $0.isFinite }), photo.intrinsics.allSatisfy({ $0.isFinite }),
                  photo.width > 0, photo.height > 0, !photo.jpeg.isEmpty,
                  photo.intrinsics[0] > 0, photo.intrinsics[4] > 0 else { return nil }
            let t = photo.transform
            let matrix = simd_float4x4(columns: (SIMD4<Float>(t[0], t[1], t[2], t[3]),
                                                SIMD4<Float>(t[4], t[5], t[6], t[7]),
                                                SIMD4<Float>(t[8], t[9], t[10], t[11]),
                                                SIMD4<Float>(t[12], t[13], t[14], t[15])))
            guard abs(simd_determinant(matrix)) > 1e-6 else { return nil }
            inverse = simd_inverse(matrix)
            position = SIMD3<Float>(t[12], t[13], t[14])
            fx = photo.intrinsics[0]; fy = photo.intrinsics[4]
            cx = photo.intrinsics[6]; cy = photo.intrinsics[7]
            width = Float(photo.width); height = Float(photo.height)
            if photo.depthWidth > 0, photo.depthHeight > 0,
               let values = photo.depth, values.count == photo.depthWidth * photo.depthHeight {
                depth = values; depthWidth = photo.depthWidth; depthHeight = photo.depthHeight
            } else { depth = nil; depthWidth = 0; depthHeight = 0 }
        }

        func accepts(a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>, center: SIMD3<Float>, normal: SIMD3<Float>) -> Bool {
            let direction = position - center
            let distance = simd_length(direction)
            guard distance.isFinite, distance > 0.08, distance < 8 else { return false }
            // Plane geometry is deliberately two-sided; no fabricated normal-facing wall box.
            guard abs(simd_dot(normal, direction / distance)) > 0.18 else { return false }
            return projects(a) && projects(b) && projects(c) && projects(center)
        }

        func projects(_ world: SIMD3<Float>) -> Bool {
            let camera = inverse * SIMD4<Float>(world, 1)
            let z = -camera.z
            guard z.isFinite, z > 0.05 else { return false }
            let u = (fx * camera.x / z + cx) / width
            let v = (cy - fy * camera.y / z) / height
            guard u.isFinite, v.isFinite, u >= 0.02, u <= 0.98, v >= 0.02, v <= 0.98 else { return false }
            if let depth = depth {
                let x = min(depthWidth - 1, max(0, Int(u * Float(depthWidth))))
                let y = min(depthHeight - 1, max(0, Int(v * Float(depthHeight))))
                let measured = depth[y * depthWidth + x]
                // Zero/invalid samples mean no reliable occlusion evidence, not fake depth.
                if measured.isFinite, measured > 0,
                   abs(measured - z) > max(0.10, z * 0.04) { return false }
            }
            return true
        }
    }
}
