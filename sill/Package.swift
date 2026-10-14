// swift-tools-version:5.9
// Sill builds as a Swift package so it can use SwiftTerm (the terminal emulator in the third panel).
// `zsh build.sh` drives this and wraps the result into Sill.app.
import PackageDescription

let package = Package(
    name: "sill",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.9.0"),
    ],
    targets: [
        .executableTarget(name: "sill", dependencies: ["SwiftTerm"], path: "Sources/sill"),
    ]
)
