// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KaggleMenuBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KaggleMenuBar", targets: ["KaggleMenuBar"])
    ],
    targets: [
        .executableTarget(
            name: "KaggleMenuBar",
            path: "Sources/KaggleMenuBar"
        ),
        .testTarget(
            name: "KaggleMenuBarTests",
            dependencies: ["KaggleMenuBar"]
        )
    ],
    swiftLanguageModes: [.v5]
)
