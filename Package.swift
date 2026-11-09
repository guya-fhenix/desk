// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FhenixDesk",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.3")],
    targets: [
        .target(name: "DeskCore", path: "Sources/DeskCore"),
        .executableTarget(
            name: "FhenixDesk",
            dependencies: ["DeskCore", "SwiftTerm"],
            path: "Sources/FhenixDesk"
        ),
        .testTarget(name: "DeskCoreTests", dependencies: ["DeskCore"], path: "Tests/DeskCoreTests"),
    ]
)
