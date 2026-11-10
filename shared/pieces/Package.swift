// swift-tools-version:5.9
// Pieces: the share lane's one byte layer (X1), shared by Recense Mac (strip/) and Recense mobile (mobile/), and the
// transport for places H3. Foundation and CryptoKit only. Twin of library/src/client/pieces.js; both must match
// vectors/v1.json byte for byte.
// Test: `swift test` in this folder (Xcode's toolchain: the Command Line Tools have no XCTest).
import PackageDescription

let package = Package(
    name: "Pieces",
    platforms: [.macOS(.v14), .iOS("18.0")],
    products: [.library(name: "Pieces", targets: ["Pieces"])],
    targets: [
        .target(name: "Pieces"),
        .testTarget(name: "PiecesTests", dependencies: ["Pieces"]),
    ]
)
