// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NotchIsland",
            path: "Sources/NotchIsland"
        )
    ],
    swiftLanguageVersions: [.v5]
)
