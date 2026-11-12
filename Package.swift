// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Terminal",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TermCore", targets: ["TermCore"]),
        .library(name: "TermPTY", targets: ["TermPTY"]),
        .executable(name: "termprobe", targets: ["termprobe"]),
        .executable(name: "TermApp", targets: ["TermApp"]),
    ],
    targets: [
        .target(name: "TermCore"),
        .target(name: "CPTY"),
        .target(name: "TermPTY", dependencies: ["CPTY"]),
        .executableTarget(name: "termprobe", dependencies: ["TermCore", "TermPTY"]),
        .executableTarget(name: "TermApp", dependencies: ["TermCore", "TermPTY"]),
        .testTarget(name: "TermCoreTests", dependencies: ["TermCore"]),
    ]
)
