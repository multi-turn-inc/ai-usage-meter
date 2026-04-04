// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIUsageMonitor",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(
            name: "AIUsageMonitor",
            targets: ["AIUsageMonitor"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
    ],
    targets: [
        .executableTarget(
            name: "AIUsageMonitor",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AIUsageMonitor",
            resources: [
                .process("Resources/Icons"),
                .copy("Resources/Scripts/updater.sh"),
            ],
            swiftSettings: [
                .define("ENABLE_SPARKLE"),
            ]
        )
    ]
)
