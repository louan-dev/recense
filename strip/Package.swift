// swift-tools-version:5.9
// Recense builds as a Swift package so it can use SwiftTerm (the terminal emulator in the third panel).
// `zsh build.sh` drives this and wraps the result into Recense.app.
import PackageDescription

let package = Package(
    name: "recense",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.9.0"),
    ],
    targets: [
        .executableTarget(name: "recense", dependencies: ["SwiftTerm"], path: "Sources/recense"),
    ]
)
