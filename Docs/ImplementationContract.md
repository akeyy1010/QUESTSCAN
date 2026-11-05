# Internal implementation contract

Root: `/home/ubuntu/QUESTSCAN/QUESTSCAN.swiftpm`. iOS 16+, Swift 5.7+, no external package dependencies. UIKit + ARKit + RealityKit. All UI Japanese. Models/ScanData.swift is the source of truth; do not change it without coordinating.

## Processing module
`enum TextureProjector { static func build(meshes: [MeshSnapshot], photos: [CameraSnapshot], mode: ScanMode, name: String, progress: @escaping (Double) -> Void) throws -> BuildResult }`

MeshSnapshot contains WORLD-space vertices/normals, triangle indices and one SurfaceKind per face. Camera transform and intrinsics are column-major [Float]. Photo jpeg is resized but width,height,intrinsics describe the ORIGINAL image; normalized UVs stay valid. ARKit camera looks down negative Z. Raw image top-left origin; texture coordinates need bottom-left origin. Use projection, reject outside frames and depth-inconsistent vertices if depth exists. Group by source mesh, classification and photo; modest group counts. Cap geometry at 60k faces across scene. No UIKit background thread drawing unless safe; use CIContext or CGImage. Warn if no textured faces. `enum DemoScene { static func make() -> SceneDocument }` creates a designed room procedurally, without external assets. Avoid faking scan metrics.

## Render module
`enum SceneRenderer { static func makeEntity(for part: ScenePart, wireframe: Bool = false) throws -> ModelEntity; static func makeWireframe(vertices: [SIMD3<Float>], indices: [UInt32], color: UIColor, limit: Int = 1200) throws -> ModelEntity; static func adjustedJPEG(_ data: Data, adjustment: ColorAdjustment) throws -> Data }`
Use part.adjustment for photo color edits AND material tint, with equivalent exported appearance. Entity.name must be part.id.uuidString for selection. Collision optional: editor generates and handles picks. Wireframe mesh edge ribbons, not debug-only showSceneUnderstanding.

## Export module
`enum USDZExporter { static func export(_ document: SceneDocument, to url: URL) throws }` uses valid uncompressed 64-byte aligned USDZ archive and USDPreviewSurface. `StoredZIP` portable Foundation-only. Modified textures generated via SceneRenderer.adjustedJPEG, untextured use adjustment-based diffuse. No network. `enum ScanLibrary { static func entries() throws -> [LibraryEntry]; static func save(_ document: SceneDocument) throws; static func load(_ entry: LibraryEntry) throws -> SceneDocument; static func delete(_ entry: LibraryEntry) throws }` transactional JSON .questscan storage in Documents/QUESTSCAN. 200MB size guard, version and indices validation. Shared file UI via UIActivityViewController (parent implements).

## Parent-owned app model and AR
`@MainActor final class ScannerModel: ObservableObject`
Published: `screen: AppScreen` enum `.home,.scanning,.processing,.editor`; `statistics: ScanStatistics`; `options: ScanOptions`; `document: SceneDocument?`; `selectedPartID: UUID?`; `library: [LibraryEntry]`; `errorMessage: String?`; `statusMessage: String`; `processingProgress: Double`; `isPaused: Bool`; `isBusy: Bool`; `shareURL: URL?`; `showShare: Bool`; `showWireframe: Bool`; `editRevision: Int`; `undoAvailable: Bool`; `redoAvailable: Bool`; `hasLiDAR: Bool`; `supportsAR: Bool`; `permissionDenied: Bool`.
Computed `selectedPart: ScenePart?`.
Methods: `startScan()`, `pauseOrResume()`, `captureNow()`, `finishScan()`, `cancelScan()`, `openDemo()`, `open(_ entry: LibraryEntry)`, `refreshLibrary()`, `delete(_ entry: LibraryEntry)`, `saveDocument()`, `exportDocument()`, `returnHome()`, `selectPart(_ id: UUID?)`, `updateAdjustment(_ adjustment: ColorAdjustment)`, `resetSelected()`, `undo()`, `redo()`.
Property `let arManager: ARManager`. `ARViewContainer(model: ScannerModel)` owns live AR view.
`EditorViewContainer(model: ScannerModel)` owns non-AR RealityKit view and orbit gestures; parent implements.

## UI module owned by UI agent
Files Views/ContentView.swift and Views/CyberComponents.swift, App/QUESTSCANApp.swift. DO NOT implement ARViewContainer/EditorViewContainer or model. SwiftUI views can use bindings to published model values. Design: midnight ink, electric cyan, lilac accents; adaptive iPad and iPhone; home branded hero with technical line art (Canvas), honest hardware chips, scan/demo entry buttons, stored scans; full bleed scan HUD, bounded panels; editor selection list and color controls, undo redo, save/export; processing screen. No downloadable fonts/images. Privacy and instructional sheet. Color selection convert UIColor to RGB values explicitly. Show scan coverage as observed-surface photo coverage, not whole-room completion. All editable/disabled states and confirmation before cancelling/delete.
