// swift-tools-version: 6.0
import PackageDescription

// QuotaPetsShared is deliberately Foundation-only: no SwiftUI, no WatchConnectivity,
// no Security framework. That keeps it buildable and testable on Linux CI (and in the
// development container), which is where the provider-parsing traps documented in
// docs/provider-research.md are actually caught.
let package = Package(
    name: "QuotaPetsShared",
    // The same floor as the watch targets. Without it the package builds at SwiftPM's
    // default watchOS deployment target, which need not get the arm64 slice that
    // Series 9 and later run on watchOS 26 — "Could not find module 'QuotaPetsShared'
    // for target 'arm64-apple-watchos'". Ignored on Linux.
    platforms: [.watchOS(.v11)],
    products: [
        .library(name: "QuotaPetsShared", targets: ["QuotaPetsShared"])
    ],
    targets: [
        .target(
            name: "QuotaPetsShared",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuotaPetsSharedTests",
            dependencies: ["QuotaPetsShared"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
