// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacMeshProfiler",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacMeshProfiler",
            path: "Sources/MacMeshProfiler"
        )
    ]
)
