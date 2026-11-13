// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "cuts",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cuts", targets: ["cuts"]),
        .library(name: "CutsKit", targets: ["CutsKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "CutsKit"),
        .executableTarget(
            name: "cuts",
            dependencies: [
                "CutsKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "CutsKitTests", dependencies: ["CutsKit"]),
    ],
    swiftLanguageModes: [.v5]
)
