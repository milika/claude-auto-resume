// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeAutoResume",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeAutoResumeApp", targets: ["ClaudeAutoResumeApp"])
    ],
    dependencies: [
        // Sparkle for in-app "Check for Updates…" — the app also reads
        // the update feed from appcast.xml on the `main` branch.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
    ],
    targets: [
        .target(name: "ClaudeAutoResumeCore"),
        .target(name: "ClaudeAutoResumeAX", dependencies: ["ClaudeAutoResumeCore"]),
        .executableTarget(
            name: "ClaudeAutoResumeApp",
            dependencies: [
                "ClaudeAutoResumeCore",
                "ClaudeAutoResumeAX",
                .product(name: "Sparkle", package: "sparkle-project/Sparkle"),
            ]
        ),
        .testTarget(name: "ClaudeAutoResumeCoreTests", dependencies: ["ClaudeAutoResumeCore"]),
        .testTarget(name: "ClaudeAutoResumeAXTests", dependencies: ["ClaudeAutoResumeAX"])
    ]
)
