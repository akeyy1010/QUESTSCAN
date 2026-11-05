import SwiftUI

@main
@MainActor
struct QUESTSCANApp: App {
    @StateObject private var model = ScannerModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .preferredColorScheme(.dark)
        }
    }
}
