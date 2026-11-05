import Foundation
import ARKit
import RealityKit
import UIKit
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import simd

/// Public lifecycle methods and callback properties are used on the main thread.
/// This is deliberately NOT @MainActor: ARSessionDelegate executes on workQueue.
/// All retained scan state and transient buffer reads are confined to that queue.
final class ARManager: NSObject, ARSessionDelegate {
    let mode: ScanMode
    var onStatistics: ((ScanStatistics) -> Void)?
    var onError: ((String) -> Void)?

    private let workQueue = DispatchQueue(label: "com.questscan.ar-copy", qos: .userInitiated,
                                          autoreleaseFrequency: .workItem)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private static let anchorLimit = 64
    private static let facesPerAnchor = 5_000
    private static let wireAnchorLimit = 24
    private static let wireEdgeLimit = 400

    // MAIN-THREAD state. Rendering never occurs on the delegate queue.
    private weak var arView: ARView?
    private var mainSession: ARSession?
    private var configuration: ARWorldTrackingConfiguration?
    private var mainGeneration: UInt64 = 0
    private var mainRunning = false
    private var wireRoot: AnchorEntity?
    private var wireEntities: [UUID: ModelEntity] = [:]
    private var drawnRevisions: [UUID: UInt64] = [:]
    private var wireErrorReported = false

    // SERIAL DELEGATE-QUEUE state.
    private var generation: UInt64 = 0
    private var sessionID: ObjectIdentifier?
    private var running = false
    private var paused = false
    private var interrupted = false
    private var options = ScanOptions()
    private var meshes: [UUID: MeshSnapshot] = [:]
    private var anchorOrder: [UUID] = []
    private var revisions: [UUID: UInt64] = [:]
    private var nextRevision: UInt64 = 0
    private var photos: [CameraSnapshot] = []
    private var latestFrame: ARFrame?
    private var lastPhotoTransform: simd_float4x4?
    private var lastPhotoTimestamp: TimeInterval = -.greatestFiniteMagnitude
    private var manualCapturePending = false
    private var elapsedTotal: TimeInterval = 0
    private var activeSince: TimeInterval?
    private var trackingGood = false
    private var trackingMessage = "カメラをゆっくり動かしてください"
    private var featureCount = 0
    private var retentionLimited = false
    private var estimate = CoverageEstimator.Estimate()
    private var estimateDirty = true
    private var lastEstimateAt: TimeInterval = 0
    private var lastStatisticsAt: TimeInterval = 0
    private var lastWireAt: TimeInterval = 0
    private var wireInFlight = false
    private var wireRedrawRequested = false

    override init() {
        let mesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            || ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        mode = mesh ? .lidar : .planes
        super.init()
    }

    /// Attaching is an explicit NEW scan. The view must disable automatic configuration.
    @MainActor
    func attach(_ view: ARView, options newOptions: ScanOptions) {
        assert(Thread.isMainThread)
        if arView === view, mainRunning { updateOptions(newOptions); return }
        mainSession?.pause()
        mainSession?.delegate = nil
        removeWireframe()
        mainGeneration &+= 1
        let ticket = mainGeneration
        let session = view.session
        arView = view
        mainSession = session
        wireErrorReported = false
        mainRunning = ARWorldTrackingConfiguration.isSupported
        let safeOptions = sanitized(newOptions)
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.clearState(generation: ticket, options: safeOptions)
            self.sessionID = ObjectIdentifier(session)
            self.running = ARWorldTrackingConfiguration.isSupported
            self.activeSince = self.running ? ProcessInfo.processInfo.systemUptime : nil
            if !self.running { self.trackingMessage = "この端末はARワールドトラッキングに対応していません" }
            self.publishStatistics(force: true)
        }
        guard mainRunning else {
            deliverError("この端末はARワールドトラッキングに対応していません", generation: ticket)
            return
        }
        view.automaticallyConfigureSession = false
        view.debugOptions = []
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        // Our bounded edge geometry is the wireframe, not RealityKit debug overlays.
        view.environment.sceneUnderstanding.options = []
        let config = makeConfiguration()
        configuration = config
        session.delegateQueue = workQueue
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Changes capture/display/retention settings without restarting the AR coordinate frame.
    @MainActor
    func updateOptions(_ newOptions: ScanOptions) {
        assert(Thread.isMainThread)
        let safeOptions = sanitized(newOptions)
        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.sameOptions(self.options, safeOptions) else { return }
            self.options = safeOptions
            if self.photos.count > safeOptions.maxPhotos {
                self.photos.removeFirst(self.photos.count - safeOptions.maxPhotos)
                self.estimateDirty = true
            }
            self.enforceGeometryBudget()
            self.pushWireframe(force: true)
            self.publishStatistics(force: true)
        }
    }

    @MainActor
    func pause() {
        assert(Thread.isMainThread)
        mainSession?.pause()
        workQueue.async { [weak self] in
            guard let self = self, self.running else { return }
            self.finishActiveInterval()
            self.paused = true
            self.latestFrame = nil
            self.manualCapturePending = false
            self.trackingGood = false
            self.trackingMessage = "一時停止中・取得した形状と写真は保持されています"
            self.publishStatistics(force: true)
        }
    }

    @MainActor
    func resume() {
        assert(Thread.isMainThread)
        guard mainRunning, let session = mainSession, let config = configuration else { return }
        workQueue.async { [weak self] in
            guard let self = self, self.running else { return }
            self.paused = false
            if self.activeSince == nil { self.activeSince = ProcessInfo.processInfo.systemUptime }
            self.trackingGood = false
            self.trackingMessage = "同じ場所でゆっくり動かして位置の復帰を待ってください"
            self.publishStatistics(force: true)
        }
        // No resetTracking/removeExistingAnchors: saved geometry and cameras stay coherent.
        session.run(config)
    }

    /// Stop releases AR resources but deliberately preserves copied meshes and photos.
    @MainActor
    func stop() {
        assert(Thread.isMainThread)
        mainRunning = false
        mainSession?.pause()
        mainSession?.delegate = nil
        mainSession = nil
        configuration = nil
        arView = nil
        removeWireframe()
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.finishActiveInterval()
            self.running = false
            self.paused = false
            self.sessionID = nil
            self.latestFrame = nil
            self.manualCapturePending = false
            self.trackingGood = false
            self.trackingMessage = "スキャン停止・取得データは保持されています"
            self.publishStatistics(force: true)
        }
    }

    /// Only an explicit reset deletes the buffers and creates a new coordinate frame.
    @MainActor
    func reset() {
        assert(Thread.isMainThread)
        mainGeneration &+= 1
        let ticket = mainGeneration
        let session = mainSession
        let canRun = mainRunning && session != nil
        removeWireframe()
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let currentOptions = self.options
            self.clearState(generation: ticket, options: currentOptions)
            self.running = canRun
            self.sessionID = session.map { ObjectIdentifier($0) }
            self.activeSince = canRun ? ProcessInfo.processInfo.systemUptime : nil
            self.publishStatistics(force: true)
        }
        if canRun, let session = session, let config = configuration {
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    @MainActor
    func captureNow() {
        assert(Thread.isMainThread)
        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.running, !self.paused, !self.interrupted else {
                self.deliverError("撮影するにはスキャンを再開してください", generation: self.generation)
                return
            }
            if let frame = self.latestFrame,
               ProcessInfo.processInfo.systemUptime - frame.timestamp < 0.5 {
                self.maybeCapture(frame, manual: true)
            } else { self.manualCapturePending = true }
            self.publishStatistics(force: true)
        }
    }

    /// A serial barrier copies value snapshots after pending delegates, even after stop().
    /// The completion is always asynchronous on main; no ARKit buffers escape.
    @MainActor
    func snapshot(completion: @escaping ([MeshSnapshot], [CameraSnapshot], ScanMode, ScanStatistics) -> Void) {
        assert(Thread.isMainThread)
        workQueue.async { [self] in
            refreshEstimate(force: true)
            let meshCopy = anchorOrder.compactMap { meshes[$0] }
            let photoCopy = photos
            let statistics = currentStatistics()
            let capturedMode = mode
            DispatchQueue.main.async { completion(meshCopy, photoCopy, capturedMode, statistics) }
        }
    }

    // MARK: ARSessionDelegate — every implementation runs on workQueue.

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard accepts(session), !paused, !interrupted else { return }
        latestFrame = frame
        featureCount = frame.rawFeaturePoints?.points.count ?? 0
        updateTracking(frame)
        let manual = manualCapturePending
        manualCapturePending = false
        if options.autoCapture || manual { maybeCapture(frame, manual: manual) }
        pushWireframe()
        publishStatistics()
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { receive(anchors, session: session) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { receive(anchors, session: session) }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard accepts(session) else { return }
        for anchor in anchors { removeMesh(anchor.identifier) }
        pushWireframe()
        publishStatistics()
    }

    func sessionWasInterrupted(_ session: ARSession) {
        guard accepts(session) else { return }
        interrupted = true
        latestFrame = nil
        finishActiveInterval()
        trackingGood = false
        trackingMessage = "ARが中断されました。カメラが戻るまで撮影を停止します"
        publishStatistics(force: true)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard accepts(session) else { return }
        interrupted = false
        if !paused { activeSince = ProcessInfo.processInfo.systemUptime }
        trackingGood = false
        trackingMessage = "中断から復帰中・元の場所にカメラを向けてください"
        // Do not silently reset the world origin; ARKit attempts relocalization.
        publishStatistics(force: true)
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    func session(_ session: ARSession, didFailWithError error: Error) {
        guard accepts(session) else { return }
        finishActiveInterval()
        running = false
        trackingGood = false
        latestFrame = nil
        trackingMessage = "ARを継続できません。取得済みデータは保持されています"
        let ticket = generation
        deliverError("ARエラー: \(error.localizedDescription)", generation: ticket)
        publishStatistics(force: true)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.mainGeneration == ticket else { return }
            self.mainRunning = false
            self.mainSession?.pause()
        }
    }

    private func accepts(_ session: ARSession) -> Bool {
        running && sessionID == ObjectIdentifier(session)
    }

    private func receive(_ anchors: [ARAnchor], session: ARSession) {
        guard accepts(session), !paused, !interrupted else { return }
        let limit = min(Self.facesPerAnchor, options.maxTriangles)
        for anchor in anchors {
            let copied: MeshSnapshot?
            if mode == .lidar, let mesh = anchor as? ARMeshAnchor {
                if mesh.geometry.faces.count > limit { retentionLimited = true }
                copied = MeshExtractor.mesh(mesh, triangleLimit: limit)
            } else if mode == .planes, let plane = anchor as? ARPlaneAnchor {
                if plane.geometry.triangleCount > limit { retentionLimited = true }
                copied = MeshExtractor.plane(plane, triangleLimit: limit)
            } else { continue }
            guard let copied = copied else { removeMesh(anchor.identifier); continue }
            meshes[copied.id] = copied
            anchorOrder.removeAll { $0 == copied.id }
            anchorOrder.append(copied.id)
            nextRevision &+= 1
            revisions[copied.id] = nextRevision
            estimateDirty = true
            enforceGeometryBudget()
        }
        pushWireframe()
        publishStatistics()
    }

    private func removeMesh(_ id: UUID) {
        if meshes.removeValue(forKey: id) != nil { estimateDirty = true }
        revisions.removeValue(forKey: id)
        anchorOrder.removeAll { $0 == id }
    }

    private func enforceGeometryBudget() {
        var total = meshes.values.reduce(0) { $0 + $1.indices.count / 3 }
        while anchorOrder.count > Self.anchorLimit || (total > options.maxTriangles && anchorOrder.count > 1) {
            retentionLimited = true
            let id = anchorOrder[0]
            total -= (meshes[id]?.indices.count ?? 0) / 3
            removeMesh(id)
        }
        if total > options.maxTriangles, let id = anchorOrder.first, let mesh = meshes[id] {
            retentionLimited = true
            meshes[id] = MeshExtractor.limited(mesh, triangleLimit: options.maxTriangles)
            nextRevision &+= 1
            revisions[id] = nextRevision
            estimateDirty = true
        }
    }

    // MARK: Native image capture

    private func updateTracking(_ frame: ARFrame) {
        switch frame.camera.trackingState {
        case .normal:
            trackingGood = true
            if let intensity = frame.lightEstimate?.ambientIntensity, intensity < 150 {
                trackingMessage = "暗すぎるため撮影を保留中・照明を増やしてください"
            } else if let intensity = frame.lightEstimate?.ambientIntensity, intensity < 350 {
                trackingMessage = "少し暗い環境です。照明を増やし、ゆっくり動かしてください"
            } else if let intensity = frame.lightEstimate?.ambientIntensity, intensity > 2_000 {
                trackingMessage = "強い光に注意・反射や窓を避けて撮影してください"
            } else if photos.count >= options.maxPhotos {
                trackingMessage = "写真の上限に達しました・形状の取得は続けられます"
            } else if meshes.isEmpty {
                trackingMessage = mode == .planes ? "床や壁をゆっくり映してください・平面のみを取得します" : "近くの床や壁をゆっくり映してください"
            } else {
                trackingMessage = "未撮影の面を別の角度から映してください・表示率は観測面の写真適合推定です"
            }
        case .notAvailable:
            trackingGood = false
            trackingMessage = "位置追跡が利用できません・撮影を保留しています"
        case .limited(let reason):
            trackingGood = false
            switch reason {
            case .initializing: trackingMessage = "位置を初期化中・周囲をゆっくり映してください"
            case .excessiveMotion: trackingMessage = "動きが速すぎます・ゆっくり動かしてください"
            case .insufficientFeatures: trackingMessage = "手掛かりが少ない環境です・模様のある明るい面を映してください"
            case .relocalizing: trackingMessage = "位置を復帰中・スキャンした元の場所に戻してください"
            @unknown default: trackingMessage = "位置追跡が不安定です・撮影を保留しています"
            }
        }
    }

    private func maybeCapture(_ frame: ARFrame, manual: Bool) {
        guard case .normal = frame.camera.trackingState else { return }
        guard running, !paused, !interrupted else { return }
        guard photos.count < options.maxPhotos else {
            if manual { deliverError("写真の設定上限（\(options.maxPhotos)枚）に達しました", generation: generation) }
            return
        }
        guard frame.lightEstimate.map({ $0.ambientIntensity >= 150 }) ?? true else { return }
        let elapsed = frame.timestamp - lastPhotoTimestamp
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard elapsed >= (manual ? 0.4 : max(options.captureInterval, lowPower ? 2.0 : 0.6)) else { return }
        if !manual, let previous = lastPhotoTransform {
            let now = frame.camera.transform
            let translation = simd_length(SIMD3<Float>(now.columns.3.x - previous.columns.3.x,
                                                       now.columns.3.y - previous.columns.3.y,
                                                       now.columns.3.z - previous.columns.3.z))
            let q1 = simd_quatf(previous), q2 = simd_quatf(now)
            let cosine = min(Float(1), max(Float(0), abs(simd_dot(q1.vector, q2.vector))))
            let angle = 2 * acos(cosine)
            guard translation >= options.translationThreshold || angle >= options.rotationThreshold else { return }
        }
        let highCountMode = options.maxPhotos > 32
        let longestSide = highCountMode ? min(640, options.photoLongEdge)
            : (lowPower ? min(960, options.photoLongEdge) : options.photoLongEdge)
        let photoByteLimit = highCountMode ? 180_000 : 1_500_000
        guard let photo = makePhoto(frame, longestSide: longestSide, jpegQuality: options.jpegQuality,
                                    maximumBytes: photoByteLimit, depthLongestSide: highCountMode ? 64 : 192) else {
            trackingMessage = "写真を保存できませんでした・明るい面を映して再撮影してください"
            if manual { deliverError("カメラ画像の保存に失敗しました", generation: generation) }
            return
        }
        photos.append(photo)
        lastPhotoTransform = frame.camera.transform
        lastPhotoTimestamp = frame.timestamp
        estimateDirty = true
    }

    private func makePhoto(_ frame: ARFrame, longestSide: Int, jpegQuality: Double,
                           maximumBytes: Int, depthLongestSide: Int) -> CameraSnapshot? {
        let buffer = frame.capturedImage
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        // At high capture counts, also reduce dimensions if needed so an unusually
        // noisy image cannot defeat the aggregate in-memory photo budget.
        var sizeCandidates = [longestSide]
        if maximumBytes < 1_500_000 {
            sizeCandidates += [min(480, longestSide), min(320, longestSide)]
        }
        sizeCandidates = Array(Set(sizeCandidates)).sorted(by: >)
        let qualityFloor = maximumBytes < 1_500_000 ? 0.45 : 0.58
        let candidates = Array(Set([jpegQuality, max(qualityFloor, jpegQuality * 0.85), qualityFloor])).sorted(by: >)
        let sourceImage = CIImage(cvPixelBuffer: buffer)
        var encodedJPEG: Data?
        for targetSide in sizeCandidates where encodedJPEG == nil {
            let scale = min(1, CGFloat(targetSide) / CGFloat(max(width, height)))
            let image = sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let outputWidth = max(1, Int((CGFloat(width) * scale).rounded()))
            let outputHeight = max(1, Int((CGFloat(height) * scale).rounded()))
            guard let cgImage = imageContext.createCGImage(image, from: CGRect(x: 0, y: 0,
                width: CGFloat(outputWidth), height: CGFloat(outputHeight))) else { continue }
            for quality in candidates {
                let bytes = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
                // No UIImage rotation, displayTransform, or orientation conversion: native image axes.
                CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: quality,
                                                                  kCGImagePropertyOrientation: 1] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { continue }
                if bytes.length <= maximumBytes { encodedJPEG = bytes as Data; break }
            }
        }
        guard let jpeg = encodedJPEG else { return nil }
        let transform = frame.camera.transform
        var intrinsics = frame.camera.intrinsics
        // Usually identical. Handle any buffer-resolution discrepancy without lying about pixels.
        let resolution = frame.camera.imageResolution
        if resolution.width > 0, resolution.height > 0 {
            let sx = Float(width) / Float(resolution.width), sy = Float(height) / Float(resolution.height)
            intrinsics.columns.0.x *= sx; intrinsics.columns.1.x *= sx; intrinsics.columns.2.x *= sx
            intrinsics.columns.0.y *= sy; intrinsics.columns.1.y *= sy; intrinsics.columns.2.y *= sy
        }
        var result = CameraSnapshot(timestamp: frame.timestamp,
                                    transform: (0..<4).flatMap { column in (0..<4).map { transform[column][$0] } },
                                    intrinsics: (0..<3).flatMap { column in (0..<3).map { intrinsics[column][$0] } },
                                    width: width, height: height, jpeg: jpeg)
        if let depthData = frame.sceneDepth ?? frame.smoothedSceneDepth,
           let depth = copyDepth(depthData, longestSide: depthLongestSide) {
            result.depth = depth.values; result.depthWidth = depth.width; result.depthHeight = depth.height
        }
        return result
    }

    private func copyDepth(_ data: ARDepthData, longestSide: Int) -> (values: [Float], width: Int, height: Int)? {
        let buffer = data.depthMap
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, stride >= width * 4 else { return nil }
        let scale = min(1.0, Double(longestSide) / Double(max(width, height)))
        let outputWidth = max(1, Int((Double(width) * scale).rounded()))
        let outputHeight = max(1, Int((Double(height) * scale).rounded()))
        let confidence = data.confidenceMap
        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceStride = 0, confidenceWidth = 0, confidenceHeight = 0
        var confidenceLocked = false
        if let confidence = confidence,
           CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess {
            confidenceLocked = true
            confidenceBase = CVPixelBufferGetBaseAddress(confidence)
            confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
            confidenceWidth = CVPixelBufferGetWidth(confidence)
            confidenceHeight = CVPixelBufferGetHeight(confidence)
        }
        defer { if confidenceLocked, let confidence = confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        var values = [Float](repeating: 0, count: outputWidth * outputHeight)
        for y in 0..<outputHeight {
            let sourceY = min(height - 1, Int((Double(y) + 0.5) * Double(height) / Double(outputHeight)))
            for x in 0..<outputWidth {
                let sourceX = min(width - 1, Int((Double(x) + 0.5) * Double(width) / Double(outputWidth)))
                if let confidenceBase = confidenceBase, confidenceWidth > 0, confidenceHeight > 0,
                   confidenceStride >= confidenceWidth {
                    let cx = min(confidenceWidth - 1, sourceX * confidenceWidth / width)
                    let cy = min(confidenceHeight - 1, sourceY * confidenceHeight / height)
                    if confidenceBase.advanced(by: cy * confidenceStride + cx).load(as: UInt8.self) == 0 { continue }
                }
                var value: Float = 0
                memcpy(&value, base.advanced(by: sourceY * stride + sourceX * 4), 4)
                if value.isFinite, value > 0, value < 20 { values[y * outputWidth + x] = value }
            }
        }
        return (values, outputWidth, outputHeight)
    }

    // MARK: Main-thread bounded wireframe drawing

    private struct WireCopy { let mesh: MeshSnapshot; let revision: UInt64 }

    private func pushWireframe(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.4 : 0.7
        if wireInFlight {
            if force { wireRedrawRequested = true }
            return
        }
        guard force || now - lastWireAt >= interval else { return }
        lastWireAt = now
        wireInFlight = true
        let ticket = generation
        let enabled = options.wireframe
        let anchorLimit = ProcessInfo.processInfo.isLowPowerModeEnabled ? 12 : Self.wireAnchorLimit
        let copies: [WireCopy] = enabled ? anchorOrder.suffix(anchorLimit).compactMap { id in
            guard let mesh = meshes[id], let revision = revisions[id] else { return nil }
            return WireCopy(mesh: mesh, revision: revision)
        } : []
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.mainGeneration == ticket, self.mainRunning {
                self.drawWireframe(copies, enabled: enabled)
            }
            self.workQueue.async { [weak self] in
                guard let self = self, self.generation == ticket else { return }
                self.wireInFlight = false
                if self.wireRedrawRequested {
                    self.wireRedrawRequested = false
                    self.pushWireframe(force: true)
                }
            }
        }
    }

    @MainActor
    private func drawWireframe(_ copies: [WireCopy], enabled: Bool) {
        assert(Thread.isMainThread)
        guard enabled, let view = arView else { removeWireframe(); return }
        if wireRoot == nil {
            let root = AnchorEntity(world: SIMD3<Float>(repeating: 0))
            root.name = "QUESTSCAN.observed-wireframe"
            view.scene.addAnchor(root)
            wireRoot = root
        }
        guard let root = wireRoot else { return }
        let desired = Set(copies.map { $0.mesh.id })
        for id in Array(wireEntities.keys) where !desired.contains(id) {
            wireEntities.removeValue(forKey: id)?.removeFromParent()
            drawnRevisions.removeValue(forKey: id)
        }
        // Spread mesh-resource generation over passes. Prioritize missing/old draws
        // so frequent AR mesh updates cannot starve the remaining visible anchors.
        let dirty = copies.filter { drawnRevisions[$0.mesh.id] != $0.revision }.sorted {
            (drawnRevisions[$0.mesh.id] ?? 0) < (drawnRevisions[$1.mesh.id] ?? 0)
        }
        let batchLimit = ProcessInfo.processInfo.isLowPowerModeEnabled ? 2 : 4
        for copy in dirty.prefix(batchLimit) {
            do {
                let entity = try SceneRenderer.makeWireframe(vertices: copy.mesh.vertices,
                                                            indices: copy.mesh.indices,
                                                            color: UIColor(red: 0.18, green: 0.93, blue: 1, alpha: 0.85),
                                                            limit: Self.wireEdgeLimit)
                entity.name = "QUESTSCAN.wire.\(copy.mesh.id.uuidString)"
                wireEntities[copy.mesh.id]?.removeFromParent()
                root.addChild(entity)
                wireEntities[copy.mesh.id] = entity
                drawnRevisions[copy.mesh.id] = copy.revision
            } catch {
                if !wireErrorReported {
                    wireErrorReported = true
                    deliverError("ワイヤーフレーム表示に失敗しました。スキャンデータは取得できます", generation: mainGeneration)
                }
            }
        }
    }

    @MainActor
    private func removeWireframe() {
        wireRoot?.removeFromParent()
        wireRoot = nil
        wireEntities.removeAll()
        drawnRevisions.removeAll()
    }

    // MARK: Statistics and configuration

    private func refreshEstimate(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 2.5 : 1.2
        guard estimateDirty, force || now - lastEstimateAt >= interval else { return }
        estimate = CoverageEstimator.estimate(meshes: anchorOrder.compactMap { meshes[$0] }, photos: photos,
                                               sampleLimit: ProcessInfo.processInfo.isLowPowerModeEnabled ? 600 : 1_200)
        estimateDirty = false
        lastEstimateAt = now
    }

    private func currentStatistics() -> ScanStatistics {
        var result = ScanStatistics()
        result.triangleCount = meshes.values.reduce(0) { $0 + $1.indices.count / 3 }
        result.anchorCount = meshes.count
        result.photoCount = photos.count
        result.coverage = estimate.coverage
        result.surfaceArea = estimate.surfaceArea
        result.elapsed = elapsedTotal + (activeSince.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0)
        result.trackingMessage = trackingMessage
        result.trackingGood = trackingGood && running && !paused && !interrupted
        result.featureCount = featureCount
        result.retentionLimited = retentionLimited
        if retentionLimited { result.trackingMessage += "\n取得上限により一部を間引き・省略しています。広い部屋は分けて撮影してください。" }
        return result
    }

    private func publishStatistics(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastStatisticsAt >= 0.4 else { return }
        lastStatisticsAt = now
        refreshEstimate(force: force)
        let result = currentStatistics()
        let ticket = generation
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.mainGeneration == ticket else { return }
            self.onStatistics?(result)
        }
    }

    private func deliverError(_ text: String, generation ticket: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.mainGeneration == ticket else { return }
            self.onError?(text)
        }
    }

    private func finishActiveInterval() {
        if let started = activeSince { elapsedTotal += max(0, ProcessInfo.processInfo.systemUptime - started) }
        activeSince = nil
    }

    private func clearState(generation ticket: UInt64, options newOptions: ScanOptions) {
        generation = ticket
        options = newOptions
        running = false; paused = false; interrupted = false; sessionID = nil
        meshes.removeAll(); anchorOrder.removeAll(); revisions.removeAll(); nextRevision = 0
        photos.removeAll(); latestFrame = nil; lastPhotoTransform = nil
        lastPhotoTimestamp = -.greatestFiniteMagnitude; manualCapturePending = false
        elapsedTotal = 0; activeSince = nil; trackingGood = false; featureCount = 0
        retentionLimited = false
        trackingMessage = "カメラをゆっくり動かしてください"
        estimate = CoverageEstimator.Estimate(); estimateDirty = true
        lastEstimateAt = 0; lastStatisticsAt = 0; lastWireAt = 0; wireInFlight = false
        wireRedrawRequested = false
    }

    private func sanitized(_ proposed: ScanOptions) -> ScanOptions {
        proposed.sanitized()
    }

    private func sameOptions(_ a: ScanOptions, _ b: ScanOptions) -> Bool {
        a == b
    }

    @MainActor
    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.isLightEstimationEnabled = true
        config.environmentTexturing = .none
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled,
           let format = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter({ $0.framesPerSecond == 30 && max($0.imageResolution.width, $0.imageResolution.height) <= 1_920 })
            .min(by: { $0.imageResolution.width * $0.imageResolution.height < $1.imageResolution.width * $1.imageResolution.height }) {
            config.videoFormat = format
        }
        return config
    }
}
