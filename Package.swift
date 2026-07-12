// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-meltysynth",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "MeltySynth", targets: ["MeltySynth"])
    ],
    targets: [
        .target(name: "MeltySynth"),
        .executableTarget(name: "MeltySynthSpike", dependencies: ["MeltySynth"]),
        .testTarget(
            name: "MeltySynthTests",
            dependencies: ["MeltySynth"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
