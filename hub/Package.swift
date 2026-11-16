// swift-tools-version: 5.9
// Derived from Spec: FEAT-18. The Recense hub: one small headless program (no AppKit), so it can run on a Mac mini
// with nobody logged in. It compiles shared/notesync.swift (symlinked) so the hub and the apps merge notes the same way.
import PackageDescription

let package = Package(
    name: "recense-hub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "recense-hub", path: "Sources/recense-hub"),
    ]
)
