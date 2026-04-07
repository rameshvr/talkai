// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TalkAICore",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(name: "TalkAICore", targets: ["TalkAICore"])
    ],
    targets: [
        .target(name: "TalkAICore")
    ]
)
