// swift-tools-version: 5.7
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "QUESTSCAN",
    defaultLocalization: "ja",
    platforms: [.iOS("16.0")],
    products: [
        .iOSApplication(
            name: "QUESTSCAN",
            targets: ["AppModule"],
            bundleIdentifier: "com.questscan.roomstudio",
            displayVersion: "1.0.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .camera),
            accentColor: .presetColor(.cyan),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [
                .portrait, .landscapeLeft, .landscapeRight,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .camera(purposeString: "周囲の空間を3Dスキャンし、撮影した画像をモデルの表面に貼り付けるためにカメラを使用します。画像は端末内で処理されます。")
            ],
            appCategory: .graphicsDesign,
            additionalInfoPlistContentFilePath: "AppInfo.plist"
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: ".",
            exclude: ["AppInfo.plist"],
            resources: [.process("Resources")],
            swiftSettings: [.define("QUESTSCAN")]
        )
    ]
)
