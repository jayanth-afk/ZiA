// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // Global hotkey registration
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.1"),
        // Keychain access for API key storage
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "Jarvis",
            dependencies: [
                "HotKey",
                "KeychainAccess",
            ],
            path: "Sources/Jarvis"
        ),
        .testTarget(
            name: "JarvisTests",
            dependencies: ["Jarvis"],
            path: "Tests/JarvisTests"
        ),
    ]
)
