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

enum CaptureSensitivity: String, Codable, CaseIterable, Identifiable {
    case conservative, balanced, responsive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .conservative: return "控えめ"
        case .balanced: return "標準"
        case .responsive: return "高感度"
        }
    }
    var detail: String {
        switch self {
        case .conservative: return "大きく移動したときに撮影。枚数と重複を抑えます。"
        case .balanced: return "移動と角度の変化を標準的に撮影します。"
        case .responsive: return "小さな移動でも撮影。重複や容量が増える場合があります。"
        }
    }
    var minimumMovement: Float {
        switch self { case .conservative: return 0.35; case .balanced: return 0.18; case .responsive: return 0.08 }
    }
    var minimumRotation: Float {
        switch self { case .conservative: return 0.35; case .balanced: return 0.18; case .responsive: return 0.08 }
    }
    var interval: TimeInterval {
        switch self { case .conservative: return 2.0; case .balanced: return 1.2; case .responsive: return 0.7 }
    }
}

struct ScanOptions: Codable, Equatable {
    var autoCapture = true
    var wireframe = true
    var maxPhotos = 32
    var sensitivity: CaptureSensitivity = .balanced
    var captureInterval: TimeInterval = CaptureSensitivity.balanced.interval
    var translationThreshold: Float = CaptureSensitivity.balanced.minimumMovement
    var rotationThreshold: Float = CaptureSensitivity.balanced.minimumRotation
    var maxTriangles = 60_000
    var photoLongEdge = 1_280
    var jpegQuality = 0.72

    static let photoLimitChoices = [8, 16, 24, 32]
    static let qualityChoices = [20_000, 40_000, 60_000]
    static let resolutionChoices = [960, 1_280]
    static let jpegQualityChoices: [Double] = [0.58, 0.72, 0.85]

    mutating func selectSensitivity(_ value: CaptureSensitivity) {
        sensitivity = value
        captureInterval = value.interval
        translationThreshold = value.minimumMovement
        rotationThreshold = value.minimumRotation
    }

    static func stored() -> ScanOptions {
        guard let data = UserDefaults.standard.data(forKey: "QUESTSCAN.scanOptions"),
              let value = try? JSONDecoder().decode(ScanOptions.self, from: data) else { return ScanOptions() }
        return value.sanitized()
    }

    func sanitized() -> ScanOptions {
        var result = self
        result.maxPhotos = Self.photoLimitChoices.contains(maxPhotos) ? maxPhotos : 32
        result.maxTriangles = Self.qualityChoices.contains(maxTriangles) ? maxTriangles : 60_000
        result.photoLongEdge = Self.resolutionChoices.contains(photoLongEdge) ? photoLongEdge : 1_280
        result.jpegQuality = Self.jpegQualityChoices.contains(jpegQuality) ? jpegQuality : 0.72
        result.captureInterval = captureInterval.isFinite ? min(3, max(0.6, captureInterval)) : CaptureSensitivity.balanced.interval
        result.translationThreshold = translationThreshold.isFinite ? min(1, max(0.03, translationThreshold)) : CaptureSensitivity.balanced.minimumMovement
        result.rotationThreshold = rotationThreshold.isFinite ? min(Float.pi, max(0.03, rotationThreshold)) : CaptureSensitivity.balanced.minimumRotation
        // Sensitivity is the source of truth; avoid inconsistent slider values after restoring settings.
        result.captureInterval = result.sensitivity.interval
        result.translationThreshold = result.sensitivity.minimumMovement
        result.rotationThreshold = result.sensitivity.minimumRotation
        return result
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(sanitized()) else { return }
        UserDefaults.standard.set(data, forKey: "QUESTSCAN.scanOptions")
    }
}

struct BuildResult {
    var document: SceneDocument
    var warnings: [String]
}
