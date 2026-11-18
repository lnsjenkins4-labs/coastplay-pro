// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RGPCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RGPCore", targets: ["RGPCore"]),
        .library(name: "RGPMock", targets: ["RGPMock"]),
        .library(name: "RGPPS5", targets: ["RGPPS5"]),
        .executable(name: "rgp-probe", targets: ["rgp-probe"]),
        .library(name: "RGPMirror", targets: ["RGPMirror"]),
        .executable(name: "rgp-mirror-host", targets: ["rgp-mirror-host"]),
    ],
    targets: [
        // Platform-neutral contracts, session state machine, input model. No UI, no network.
        .target(name: "RGPCore"),
        // Demo/mock console. Kept in its own module so real code never links simulated behaviour by accident.
        .target(name: "RGPMock", dependencies: ["RGPCore"]),
        // Real PS5 code. Today: LAN discovery only. Streaming transport is NOT implemented.
        .target(name: "RGPPS5", dependencies: ["RGPCore"]),
        // Desktop diagnostic harness: looks for PS5 consoles on the local network.
        .executableTarget(name: "rgp-probe", dependencies: ["RGPPS5"]),
        // Computer mirroring: our own small protocol (TLS with a pre-shared pairing code) and the
        // phone-side client. No third-party code.
        .target(name: "RGPMirror", dependencies: ["RGPCore"]),
        // The Mac app that captures the screen and sound and accepts control. macOS only.
        .executableTarget(name: "rgp-mirror-host", dependencies: ["RGPMirror"]),
        .testTarget(name: "RGPCoreTests", dependencies: ["RGPCore", "RGPMock", "RGPPS5", "RGPMirror"]),
    ]
)
