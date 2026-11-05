import SwiftUI
import RealityKit
import UIKit
import simd

/// A non-AR, meter-based scene viewer. Pan orbits, pinch zooms, two-finger pan moves the focus.
@MainActor
struct EditorViewContainer: UIViewRepresentable {
    @ObservedObject var model: ScannerModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(UIColor(red: 0.018, green: 0.027, blue: 0.055, alpha: 1))
        view.environment.lighting.intensityExponent = 1
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        context.coordinator.attach(view)
        context.coordinator.update()
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.model = model
        context.coordinator.scheduleUpdate()
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.pendingUpdate?.cancel()
        uiView.scene.anchors.removeAll()
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject {
        var model: ScannerModel
        weak var view: ARView?
        let root = AnchorEntity(world: .zero)
        let camera = PerspectiveCamera()
        private var sceneID: UUID?
        private var entities: [UUID: ModelEntity] = [:]
        private var adjustments: [UUID: ColorAdjustment] = [:]
        private var wireEntities: [UUID: ModelEntity] = [:]
        private var selectedWire: ModelEntity?
        private var lastSelection: UUID?
        private var lastWireframe = false
        private var lastRevision = -1
        var pendingUpdate: DispatchWorkItem?
        private var center = SIMD3<Float>(0, 1, 0)
        private var yaw: Float = 0.55
        private var pitch: Float = 0.32
        private var radius: Float = 5
        private var maximumRadius: Float = 20
        private var panOrigin = SIMD2<Float>.zero
        private var radiusOrigin: Float = 5
        private var focusOrigin = SIMD3<Float>.zero

        init(model: ScannerModel) { self.model = model }

        func attach(_ view: ARView) {
            self.view = view
            view.scene.addAnchor(root)
            camera.camera.fieldOfViewInDegrees = 58
            root.addChild(camera)
            let key = DirectionalLight()
            key.light.intensity = 2600
            key.light.color = .white
            key.look(at: .zero, from: SIMD3<Float>(3, 7, 5), relativeTo: nil)
            root.addChild(key)
            let fill = DirectionalLight()
            fill.light.intensity = 1400
            fill.light.color = UIColor(red: 0.65, green: 0.8, blue: 1, alpha: 1)
            fill.look(at: .zero, from: SIMD3<Float>(-4, 4, -3), relativeTo: nil)
            root.addChild(fill)

            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(orbited(_:)))
            pan.maximumNumberOfTouches = 1
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(zoomed(_:)))
            let translate = UIPanGestureRecognizer(target: self, action: #selector(translated(_:)))
            translate.minimumNumberOfTouches = 2
            translate.maximumNumberOfTouches = 2
            let reset = UITapGestureRecognizer(target: self, action: #selector(resetCamera(_:)))
            reset.numberOfTapsRequired = 2
            tap.require(toFail: reset)
            view.addGestureRecognizer(tap)
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(pinch)
            view.addGestureRecognizer(translate)
            view.addGestureRecognizer(reset)
            view.isAccessibilityElement = true
            view.accessibilityLabel = "3Dルーム。1本指で回転、ピンチで拡大、2本指で移動、ダブルタップで視点をリセットします。下の部分一覧からも選択できます。"
        }

        func scheduleUpdate() {
            // Coalesce slider updates, retaining the same camera and collision geometry.
            pendingUpdate?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.update() }
            pendingUpdate = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
        }

        func update() {
            guard let document = model.document else { return }
            let isNew = sceneID != document.id
            if isNew {
                entities.values.forEach { $0.removeFromParent() }
                wireEntities.values.forEach { $0.removeFromParent() }
                entities.removeAll(); adjustments.removeAll(); wireEntities.removeAll()
                selectedWire?.removeFromParent(); selectedWire = nil
                sceneID = document.id
                lastSelection = nil
                lastWireframe = false
                lastRevision = -1
                fitCamera(document)
            }
            if isNew || lastRevision != model.editRevision {
                for part in document.parts {
                    if entities[part.id] == nil {
                        do {
                            let entity = try SceneRenderer.makeEntity(for: part)
                            entity.name = part.id.uuidString
                            entity.generateCollisionShapes(recursive: false)
                            root.addChild(entity)
                            entities[part.id] = entity
                            adjustments[part.id] = part.adjustment
                        } catch {
                            model.errorMessage = "プレビュー生成に失敗しました: \(error.localizedDescription)"
                        }
                    } else if adjustments[part.id] != part.adjustment {
                        do {
                            // Reuse collision shapes and geometry; only the material changes.
                            let replacement = try SceneRenderer.makeEntity(for: part)
                            if let component = replacement.model { entities[part.id]?.model?.materials = component.materials }
                            adjustments[part.id] = part.adjustment
                        } catch { model.errorMessage = "色の反映に失敗しました: \(error.localizedDescription)" }
                    }
                }
                lastRevision = model.editRevision
            }
            if isNew || lastWireframe != model.showWireframe {
                wireEntities.values.forEach { $0.removeFromParent() }
                wireEntities.removeAll()
                if model.showWireframe {
                    let perPart = max(24, min(500, 8000 / max(document.parts.count, 1)))
                    for part in document.parts {
                        if let wire = try? SceneRenderer.makeWireframe(vertices: part.vertices, indices: part.indices, color: UIColor.cyan.withAlphaComponent(0.65), limit: perPart) {
                            root.addChild(wire)
                            wireEntities[part.id] = wire
                        }
                    }
                }
                lastWireframe = model.showWireframe
            }
            if isNew || lastSelection != model.selectedPartID {
                selectedWire?.removeFromParent()
                selectedWire = nil
                if let part = model.selectedPart,
                   let highlight = try? SceneRenderer.makeWireframe(vertices: part.vertices, indices: part.indices, color: UIColor(red: 0.8, green: 0.55, blue: 1, alpha: 1), limit: 2000) {
                    root.addChild(highlight)
                    selectedWire = highlight
                }
                lastSelection = model.selectedPartID
            }
        }

        private func fitCamera(_ document: SceneDocument) {
            var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for part in document.parts {
                for p in part.vertices {
                    low = simd_min(low, p); high = simd_max(high, p)
                }
            }
            guard low.x.isFinite, high.x.isFinite, low.x <= high.x else { return }
            center = (low + high) * 0.5
            let extent = max(1, simd_length(high - low))
            radius = extent * 0.9
            maximumRadius = max(8, extent * 4)
            yaw = 0.55; pitch = 0.32
            placeCamera()
        }

        private func placeCamera() {
            pitch = min(1.35, max(-1.25, pitch))
            radius = min(maximumRadius, max(0.15, radius))
            let offset = SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * radius
            camera.look(at: center, from: center + offset, relativeTo: nil)
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = view, !model.isBusy else { return }
            if let entity = view.entity(at: recognizer.location(in: view)), let id = UUID(uuidString: entity.name) {
                model.selectPart(id)
                UISelectionFeedbackGenerator().selectionChanged()
            } else { model.selectPart(nil) }
        }

        @objc private func orbited(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { panOrigin = SIMD2<Float>(yaw, pitch) }
            let translation = recognizer.translation(in: view)
            yaw = panOrigin.x - Float(translation.x) * 0.006
            pitch = panOrigin.y + Float(translation.y) * 0.006
            placeCamera()
        }

        @objc private func zoomed(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began { radiusOrigin = radius }
            radius = radiusOrigin / max(0.1, Float(recognizer.scale))
            placeCamera()
        }

        @objc private func translated(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { focusOrigin = center }
            let move = recognizer.translation(in: view)
            let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
            let up = SIMD3<Float>(0, 1, 0)
            center = focusOrigin - right * Float(move.x) * radius * 0.0015 + up * Float(move.y) * radius * 0.0015
            placeCamera()
        }

        @objc private func resetCamera(_ recognizer: UITapGestureRecognizer) {
            if let document = model.document { fitCamera(document) }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
