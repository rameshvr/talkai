// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TalkAI",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "TalkAICore", targets: ["TalkAICore"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "TalkAICore",
            dependencies: [.product(name: "WhisperKit", package: "whisperkit")],
            path: "TalkAICore/Sources/TalkAICore"
        ),
        .executableTarget(
            name: "TalkAI",
            dependencies: ["TalkAICore"],
            path: "TalkAI",
            exclude: ["Info.plist", "TalkAI.entitlements"]
        ),
        .testTarget(
            name: "TalkAICoreTests",
            dependencies: ["TalkAICore", .product(name: "WhisperKit", package: "whisperkit")],
            path: "TalkAICore/Tests/TalkAICoreTests"
        )
    ]
)
