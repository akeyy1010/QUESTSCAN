import Foundation

/// ARKit classification raw values; independent of Apple rendering frameworks.
enum SurfaceKind: Int, Codable, CaseIterable {
    case unknown = 0, wall = 1, floor = 2, ceiling = 3, table = 4, seat = 5, window = 6, door = 7
    var title: String {
        switch self {
        case .unknown: return "その他"
        case .wall: return "壁"
        case .floor: return "床"
        case .ceiling: return "天井"
        case .table: return "テーブル"
        case .seat: return "椅子・ソファ"
        case .window: return "窓"
        case .door: return "ドア"
        }
    }
    var symbol: String {
        switch self {
        case .floor, .ceiling: return "square.3.layers.3d"
        case .wall: return "rectangle.split.3x1"
        case .seat: return "chair.lounge.fill"
        case .table: return "table.furniture.fill"
        case .window: return "window.vertical.closed"
        case .door: return "door.left.hand.closed"
        case .unknown: return "cube.transparent"
        }
    }
}

enum ScanMode: String, Codable { case lidar, planes, demo
    var title: String {
        switch self { case .lidar: return "LiDAR メッシュ"; case .planes: return "平面スキャン"; case .demo: return "デモルーム" }
    }
}

struct ColorAdjustment: Codable, Equatable {
    var red: Float = 1
    var green: Float = 1
    var blue: Float = 1
    var tintAmount: Float = 0
    var brightness: Float = 0
    var contrast: Float = 1
    var saturation: Float = 1
    static let identity = ColorAdjustment()
}

/// World-space, meter-based triangle geometry copied out of ARKit's transient Metal buffers.
struct MeshSnapshot {
    var id: UUID
    var vertices: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
    var classifications: [SurfaceKind]
}

/// Intrinsics and transform are column-major arrays. JPEG is unrotated native camera imagery.
struct CameraSnapshot {
    var id = UUID()
    var timestamp: TimeInterval
    var transform: [Float] // 16 values
    var intrinsics: [Float] // 9 values, in ORIGINAL camera pixel coordinates
    var width: Int
    var height: Int
    var jpeg: Data
    var depth: [Float]? = nil
    var depthWidth: Int = 0
    var depthHeight: Int = 0
}

struct ScenePart: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var classification: SurfaceKind
    var vertices: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
    var textureCoordinates: [SIMD2<Float>]
    var textureJPEG: Data?
    var adjustment: ColorAdjustment = .identity
    var triangleCount: Int { indices.count / 3 }
}

struct SceneDocument: Identifiable, Codable {
    static let currentVersion = 1
    var formatVersion: Int = currentVersion
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var mode: ScanMode
    var parts: [ScenePart]
    var photosCaptured: Int
    var coverage: Double
    var surfaceArea: Float
    var thumbnailJPEG: Data? = nil
    var qualityNotes: [String]? = nil
    var triangleCount: Int { parts.reduce(0) { $0 + $1.triangleCount } }
    var texturedTriangleCount: Int { parts.filter { $0.textureJPEG != nil }.reduce(0) { $0 + $1.triangleCount } }
}

struct LibraryEntry: Identifiable {
    var id: UUID
    var name: String
    var date: Date
    var mode: ScanMode
    var triangleCount: Int
    var url: URL
    var thumbnailJPEG: Data?
}

struct ScanStatistics {
    var triangleCount: Int = 0
    var anchorCount: Int = 0
    var photoCount: Int = 0
    var coverage: Double = 0
    var surfaceArea: Float = 0
    var elapsed: TimeInterval = 0
    var trackingMessage: String = "カメラをゆっくり動かしてください"
    var trackingGood: Bool = false
    var featureCount: Int = 0
    var retentionLimited: Bool = false
}

struct ScanOptions {
    var autoCapture = true
    var wireframe = true
    var maxPhotos = 32
    var captureInterval: TimeInterval = 1.2
    var translationThreshold: Float = 0.18
    var rotationThreshold: Float = 0.18
    var maxTriangles = 60_000
}

struct BuildResult {
    var document: SceneDocument
    var warnings: [String]
}
