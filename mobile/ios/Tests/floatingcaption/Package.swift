// swift-tools-version:5.9
// The floating window's picture, rendered on the Mac (FloatingCaption.swift is a link to the app's file).
// swift run --package-path mobile/ios/Tests/floatingcaption --scratch-path "$TMPDIR/floatingcaption" (ALL OK)
import PackageDescription

let package = Package(
    name: "floatingcaption",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../../shared/ShowsKit")],
    targets: [.executableTarget(name: "floatingcaption", dependencies: ["ShowsKit"])]
)
