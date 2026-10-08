// swift-tools-version: 6.0
// swift-tensor:disabled
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [
        .macOS(.v14) // Targets macOS Sonoma (14.0) and above
    ],
    products: [
        .executable(name: "Jarvis", targets: ["Jarvis"])
    ],
    dependencies: [
        // Global hotkey registration
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.1"),
        // Keychain access for API key storage
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2"),
        // Local XCTest-compatible shim so swift test can compile without Xcode/XCTest.framework.
        .package(path: "/tmp/jarvis-xctest"),
    ],
    targets: [
        .executableTarget(
            name: "Jarvis",
            dependencies: [
                "HotKey",
                "KeychainAccess",
            ],
            path: "Sources/Jarvis",
            resources: [
                .copy("Brain/Workers/mlx_worker.py")
            ],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("ExistentialAny")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Scripts/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "JarvisTests",
            dependencies: ["Jarvis"],
            products: [.product(name: "JarvisXCTestLocal", package: "jarvis-xctest-local")],
            path: "Tests/JarvisTests"
        )
    ]
)