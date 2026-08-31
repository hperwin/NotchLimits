// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchLimits",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "NotchLimits",
            path: "Sources/NotchLimits"
        )
    ]
)
