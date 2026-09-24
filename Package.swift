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
        // No external SwiftPM dependencies allowed to keep compile times ultra-fast,
        // relying strictly on macOS native frameworks (AppKit, AVFoundation, ScreenCaptureKit, Speech, LocalAuthentication, Security, etc.)
    ],
    targets: [
        .executableTarget(
            name: "Jarvis",
            dependencies: [],
            path: "Sources/Jarvis",
            resources: [
                // If any resources are needed in the future
            ],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "JarvisTests",
            dependencies: ["Jarvis"],
            path: "Tests/JarvisTests"
        )
    ]
)