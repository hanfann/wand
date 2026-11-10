// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "wand",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "wand", targets: ["wand"]),
    ],
    targets: [
        // Objective-C engine: touches Apple's private CoreSimulator / SimulatorKit /
        // AccessibilityPlatformTranslation frameworks via dlopen + the Obj-C runtime.
        // Zero third-party dependencies — only Apple frameworks shipped with Xcode.
        .target(
            name: "WandEngine",
            path: "Sources/WandEngine",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Vision"),
            ]
        ),
        // Pure, simulator-free logic (the screen model) — unit-tested.
        .target(name: "WandKit"),
        .executableTarget(
            name: "wand",
            dependencies: ["WandEngine", "WandKit"],
            path: "Sources/wand"
        ),
        .testTarget(
            name: "WandKitTests",
            dependencies: ["WandKit"],
            path: "Tests/WandKitTests"
        ),
        .testTarget(
            name: "WandTests",
            dependencies: ["wand"],
            path: "Tests/WandTests"
        ),
    ]
)
