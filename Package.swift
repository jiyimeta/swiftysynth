// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swiftysynth",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SwiftySynth", targets: ["SwiftySynth"])
    ],
    targets: [
        .target(name: "SwiftySynth"),
        .executableTarget(name: "SwiftySynthSpike", dependencies: ["SwiftySynth"]),
        .testTarget(
            name: "SwiftySynthTests",
            dependencies: ["SwiftySynth"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
