// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dedup",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(name: "DedupCore", path: "Sources/DedupCore"),
        .executableTarget(name: "DedupApp", dependencies: ["DedupCore"], path: "Sources/DedupApp"),
        .testTarget(name: "DedupCoreTests", dependencies: ["DedupCore"], path: "Tests/DedupCoreTests")
    ]
)
