// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tack",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tack",
            path: "Sources/Tack"
        )
    ]
)
