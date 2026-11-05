import SwiftUI

@main
@MainActor
struct QUESTSCANApp: App {
    @StateObject private var model: ScannerModel

    init() {
        let initial = ScannerModel()
        // Explicit developer smoke-test flag; never bypasses camera permissions or
        // fabricates AR results. Normal user launches always show the home screen.
        if ProcessInfo.processInfo.arguments.contains("--questscan-demo") { initial.openDemo() }
        _model = StateObject(wrappedValue: initial)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .preferredColorScheme(.dark)
        }
    }
}
