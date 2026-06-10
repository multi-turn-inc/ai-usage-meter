// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIUsageMeter",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(
            name: "AIUsageMeter",
            targets: ["AIUsageMeter"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
    ],
    targets: [
        .executableTarget(
            name: "AIUsageMeter",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AIUsageMeter",
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
