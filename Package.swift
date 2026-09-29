// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Rainpane",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Rainpane",
            path: "Sources/Rainpane",
            swiftSettings: [.unsafeFlags(["-Ounchecked", "-wmo"], .when(configuration: .release))]
        )
    ],
    swiftLanguageModes: [.v5]
)
