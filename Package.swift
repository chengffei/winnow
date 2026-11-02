// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Winnow",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(name: "WinnowCore", path: "Sources/WinnowCore"),
        .executableTarget(name: "WinnowApp", dependencies: ["WinnowCore"], path: "Sources/WinnowApp"),
        .testTarget(name: "WinnowCoreTests", dependencies: ["WinnowCore"], path: "Tests/WinnowCoreTests")
    ]
)
