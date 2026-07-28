// swift-tools-version: 6.0
//
// FreeScan — open-source film scanner for the Epson Perfection V500 Photo.
//
// Primary build system is SwiftPM so the core logic, the diagnostic CLI, and the
// SwiftUI views all build and test with just `swift build` / `swift test` (i.e. with
// only the macOS Command Line Tools installed — no full Xcode required).
//
// The shippable, signed, sandboxed macOS .app is produced from `project.yml` via
// XcodeGen once full Xcode is installed (see README → Build).

import PackageDescription

let package = Package(
    name: "FreeScan",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FreeScanDiag", targets: ["FreeScanDiag"]),
        .executable(name: "FreeScanApp", targets: ["FreeScanApp"]),
        .library(name: "FreeScanCore", targets: ["FreeScanCore"]),
        .library(name: "FreeScanUI", targets: ["FreeScanUI"]),
    ],
    targets: [
        // Shared scanner-control + image-processing + export logic. No UI; fully unit-testable.
        .target(
            name: "FreeScanCore",
            path: "Sources/FreeScanCore"
        ),

        // SwiftUI views: prescan, crop overlay, histogram, curve editor, settings panel.
        .target(
            name: "FreeScanUI",
            dependencies: ["FreeScanCore"],
            path: "Sources/FreeScanUI"
        ),

        // Step 0 diagnostic: discover the V500, print functional units, run one overview scan.
        .executableTarget(
            name: "FreeScanDiag",
            dependencies: ["FreeScanCore"],
            path: "Sources/FreeScanDiag"
        ),

        // The SwiftUI macOS app. Runs via `swift run FreeScanApp` with no Xcode (for local/dev use
        // it is unsandboxed, so the USB scanner is reachable without entitlements). The signed,
        // sandboxed, distributable .app bundle is produced from project.yml via XcodeGen.
        .executableTarget(
            name: "FreeScanApp",
            dependencies: ["FreeScanUI"],
            path: "Sources/FreeScanApp",
            exclude: ["FreeScan.entitlements"]   // entitlements are for the XcodeGen app bundle
        ),

        // CLT-runnable self-checks (mirrors the XCTest suite, which needs full Xcode).
        .executableTarget(
            name: "FreeScanVerify",
            dependencies: ["FreeScanCore"],
            path: "Sources/FreeScanVerify"
        ),

        // Unit tests for the math + export round-trips. No scanner hardware required.
        .testTarget(
            name: "FreeScanCoreTests",
            dependencies: ["FreeScanCore"],
            path: "Tests/FreeScanCoreTests"
        ),
    ]
)
