// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPulse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPulse", targets: ["MacPulse"]),
        .library(name: "MacPulseCore", targets: ["MacPulseCore"]),
        .library(name: "MacPulseUI", targets: ["MacPulseUI"]),
    ],
    targets: [
        // Data models, provider protocols and the live system-monitoring services.
        .target(name: "MacPulseCore"),
        // SwiftUI dashboard, charts and About screen.
        .target(name: "MacPulseUI", dependencies: ["MacPulseCore"]),
        // App entry point and window/menu wiring.
        .executableTarget(name: "MacPulse", dependencies: ["MacPulseCore", "MacPulseUI"]),
        // Automated tests.
        .testTarget(name: "MacPulseCoreTests", dependencies: ["MacPulseCore"]),
        .testTarget(name: "MacPulseUITests", dependencies: ["MacPulseCore", "MacPulseUI"]),
    ],
    swiftLanguageModes: [.v5]
)
