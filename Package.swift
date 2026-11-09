// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "liuying",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "liuying", targets: ["liuying"]),
        .executable(name: "liuyingctl", targets: ["liuyingctl"]),
        .library(name: "LiuYingCore", targets: ["LiuYingCore"]),
    ],
    targets: [
        .target(
            name: "LiuYingCore",
            path: "Sources/LiuYingCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "liuying",
            dependencies: ["LiuYingCore"],
            path: "Sources/liuying"
        ),
        .executableTarget(
            name: "liuyingctl",
            dependencies: ["LiuYingCore"],
            path: "Sources/liuyingctl"
        ),
        .testTarget(
            name: "LiuYingCoreTests",
            dependencies: ["LiuYingCore"],
            path: "Tests/LiuYingCoreTests"
        ),
    ]
)