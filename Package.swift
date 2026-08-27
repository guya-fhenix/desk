// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FhenixDesk",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "DeskCore", path: "Sources/DeskCore"),
        .executableTarget(
            name: "FhenixDesk",
            dependencies: ["DeskCore"],
            path: "Sources/FhenixDesk"
        ),
        .testTarget(name: "DeskCoreTests", dependencies: ["DeskCore"], path: "Tests/DeskCoreTests"),
    ]
)
