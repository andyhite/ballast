// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ballast",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ballast", targets: ["ballast"]),
    ],
    targets: [
        // Pure, I/O-free model: config, rules, weights, layouts, engine state machine.
        .target(name: "BallastCore"),
        // macOS glue: Accessibility, SkyLight (read-only), AppKit menu bar, hotkeys.
        .target(
            name: "BallastApp",
            dependencies: ["BallastCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(name: "ballast", dependencies: ["BallastApp"]),
        .testTarget(name: "BallastCoreTests", dependencies: ["BallastCore"]),
    ],
    swiftLanguageModes: [.v5]
)
