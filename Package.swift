// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Hush", targets: ["Hush"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.11.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Hush",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources",
            resources: [.process("Assets.xcassets")]
        ),
        .testTarget(
            name: "HushTests",
            dependencies: ["Hush"],
            path: "Tests"
        )
    ]
)
