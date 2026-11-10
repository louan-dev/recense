// swift-tools-version:5.9
// SSHKit: SSH from Recense on the iPhone and iPad (owner, 2026-11-10). SwiftNIO SSH for the protocol, an Ed25519 key
// made on the device and kept in its Keychain, the server's host key pinned on first use. No company in the path:
// the connection goes straight to the owner's own Mac (LAN, then Tailscale, then a tunnel, as shared/sshhosts.swift says).
// Fetched once at setup from GitHub: swift-nio-ssh, swift-crypto (Apple, Apache 2.0). Test: `swift test` in this folder.
import PackageDescription

let package = Package(
    name: "SSHKit",
    platforms: [.macOS(.v14), .iOS("18.0")],
    products: [
        .library(name: "SSHKit", targets: ["SSHKit"]),
        .library(name: "SSHTerminal", targets: ["SSHTerminal"]),  // the iPhone/iPad terminal screen (SwiftTerm)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2"),  // MIT; the terminal emulator. Pinned: 1.13+ needs the Metal toolchain, 1.19+ runs a build plugin
    ],
    targets: [
        .target(name: "SSHKit", dependencies: [
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "SSHTerminal", dependencies: ["SSHKit", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "SSHKitTests", dependencies: ["SSHKit"]),
    ]
)
