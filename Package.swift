// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Aloud",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Aloud",
            path: "Sources"
        )
    ]
)
