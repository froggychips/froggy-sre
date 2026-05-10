// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "froggy-sre",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "froggy-sre", targets: ["FroggySRE"]),
        .library(name: "FroggySRECore", targets: ["FroggySRECore"]),
    ],
    targets: [
        .target(
            name: "FroggySRECore",
            path: "Sources/FroggySRECore"
        ),
        .executableTarget(
            name: "FroggySRE",
            dependencies: ["FroggySRECore"],
            path: "Sources/FroggySRE"
        ),
        .testTarget(
            name: "FroggySRETests",
            dependencies: ["FroggySRECore"],
            path: "Tests/FroggySRETests"
        ),
    ]
)
