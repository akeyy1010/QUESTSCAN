import Foundation
import simd

/// A designed, deterministic cutaway studio, not captured AR data. All pieces carry a
/// Japanese demo label; captured-photo count, coverage, and scanned-area metrics remain zero.
enum DemoScene {
    static func make() -> SceneDocument {
        var room = RoomBuilder()
        let cream = SIMD3<Float>(0.84, 0.85, 0.80)
        let ink = SIMD3<Float>(0.10, 0.15, 0.20)
        let oak = SIMD3<Float>(0.61, 0.43, 0.27)
        let sage = SIMD3<Float>(0.41, 0.56, 0.52)
        let cyan = SIMD3<Float>(0.20, 0.53, 0.58)
        let brass = SIMD3<Float>(0.73, 0.56, 0.30)

        // Three gently varied oak groups form individually modeled planks with fine seams.
        for tone in 0..<3 {
            room.add("オーク床・\(tone + 1)", kind: .floor,
                     color: oak + SIMD3<Float>(repeating: Float(tone) * 0.035)) { g in
                for row in 0..<20 where row % 3 == tone {
                    for column in 0..<3 {
                        g.box(center: SIMD3<Float>(-2 + Float(column) * 2, -0.045, -2.185 + Float(row) * 0.23),
                              size: SIMD3<Float>(1.993, 0.09, 0.223))
                    }
                }
            }
        }
        room.add("壁・カットアウェイ", kind: .wall, color: cream) { g in
            g.box(center: [-3.025, 1.4, 0], size: [0.10, 2.8, 4.6])
            // A real window opening in the back wall, not a texture on a solid wall.
            g.box(center: [-1.15, 1.4, -2.325], size: [3.7, 2.8, 0.10])
            g.box(center: [2.75, 1.4, -2.325], size: [0.5, 2.8, 0.10])
            g.box(center: [1.6, 0.46, -2.325], size: [1.8, 0.92, 0.10])
            g.box(center: [1.6, 2.61, -2.325], size: [1.8, 0.38, 0.10])
        }
        room.add("巾木・天井縁", kind: .wall, color: [0.70, 0.73, 0.69]) { g in
            g.box(center: [0, 0.08, -2.261], size: [6, 0.16, 0.028])
            g.box(center: [-2.961, 0.08, 0], size: [0.028, 0.16, 4.6])
            g.box(center: [0, 2.73, -2.25], size: [6, 0.14, 0.05])
            g.box(center: [-2.95, 2.73, 0], size: [0.10, 0.14, 4.6])
        }
        room.add("窓・空色パネル", kind: .window, color: [0.42, 0.65, 0.73]) { g in
            g.box(center: [1.6, 1.67, -2.36], size: [1.8, 1.5, 0.025])
        }
        room.add("窓枠", kind: .window, color: ink) { g in
            for x in [Float]([0.70, 1.60, 2.50]) {
                g.box(center: [x, 1.67, -2.23], size: [0.055, 1.55, 0.11])
            }
            for y in [Float]([0.92, 1.67, 2.42]) {
                g.box(center: [1.6, y, -2.23], size: [1.85, 0.055, 0.11])
            }
            g.box(center: [1.6, 0.91, -2.16], size: [1.95, 0.065, 0.30])
        }
        room.add("織りラグ", kind: .floor, color: cyan) { g in
            g.roundedBox(center: [-0.25, 0.018, 0.20], size: [3.20, 0.026, 2.04], radius: 0.012)
        }
        room.add("ラグの織りライン", kind: .floor, color: [0.34, 0.66, 0.68]) { g in
            for x in [Float]([-1.67, -1.58, 1.08, 1.17]) {
                g.box(center: [x, 0.034, 0.20], size: [0.026, 0.004, 1.92])
            }
        }

        room.add("ソファ・フレーム", kind: .seat, color: [0.30, 0.43, 0.41]) { g in
            g.roundedBox(center: [-1.15, 0.37, -1.29], size: [2.55, 0.33, 0.94], radius: 0.10)
            g.roundedBox(center: [-1.15, 0.79, -1.65], size: [2.55, 0.79, 0.25], radius: 0.085)
            for x in [Float]([-2.35, 0.05]) {
                g.roundedBox(center: [x, 0.62, -1.29], size: [0.19, 0.67, 0.96], radius: 0.075)
            }
        }
        room.add("ソファ・座面", kind: .seat, color: sage) { g in
            for x in [Float]([-1.72, -0.58]) {
                g.roundedBox(center: [x, 0.57, -1.22], size: [1.10, 0.23, 0.73], radius: 0.09)
                g.roundedBox(center: [x, 0.88, -1.48], size: [1.09, 0.50, 0.20], radius: 0.075)
            }
        }
        room.add("ソファ・脚", kind: .seat, color: ink) { g in
            for x in [Float]([-2.13, -0.17]) {
                for z in [Float]([-1.62, -0.98]) {
                    g.frustum(center: [x, 0.12, z], height: 0.24, bottomRadius: 0.035, topRadius: 0.043, segments: 12)
                }
            }
        }
        room.add("クッション・リネン", kind: .seat, color: [0.89, 0.82, 0.65]) { g in
            g.roundedBox(center: [-2.0, 0.82, -1.28], size: [0.42, 0.40, 0.18], radius: 0.075, yaw: -0.18)
        }
        room.add("クッション・ライラック", kind: .seat, color: [0.64, 0.59, 0.72]) { g in
            g.roundedBox(center: [-0.37, 0.82, -1.31], size: [0.40, 0.38, 0.18], radius: 0.075, yaw: 0.16)
        }

        room.add("丸いコーヒーテーブル", kind: .table, color: [0.46, 0.29, 0.19]) { g in
            g.frustum(center: [-0.20, 0.47, 0.16], height: 0.075, bottomRadius: 0.61, topRadius: 0.61)
            for angle in [Float]([0.0, 2.0944, 4.1888]) {
                g.frustum(center: [-0.20 + cos(angle) * 0.40, 0.24, 0.16 + sin(angle) * 0.40],
                          height: 0.43, bottomRadius: 0.042, topRadius: 0.06, segments: 14)
            }
        }
        room.add("テーブルのトレイ", kind: .unknown, color: brass) { g in
            g.frustum(center: [-0.18, 0.523, 0.12], height: 0.018, bottomRadius: 0.23, topRadius: 0.23)
        }
        room.add("陶器のカップ", kind: .unknown, color: [0.85, 0.87, 0.81]) { g in
            g.frustum(center: [-0.17, 0.58, 0.11], height: 0.10, bottomRadius: 0.055, topRadius: 0.07, segments: 20)
        }
        room.add("読書本", kind: .unknown, color: [0.14, 0.23, 0.30]) { g in
            g.box(center: [0.10, 0.529, 0.33], size: [0.19, 0.035, 0.25], yaw: 0.18)
        }

        room.add("サイドボード", kind: .table, color: oak) { g in
            g.roundedBox(center: [1.65, 0.45, -1.65], size: [1.66, 0.62, 0.54], radius: 0.025)
            for x in [Float]([0.96, 2.34]) {
                for z in [Float]([-1.84, -1.45]) {
                    g.box(center: [x, 0.095, z], size: [0.055, 0.19, 0.055])
                }
            }
        }
        room.add("サイドボードの扉", kind: .door, color: [0.53, 0.36, 0.22]) { g in
            for x in [Float]([1.24, 2.06]) {
                g.box(center: [x, 0.46, -1.368], size: [0.79, 0.56, 0.018])
            }
        }
        room.add("取っ手", kind: .unknown, color: brass) { g in
            for x in [Float]([1.54, 1.76]) {
                g.box(center: [x, 0.51, -1.344], size: [0.022, 0.15, 0.022])
            }
        }
        room.add("花器", kind: .unknown, color: [0.67, 0.39, 0.29]) { g in
            g.frustum(center: [1.20, 0.91, -1.64], height: 0.30, bottomRadius: 0.09, topRadius: 0.065)
        }
        room.add("枝のオブジェ", kind: .unknown, color: brass) { g in
            g.frustum(center: [1.2, 1.21, -1.64], height: 0.42, bottomRadius: 0.008, topRadius: 0.006, segments: 8)
            g.ellipsoid(center: [1.2, 1.42, -1.64], radii: [0.095, 0.075, 0.024], yaw: 0.3)
        }
        room.add("サイドボードの本・淡色", kind: .unknown, color: [0.76, 0.78, 0.70]) { g in
            for index in 0..<3 {
                g.box(center: [2.08, 0.79 + Float(index) * 0.035, -1.65], size: [0.32, 0.03, 0.25], yaw: Float(index) * 0.035)
            }
        }

        room.add("アートの額縁", kind: .wall, color: ink) { g in
            g.box(center: [-1.25, 1.90, -2.23], size: [1.28, 0.91, 0.055])
        }
        room.add("アートの台紙", kind: .wall, color: [0.89, 0.85, 0.73]) { g in
            g.box(center: [-1.25, 1.90, -2.196], size: [1.18, 0.81, 0.012])
        }
        room.add("アート・円", kind: .wall, color: cyan) { g in
            g.ellipsoid(center: [-1.41, 1.94, -2.183], radii: [0.23, 0.23, 0.010], latitudes: 12, longitudes: 28)
        }
        room.add("アート・幾何学", kind: .wall, color: [0.68, 0.47, 0.34]) { g in
            g.box(center: [-1.04, 1.77, -2.173], size: [0.38, 0.25, 0.012])
            g.box(center: [-1.05, 2.15, -2.173], size: [0.20, 0.045, 0.012])
        }

        room.add("フロアランプ・金属", kind: .unknown, color: ink) { g in
            g.frustum(center: [1.96, 0.045, 0.68], height: 0.07, bottomRadius: 0.23, topRadius: 0.22)
            g.frustum(center: [1.96, 0.88, 0.68], height: 1.66, bottomRadius: 0.018, topRadius: 0.018, segments: 12)
        }
        room.add("フロアランプ・シェード", kind: .unknown, color: [0.88, 0.81, 0.62]) { g in
            g.frustum(center: [1.96, 1.69, 0.68], height: 0.34, bottomRadius: 0.34, topRadius: 0.16)
        }
        room.add("鉢・テラコッタ", kind: .unknown, color: [0.61, 0.36, 0.26]) { g in
            g.frustum(center: [2.59, 0.21, -0.81], height: 0.42, bottomRadius: 0.18, topRadius: 0.24)
            g.frustum(center: [2.59, 0.407, -0.81], height: 0.052, bottomRadius: 0.255, topRadius: 0.255)
        }
        room.add("鉢の土", kind: .unknown, color: [0.17, 0.13, 0.11]) { g in
            g.frustum(center: [2.59, 0.437, -0.81], height: 0.01, bottomRadius: 0.215, topRadius: 0.215)
        }
        room.add("観葉植物・茎", kind: .unknown, color: [0.27, 0.37, 0.22]) { g in
            g.frustum(center: [2.59, 0.89, -0.81], height: 0.92, bottomRadius: 0.013, topRadius: 0.007, segments: 8)
        }
        for shade in 0..<2 {
            room.add("観葉植物・葉\(shade + 1)", kind: .unknown,
                     color: shade == 0 ? [0.22, 0.43, 0.31] : [0.32, 0.54, 0.36]) { g in
                for index in 0..<10 where index % 2 == shade {
                    let angle = Float(index) * 2.40
                    let height = 0.60 + Float(index) * 0.077
                    let radius: Float = index > 6 ? 0.16 : 0.24
                    g.ellipsoid(center: [2.59 + cos(angle) * radius, height, -0.81 + sin(angle) * radius],
                                radii: [0.29, 0.085, 0.12], yaw: -angle, latitudes: 6, longitudes: 12)
                }
            }
        }
        // Deliberately no fake photos, scan coverage, or scanned-surface area.
        return SceneDocument(name: "デモルーム・静かなアトリエ", mode: .demo, parts: room.parts,
                             photosCaptured: 0, coverage: 0, surfaceArea: 0)
    }

    private struct RoomBuilder {
        var parts: [ScenePart] = []
        mutating func add(_ name: String, kind: SurfaceKind, color: SIMD3<Float>,
                          build: (inout Geometry) -> Void) {
            var geometry = Geometry()
            build(&geometry)
            let adjustment = ColorAdjustment(red: color.x, green: color.y, blue: color.z, tintAmount: 1)
            parts.append(ScenePart(name: "デモ・" + name, classification: kind,
                                   vertices: geometry.vertices, normals: geometry.normals,
                                   indices: geometry.indices, textureCoordinates: geometry.uvs,
                                   textureJPEG: nil, adjustment: adjustment))
        }
    }

    private struct Geometry {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var uvs: [SIMD2<Float>] = []

        private func rotate(_ p: SIMD3<Float>, yaw: Float) -> SIMD3<Float> {
            SIMD3<Float>(cos(yaw) * p.x + sin(yaw) * p.z, p.y,
                         -sin(yaw) * p.x + cos(yaw) * p.z)
        }
        private mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float>,
                                     center: SIMD3<Float>, yaw: Float = 0) -> UInt32 {
            let index = UInt32(vertices.count)
            vertices.append(center + rotate(p, yaw: yaw))
            normals.append(rotate(n, yaw: yaw))
            uvs.append(uv)
            return index
        }

        mutating func box(center: SIMD3<Float>, size: SIMD3<Float>, yaw: Float = 0) {
            roundedBox(center: center, size: size, radius: 0, yaw: yaw)
        }

        /// Face grids are rounded by clamping to an inner box and offsetting along the
        /// resulting sphere normal. Attribute seams remain per-face, not flattened.
        mutating func roundedBox(center: SIMD3<Float>, size: SIMD3<Float>, radius: Float, yaw: Float = 0) {
            let half = size / 2
            let r = max(0, min(radius, min(half.x, min(half.y, half.z)) * 0.98))
            let faceAxes: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
                ([1, 0, 0], [0, 0, -1], [0, 1, 0]), ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
                ([0, 1, 0], [1, 0, 0], [0, 0, -1]), ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
                ([0, 0, 1], [1, 0, 0], [0, 1, 0]), ([0, 0, -1], [-1, 0, 0], [0, 1, 0])
            ]
            func coordinates(_ extent: Float) -> [Float] {
                guard r > 0 else { return [-extent, extent] }
                return [-extent, -extent + r * 0.5, -extent + r,
                        extent - r, extent - r * 0.5, extent]
            }
            for (normal, u, v) in faceAxes {
                let uExtent = abs(simd_dot(u, half))
                let vExtent = abs(simd_dot(v, half))
                let faceCenter = normal * abs(simd_dot(normal, half))
                let us = coordinates(uExtent), vs = coordinates(vExtent)
                let base = UInt32(vertices.count)
                for (row, vertical) in vs.enumerated() {
                    for (column, horizontal) in us.enumerated() {
                        let p = faceCenter + u * horizontal + v * vertical
                        var position = p, n = normal
                        if r > 0 {
                            let inner = half - SIMD3<Float>(repeating: r)
                            let clamped = simd_min(simd_max(p, -inner), inner)
                            n = simd_normalize(p - clamped)
                            position = clamped + n * r
                        }
                        _ = vertex(position, n, [Float(column) / Float(us.count - 1), Float(row) / Float(vs.count - 1)],
                                   center: center, yaw: yaw)
                    }
                }
                for row in 0..<(vs.count - 1) {
                    for column in 0..<(us.count - 1) {
                        let a = base + UInt32(row * us.count + column)
                        let b = a + 1, c = a + UInt32(us.count), d = c + 1
                        indices.append(contentsOf: [a, b, d, a, d, c])
                    }
                }
            }
        }

        mutating func frustum(center: SIMD3<Float>, height: Float, bottomRadius: Float, topRadius: Float,
                              segments: Int = 28) {
            let count = min(48, max(8, segments))
            let start = UInt32(vertices.count)
            let slope = (bottomRadius - topRadius) / height
            for index in 0...count {
                let angle = Float(index) / Float(count) * 2 * Float.pi
                let radial = SIMD3<Float>(cos(angle), 0, sin(angle))
                let normal = simd_normalize(SIMD3<Float>(radial.x, slope, radial.z))
                _ = vertex(radial * bottomRadius + [0, -height / 2, 0], normal,
                           [Float(index) / Float(count), 0], center: center)
                _ = vertex(radial * topRadius + [0, height / 2, 0], normal,
                           [Float(index) / Float(count), 1], center: center)
            }
            for index in 0..<count {
                let b = start + UInt32(index * 2), t = b + 1, bn = b + 2, tn = b + 3
                indices.append(contentsOf: [b, t, tn, b, tn, bn])
            }
            for top in [false, true] {
                let y = top ? height / 2 : -height / 2
                let radius = top ? topRadius : bottomRadius
                let normal = SIMD3<Float>(0, top ? 1 : -1, 0)
                let middle = vertex([0, y, 0], normal, [0.5, 0.5], center: center)
                let ring = UInt32(vertices.count)
                for index in 0...count {
                    let angle = Float(index) / Float(count) * 2 * Float.pi
                    _ = vertex([cos(angle) * radius, y, sin(angle) * radius], normal,
                               [cos(angle) * 0.5 + 0.5, sin(angle) * 0.5 + 0.5], center: center)
                }
                for index in 0..<count {
                    let a = ring + UInt32(index), b = a + 1
                    indices.append(contentsOf: top ? [middle, b, a] : [middle, a, b])
                }
            }
        }

        mutating func ellipsoid(center: SIMD3<Float>, radii: SIMD3<Float>, yaw: Float = 0,
                                latitudes: Int = 8, longitudes: Int = 16) {
            let rows = min(16, max(4, latitudes)), columns = min(32, max(8, longitudes))
            let start = UInt32(vertices.count)
            for row in 0...rows {
                let theta = Float(row) / Float(rows) * Float.pi
                for column in 0...columns {
                    let phi = Float(column) / Float(columns) * 2 * Float.pi
                    let unit = SIMD3<Float>(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
                    let normal = simd_normalize(unit / radii)
                    _ = vertex(unit * radii, normal, [Float(column) / Float(columns), 1 - Float(row) / Float(rows)],
                               center: center, yaw: yaw)
                }
            }
            for row in 0..<rows {
                for column in 0..<columns {
                    let a = start + UInt32(row * (columns + 1) + column)
                    let b = a + 1, c = a + UInt32(columns + 1), d = c + 1
                    if row > 0 { indices.append(contentsOf: [a, b, c]) }
                    if row < rows - 1 { indices.append(contentsOf: [b, d, c]) }
                }
            }
        }
    }
}
