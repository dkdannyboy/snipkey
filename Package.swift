// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SnipKey",
    platforms: [.macOS(.v13)],
    targets: [
        // Core logic: models, storage, TextExpander import, macro parsing.
        // Kept UI-free so it is unit-testable.
        .target(name: "SnipKeyKit"),
        // The menu bar application.
        .executableTarget(
            name: "SnipKey",
            dependencies: ["SnipKeyKit"]
        ),
        .testTarget(
            name: "SnipKeyKitTests",
            dependencies: ["SnipKeyKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
