import SwiftUI
import RealityKit
import UIKit

/// The parent handles permission before entering this view. No permission or network
/// requests occur here; makeUIView explicitly starts a fresh AR session.
@MainActor
struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var model: ScannerModel

    @MainActor
    final class Coordinator {
        let manager: ARManager
        init(manager: ARManager) { self.manager = manager }
    }

    func makeCoordinator() -> Coordinator { Coordinator(manager: model.arManager) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.backgroundColor = .black
        context.coordinator.manager.attach(view, options: model.options)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // An option edit updates capture/display policy, never restarts tracking.
        context.coordinator.manager.updateOptions(model.options)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        // stop() releases the camera but retains copied geometry/photos for snapshot().
        coordinator.manager.stop()
    }
}
