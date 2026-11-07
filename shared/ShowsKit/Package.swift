// swift-tools-version:5.9
// ShowsKit: the Podcasts-style skin's model, rules and catalog store, shared by Recense Mac (strip/) and Recense
// mobile (mobile/). Platform-neutral: Foundation and CryptoKit only here; SwiftUI views join in B2.
// Test: `swift test` in this folder.
import PackageDescription

let package = Package(
    name: "ShowsKit",
    platforms: [.macOS(.v14), .iOS("18.0")],
    products: [.library(name: "ShowsKit", targets: ["ShowsKit"])],
    targets: [
        .target(name: "ShowsKit"),
        .testTarget(name: "ShowsKitTests", dependencies: ["ShowsKit"]),
    ]
)
