// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "yobirin",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "yobirin",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "yobirinTests",
            dependencies: [
                "yobirin"
            ]
        ),
    ]
)
