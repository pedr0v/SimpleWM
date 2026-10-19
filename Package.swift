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
        // Menu-bar executable. Wires config, controller, and status item.
        .executableTarget(
            name: "SimpleWM",
            dependencies: ["LayoutEngine", "MacOSBridge"]
        ),
        .testTarget(name: "LayoutEngineTests", dependencies: ["LayoutEngine"]),
    ],
    swiftLanguageVersions: [.v5]
)
