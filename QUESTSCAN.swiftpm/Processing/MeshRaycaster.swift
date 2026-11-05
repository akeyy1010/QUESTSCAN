import Foundation
import simd

/// Exact CPU picking against the exported world-space triangles. This avoids convex
/// collision hulls selecting empty space between disconnected photo/classification regions.
enum MeshRaycaster {
    static func nearestPart(in document: SceneDocument, origin: SIMD3<Float>, direction: SIMD3<Float>) -> UUID? {
        guard finite(origin), finite(direction) else { return nil }
        let length = simd_length(direction)
        guard length > 0.000001 else { return nil }
        let ray = direction / length
        var nearest: Float = .greatestFiniteMagnitude
        var selected: UUID?
        for part in document.parts {
            for offset in stride(from: 0, to: part.indices.count - part.indices.count % 3, by: 3) {
                let a = Int(part.indices[offset]), b = Int(part.indices[offset + 1]), c = Int(part.indices[offset + 2])
                guard a < part.vertices.count, b < part.vertices.count, c < part.vertices.count else { continue }
                if let distance = intersection(origin: origin, direction: ray,
                                               a: part.vertices[a], b: part.vertices[b], c: part.vertices[c]), distance < nearest {
                    nearest = distance
                    selected = part.id
                }
            }
        }
        return selected
    }

    private static func intersection(origin: SIMD3<Float>, direction: SIMD3<Float>,
                                     a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) -> Float? {
        let edge1 = b - a, edge2 = c - a
        let h = simd_cross(direction, edge2)
        let determinant = simd_dot(edge1, h)
        guard determinant.isFinite, abs(determinant) > 0.00000001 else { return nil }
        let inverse = 1 / determinant
        let offset = origin - a
        let u = simd_dot(offset, h) * inverse
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(offset, edge1)
        let v = simd_dot(direction, q) * inverse
        guard v >= 0, u + v <= 1 else { return nil }
        let distance = simd_dot(edge2, q) * inverse
        return distance.isFinite && distance > 0.0001 ? distance : nil
    }

    private static func finite(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
}
