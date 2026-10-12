// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexLimits",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexLimits", targets: ["CodexLimits"])],
    targets: [
        .target(name: "LimitsCore"),
        .executableTarget(name: "CodexLimits", dependencies: ["LimitsCore"]),
        .testTarget(name: "LimitsCoreTests", dependencies: ["LimitsCore"])
    ],
    swiftLanguageModes: [.v5]
)
