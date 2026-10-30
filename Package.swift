// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StageChase",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StageChase", targets: ["StageChaseApp"]),
        .executable(name: "StageChaseChecks", targets: ["StageChaseChecks"])
    ],
    targets: [
        .target(name: "StageChaseCore"),
        .executableTarget(
            name: "StageChaseApp",
            dependencies: ["StageChaseCore"]
        ),
        .executableTarget(name: "StageChaseChecks", dependencies: ["StageChaseCore"])
    ],
    swiftLanguageModes: [.v5]
)
