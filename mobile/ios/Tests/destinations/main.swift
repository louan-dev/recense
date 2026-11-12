// Regression guard: FEAT-04
// swiftc -O shared/destinations.swift mobile/ios/Tests/destinations/main.swift -o "$TMPDIR/destinations" && "$TMPDIR/destinations"
import Foundation
import CryptoKit

var bad = 0
func check(_ name: String, _ got: Bool) {
    if !got { bad += 1; print("FAIL \(name)") }
}

func tempDir() -> URL {
    let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
    let d = URL(fileURLWithPath: base).appendingPathComponent("rc-dest-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func withRoot(_ kind: DestinationKind, _ dir: URL, _ body: () throws -> Void) rethrows {
    setenv("RECENSE_\(kind.rawValue.uppercased())_DIR", dir.path, 1)
    defer { unsetenv("RECENSE_\(kind.rawValue.uppercased())_DIR") }
    try body()
}

// adopt() on an empty folder finds nothing
try withRoot(.screenshots, tempDir()) {
    let added = try Destinations.adopt(.screenshots)
    check("empty folder adopts nothing", added.isEmpty)
}

// a file dropped into screenshots/ with no manifest entry is adopted with the right sha256
try withRoot(.screenshots, tempDir()) {
    let root = Destinations.root(.screenshots)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let f = root.appendingPathComponent("shot.png")
    let bytes = Data("hello screenshot".utf8)
    try bytes.write(to: f)
    let expectedHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

    let added = try Destinations.adopt(.screenshots)
    check("one file adopted", added.count == 1)
    check("adopted entry has the right sha256", added.first?.sha256 == expectedHash)
    check("adopted entry is marked adopted", added.first?.via == "adopted")
}

// a file already in the manifest is not re-added or re-hashed
try withRoot(.screenshots, tempDir()) {
    let root = Destinations.root(.screenshots)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let f = root.appendingPathComponent("shot.png")
    try Data("v1".utf8).write(to: f)
    _ = try Destinations.adopt(.screenshots)

    let secondPass = try Destinations.adopt(.screenshots)
    check("already-known file is not re-adopted", secondPass.isEmpty)
    check("manifest still has exactly one entry", Destinations.manifest(.screenshots).count == 1)
}

// trash(_:) moves a file's bytes into Recense/trash/ and leaves a manifest entry with via: "trash"
try withRoot(.trash, tempDir()) {
    let srcDir = tempDir()
    let src = srcDir.appendingPathComponent("note.md")
    try Data("gone but recoverable".utf8).write(to: src)

    let entry = try Destinations.trash(src, source: "draftpad")
    check("original file no longer at its old path", !FileManager.default.fileExists(atPath: src.path))
    check("trashed file exists in Recense/trash", FileManager.default.fileExists(atPath: Destinations.root(.trash).appendingPathComponent(entry.name).path))
    check("trashed entry is marked trash", entry.via == "trash")
    check("trashed entry keeps its source", entry.source == "draftpad")
}

// two destinations never share one root for the same kind
try withRoot(.screenshots, tempDir()) {
    let shotsRoot = Destinations.root(.screenshots)
    withRoot(.trash, tempDir()) {
        let trashRoot = Destinations.root(.trash)
        check("screenshots and trash resolve to different folders", shotsRoot != trashRoot)
    }
}

if bad == 0 { print("OK") } else { print("\(bad) failed"); exit(1) }
