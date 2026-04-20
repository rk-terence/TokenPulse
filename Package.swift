// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenPulse",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "TokenPulse", targets: ["TokenPulse"]),
    ],
    targets: [
        .executableTarget(
            name: "TokenPulse",
            path: "TokenPulse",
            exclude: [
                "Assets.xcassets",
                "Info.plist",
                "TokenPulse.entitlements",
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
