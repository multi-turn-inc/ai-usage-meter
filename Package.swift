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
        ),
        .library(
            name: "AIUsageMeterCore",
            targets: ["AIUsageMeterCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
    ],
    targets: [
        .target(
            name: "AIUsageMeterCore",
            path: "Sources/AIUsageMeterCore"
        ),
        .executableTarget(
            name: "AIUsageMeter",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "AIUsageMeterCore",
            ],
            path: "Sources/AIUsageMeter",
            resources: [
                .process("Resources/Icons"),
                .copy("Resources/Scripts/updater.sh"),
            ],
            swiftSettings: [
                .define("ENABLE_SPARKLE"),
            ]
        ),
        .testTarget(
            name: "AIUsageMeterTests",
            dependencies: ["AIUsageMeterCore"],
            path: "Tests/AIUsageMeterTests"
        ),
    ]
)
