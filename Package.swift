// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tack",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "Tack",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Tack",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
