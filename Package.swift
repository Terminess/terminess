// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Terminal",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TermCore", targets: ["TermCore"]),
        .library(name: "TermPTY", targets: ["TermPTY"]),
        .executable(name: "termprobe", targets: ["termprobe"]),
        .executable(name: "TermApp", targets: ["TermApp"]),
        .library(name: "TermHost", targets: ["TermHost"]),
        .library(name: "TermTranscript", targets: ["TermTranscript"]),
        .library(name: "TermHostServer", targets: ["TermHostServer"]),
        .executable(name: "terminessd", targets: ["terminessd"]),
    ],
    targets: [
        .target(name: "TermCore", swiftSettings: [
            .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release)),
        ]),
        .target(name: "CPTY", linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]),
        .target(name: "TermPTY", dependencies: ["CPTY"]),
        .executableTarget(name: "termprobe", dependencies: ["TermCore", "TermPTY"]),
        .executableTarget(name: "TermApp", dependencies: ["TermCore", "TermPTY", "TermHost", "TermTranscript"]),
        .target(name: "TermTranscript", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "TermHost", dependencies: ["TermTranscript"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "TermHostServer", dependencies: ["TermHost", "TermPTY"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "terminessd", dependencies: ["TermHost", "TermHostServer"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TermCoreTests", dependencies: ["TermCore"]),
        .testTarget(name: "TermTranscriptTests", dependencies: ["TermTranscript"], resources: [.copy("Fixtures")]),
        .testTarget(name: "TermHostTests", dependencies: ["TermHost"]),
        .testTarget(name: "TermHostServerTests", dependencies: ["TermHostServer", "TermHost"]),
    ]
)
