import ARKit
import Metal
import simd

/// Call only on ARSession.delegateQueue while the delegate owns the anchor.
/// No ARGeometrySource, Metal buffer, or pointer escapes into a snapshot.
/// Apple references: /documentation/arkit/argeometrysource,
/// /documentation/arkit/armeshgeometry/faces, /documentation/arkit/arplanegeometry.
enum MeshExtractor {
    static func mesh(_ anchor: ARMeshAnchor, triangleLimit: Int) -> MeshSnapshot? {
        let geometry = anchor.geometry
        let faces = geometry.faces
        guard triangleLimit > 0, faces.primitiveType == .triangle,
              faces.indexCountPerPrimitive == 3,
              faces.bytesPerIndex == 2 || faces.bytesPerIndex == 4,
              faces.buffer.storageMode != .private else { return nil }
        let bytesPerFace = 3 * faces.bytesPerIndex
        let faceCount = min(faces.count, faces.buffer.length / bytesPerFace)
        guard faceCount > 0, geometry.vertices.format == .float3,
              geometry.vertices.buffer.storageMode != .private else { return nil }

        let target = min(triangleLimit, faceCount)
        let rotation = rotationMatrix(anchor.transform)
        var result = MeshSnapshot(id: anchor.identifier, vertices: [], normals: [], indices: [], classifications: [])
        result.indices.reserveCapacity(target * 3)
        result.classifications.reserveCapacity(target)
        var remap: [Int: UInt32] = [:]
        remap.reserveCapacity(min(geometry.vertices.count, target * 3))
        let indexBytes = faces.buffer.contents()

        // Deterministic, distributed face sampling; compaction bounds vertex memory too.
        for sample in 0..<target {
            let face = Int((Int64(sample) * Int64(faceCount)) / Int64(target))
            var original: [Int] = []
            for corner in 0..<3 {
                let offset = (face * 3 + corner) * faces.bytesPerIndex
                let index: Int
                if faces.bytesPerIndex == 2 {
                    var value: UInt16 = 0
                    memcpy(&value, indexBytes.advanced(by: offset), 2)
                    index = Int(value)
                } else {
                    var value: UInt32 = 0
                    memcpy(&value, indexBytes.advanced(by: offset), 4)
                    index = Int(value)
                }
                original.append(index)
            }
            guard original.allSatisfy({ $0 < geometry.vertices.count }),
                  original[0] != original[1], original[1] != original[2], original[0] != original[2] else { continue }
            var local: [SIMD3<Float>] = []
            for index in original {
                guard let vertex = float3(geometry.vertices, index: index) else { break }
                local.append(vertex)
            }
            guard local.count == 3 else { continue }
            let faceNormal = simd_cross(local[1] - local[0], local[2] - local[0])
            guard simd_length_squared(faceNormal) > 1e-12 else { continue }
            var mapped: [UInt32] = []
            for corner in 0..<3 {
                let originalIndex = original[corner]
                if let existing = remap[originalIndex] {
                    mapped.append(existing)
                    continue
                }
                let point = anchor.transform * SIMD4<Float>(local[corner], 1)
                let world = SIMD3<Float>(point.x, point.y, point.z)
                let localNormal = float3(geometry.normals, index: originalIndex) ?? faceNormal
                let normal = normalized(rotation * localNormal, fallback: rotation * faceNormal)
                guard finite(world), finite(normal) else { break }
                let newIndex = UInt32(result.vertices.count)
                remap[originalIndex] = newIndex
                result.vertices.append(world)
                result.normals.append(normal)
                mapped.append(newIndex)
            }
            guard mapped.count == 3 else { continue }
            result.indices.append(contentsOf: mapped)
            result.classifications.append(classification(geometry.classification, face: face))
        }
        return result.indices.isEmpty ? nil : result
    }

    /// Non-LiDAR fallback is the actual ARKit convex plane geometry, not a room box.
    static func plane(_ anchor: ARPlaneAnchor, triangleLimit: Int) -> MeshSnapshot? {
        let vertices = anchor.geometry.vertices
        let indices = anchor.geometry.triangleIndices
        let count = min(anchor.geometry.triangleCount, indices.count / 3)
        guard count > 0, triangleLimit > 0 else { return nil }
        let target = min(count, triangleLimit)
        let normal = normalized(rotationMatrix(anchor.transform) * SIMD3<Float>(0, 1, 0), fallback: SIMD3<Float>(0, 1, 0))
        let kind = planeClassification(anchor.classification)
        var result = MeshSnapshot(id: anchor.identifier, vertices: [], normals: [], indices: [], classifications: [])
        var remap: [Int: UInt32] = [:]
        for sample in 0..<target {
            let face = Int((Int64(sample) * Int64(count)) / Int64(target))
            // The API exposes Int16, but the underlying indices are unsigned 16-bit.
            let corners = (0..<3).map { Int(UInt16(bitPattern: indices[face * 3 + $0])) }
            guard corners.allSatisfy({ $0 < vertices.count }) else { continue }
            let localA = vertices[corners[0]], localB = vertices[corners[1]], localC = vertices[corners[2]]
            guard finite(localA), finite(localB), finite(localC),
                  simd_length_squared(simd_cross(localB - localA, localC - localA)) > 1e-12 else { continue }
            var mapped: [UInt32] = []
            for index in corners {
                if let existing = remap[index] { mapped.append(existing); continue }
                let point = anchor.transform * SIMD4<Float>(vertices[index], 1)
                let world = SIMD3<Float>(point.x, point.y, point.z)
                guard finite(world) else { break }
                let newIndex = UInt32(result.vertices.count)
                remap[index] = newIndex
                result.vertices.append(world)
                result.normals.append(normal)
                mapped.append(newIndex)
            }
            guard mapped.count == 3 else { continue }
            result.indices.append(contentsOf: mapped)
            result.classifications.append(kind)
        }
        return result.indices.isEmpty ? nil : result
    }

    /// Rebudget already-owned values without retaining or rereading an ARKit buffer.
    static func limited(_ mesh: MeshSnapshot, triangleLimit: Int) -> MeshSnapshot {
        let faceCount = mesh.indices.count / 3
        let target = min(faceCount, max(0, triangleLimit))
        guard target < faceCount else { return mesh }
        var result = MeshSnapshot(id: mesh.id, vertices: [], normals: [], indices: [], classifications: [])
        guard target > 0 else { return result }
        var remap: [UInt32: UInt32] = [:]
        for sample in 0..<target {
            let face = Int((Int64(sample) * Int64(faceCount)) / Int64(target))
            let corners = Array(mesh.indices[(face * 3)..<(face * 3 + 3)])
            guard corners.allSatisfy({ Int($0) < mesh.vertices.count }) else { continue }
            for old in corners {
                if let mapped = remap[old] { result.indices.append(mapped); continue }
                let index = Int(old)
                let mapped = UInt32(result.vertices.count)
                remap[old] = mapped
                result.vertices.append(mesh.vertices[index])
                result.normals.append(index < mesh.normals.count ? mesh.normals[index] : SIMD3<Float>(0, 1, 0))
                result.indices.append(mapped)
            }
            result.classifications.append(face < mesh.classifications.count ? mesh.classifications[face] : .unknown)
        }
        return result
    }

    private static func float3(_ source: ARGeometrySource, index: Int) -> SIMD3<Float>? {
        guard index >= 0, index < source.count, source.format == .float3,
              source.stride >= 12, source.offset >= 0,
              source.buffer.storageMode != .private else { return nil }
        let offset = source.offset + source.stride * index
        guard offset <= source.buffer.length - 12 else { return nil }
        let pointer = source.buffer.contents().advanced(by: offset)
        // SIMD3 has 16-byte stride, whereas a packed Metal float3 may use 12 bytes.
        var x: Float = 0, y: Float = 0, z: Float = 0
        memcpy(&x, pointer, 4)
        memcpy(&y, pointer.advanced(by: 4), 4)
        memcpy(&z, pointer.advanced(by: 8), 4)
        let value = SIMD3<Float>(x, y, z)
        return finite(value) ? value : nil
    }

    private static func classification(_ source: ARGeometrySource?, face: Int) -> SurfaceKind {
        guard let source = source, face < source.count, source.format == .uchar,
              source.buffer.storageMode != .private, source.offset >= 0, source.stride > 0 else { return .unknown }
        let offset = source.offset + source.stride * face
        guard offset < source.buffer.length else { return .unknown }
        let value = source.buffer.contents().advanced(by: offset).load(as: UInt8.self)
        return SurfaceKind(rawValue: Int(value)) ?? .unknown
    }

    private static func planeClassification(_ classification: ARPlaneAnchor.Classification) -> SurfaceKind {
        switch classification {
        case .wall: return .wall
        case .floor: return .floor
        case .ceiling: return .ceiling
        case .table: return .table
        case .seat: return .seat
        case .window: return .window
        case .door: return .door
        default: return .unknown
        }
    }

    private static func rotationMatrix(_ transform: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(columns: (SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                               SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                               SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)))
    }

    private static func normalized(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        if finite(value), simd_length_squared(value) > 1e-12 { return simd_normalize(value) }
        if finite(fallback), simd_length_squared(fallback) > 1e-12 { return simd_normalize(fallback) }
        return SIMD3<Float>(0, 1, 0)
    }

    private static func finite(_ vector: SIMD3<Float>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
}
