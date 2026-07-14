// swift-tools-version:5.9
// SwiftPM manifest — used ONLY for `swift test`. The shipping .app is
// still built by build.sh (ad-hoc swiftc + codesign), which is what
// codesigns and bundles resources; SwiftPM here is scaffolding for the
// XCTest suite that covers the app's pure-logic pieces (Razer protocol
// framing/CRC, settings encode/decode migrations, low-battery
// hysteresis math, scroll pixel accounting, …).
//
// Both build systems point at the same Sources/ tree, so bugs caught in
// tests reflect the actual shipping code.
import PackageDescription

let package = Package(
    name: "BSKV3XHS",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BSKV3XHS",
            path: "Sources"
        ),
        .testTarget(
            name: "BSKV3XHSTests",
            dependencies: ["BSKV3XHS"],
            path: "Tests"
        ),
    ]
)
