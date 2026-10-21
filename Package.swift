// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KernelWatch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KernelWatch", targets: ["KernelWatch"])
    ],
    targets: [
        .executableTarget(
            name: "KernelWatch",
            path: "Sources/KernelWatch"
        ),
        .testTarget(
            name: "KernelWatchTests",
            dependencies: ["KernelWatch"]
        )
    ],
    swiftLanguageModes: [.v5]
)
