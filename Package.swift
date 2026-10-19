// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SimpleWM",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LayoutEngine", targets: ["LayoutEngine"]),
        .library(name: "MacOSBridge", targets: ["MacOSBridge"]),
        .executable(name: "SimpleWM", targets: ["SimpleWM"]),
    ],
    dependencies: [
        // Auto-update. The version is exact so that local and CI builds match.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Pure tiling logic. Foundation only. No AppKit, no CoreGraphics.
        .target(name: "LayoutEngine"),
        // macOS system bridge: SkyLight (dlsym), Accessibility, Carbon hotkeys.
        .target(
            name: "MacOSBridge",
            dependencies: ["LayoutEngine"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        // Menu-bar executable. Wires config, controller, status item, and updater.
        .executableTarget(
            name: "SimpleWM",
            dependencies: [
                "LayoutEngine",
                "MacOSBridge",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(name: "LayoutEngineTests", dependencies: ["LayoutEngine"]),
    ],
    swiftLanguageVersions: [.v5]
)
