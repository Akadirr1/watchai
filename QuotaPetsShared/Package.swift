// swift-tools-version: 6.0
import PackageDescription

// QuotaPetsShared is deliberately Foundation-only: no SwiftUI, no WatchConnectivity,
// no Security framework. That keeps it buildable and testable on Linux CI (and in the
// development container), which is where the provider-parsing traps documented in
// docs/provider-research.md are actually caught.
let package = Package(
    name: "QuotaPetsShared",
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
