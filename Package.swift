// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MicBoost",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MicBoostCore", targets: ["MicBoostCore"]),
        .executable(name: "MicBoost", targets: ["MicBoostApp"]),
        .executable(name: "micboost-diag", targets: ["micboost-diag"]),
    ],
    targets: [
        .target(name: "MicBoostDSP", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "MicBoostCore", dependencies: ["MicBoostDSP"]),
        .executableTarget(name: "MicBoostApp", dependencies: ["MicBoostCore"], resources: [.process("Localization")]),
        .executableTarget(name: "micboost-diag", dependencies: ["MicBoostCore", "MicBoostDSP"]),
        .testTarget(name: "MicBoostDSPTests", dependencies: ["MicBoostDSP"]),
        .testTarget(name: "MicBoostCoreTests", dependencies: ["MicBoostCore"]),
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c17
)
