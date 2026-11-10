import CryptoKit
import Foundation
import XCTest
@testable import Pieces

// The vectors were made once by the JS twin (library/src/client/pieces.js); Swift must reproduce every byte.
struct Vectors: Decodable {
    struct Case: Decodable {
        let label: String, size: Int, name: String, type: String, origin: String, created: Int64
        let manifestNonce: String, fileHash: String, itemKey: String, manifestKey: String, pieceKey: String
        let pieceSize: Int, pieces: [String], manifest: String, blob: String, id: String, link: String
    }
    struct Tamper: Decodable { let `case`: Int, piece: Int, byte: Int, xor: UInt8 }
    struct Edited: Decodable { let `case`: Int, byte: Int, xor: UInt8, itemKey: String }
    let groupSecret: String, tamper: Tamper, edited: Edited, cases: [Case]
    static let load: Vectors = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../vectors/v1.json")
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()
}
func plaintext(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }
func keyHex(_ k: SymmetricKey) -> String { k.withUnsafeBytes { Pieces.hex($0) } }

final class PiecesTests: XCTestCase {
    let V = Vectors.load
    var group: Data { Pieces.unhex(V.groupSecret) }

    func make(_ c: Vectors.Case, _ d: Data) throws -> Pieces.Item {
        try Pieces.make(size: Int64(d.count), read: Pieces.reader(d), groupSecret: group, name: c.name, type: c.type,
                        origin: c.origin, created: c.created, manifestNonce: Pieces.unhex(c.manifestNonce))
    }

    func testVectorsMatchTheJSTwinByteForByte() throws {
        XCTAssertEqual(V.cases.count, 2)
        for c in V.cases {
            let it = try make(c, plaintext(c.size))
            XCTAssertEqual(it.manifest.file, c.fileHash, c.label)
            XCTAssertEqual(Pieces.hex(it.keys.item), c.itemKey, c.label)
            XCTAssertEqual(keyHex(it.keys.manifest), c.manifestKey, c.label)
            XCTAssertEqual(keyHex(it.keys.piece), c.pieceKey, c.label)
            XCTAssertEqual(it.manifest.piece, c.pieceSize, c.label)
            XCTAssertEqual(it.manifest.pieces, c.pieces, c.label)
            XCTAssertEqual(it.manifest.canonical, c.manifest, c.label)
            XCTAssertEqual(Pieces.hex(it.blob), c.blob, c.label)
            XCTAssertEqual(it.id, c.id, c.label)
            XCTAssertEqual(Pieces.link(host: "seed.example", id: it.id, itemKey: it.keys.item), c.link, c.label)
        }
    }

    func testManifestOpensFromTheLinkAlone() throws {
        for c in V.cases {
            let l = try Pieces.parseLink(c.link)
            XCTAssertEqual(l.host, "seed.example")
            let (m, keys) = try Pieces.openManifest(itemKey: l.itemKey, blob: Pieces.unhex(c.blob), expectedId: l.id)
            XCTAssertEqual(m.name, c.name)
            XCTAssertEqual(m.pieces, c.pieces)
            XCTAssertEqual(keyHex(keys.piece), c.pieceKey)
        }
        XCTAssertThrowsError(try Pieces.openManifest(itemKey: Pieces.unhex(V.cases[0].itemKey), blob: Pieces.unhex(V.cases[0].blob),
                                                    expectedId: V.cases[1].id)) { XCTAssertEqual($0 as? PieceError, .idMismatch) }
    }

    func testTheKeyIsNeverBeforeTheFragment() throws {
        let c = V.cases[0]
        let beforeHash = c.link.components(separatedBy: "#")[0]
        XCTAssertFalse(beforeHash.contains(Pieces.b64url(Pieces.unhex(c.itemKey))))
        XCTAssertThrowsError(try Pieces.parseLink(beforeHash))
        XCTAssertThrowsError(try Pieces.parseLink(beforeHash + "#short"))
    }

    func testAFlippedByteIsCaughtTwice() throws {
        let t = V.tamper, c = V.cases[t.case]
        let it = try make(c, plaintext(c.size))
        var bad = try Pieces.servePiece(read: Pieces.reader(plaintext(c.size)), manifest: it.manifest, keys: it.keys, index: t.piece)
        bad[t.byte] ^= t.xor
        // 1: its name no longer matches
        XCTAssertThrowsError(try Pieces.openPiece(it.keys.piece, index: t.piece, cipher: bad, expectedHash: c.pieces[t.piece])) {
            XCTAssertEqual($0 as? PieceError, .hashMismatch(t.piece))
        }
        // 2: even a seed that renamed it to match can't get it past GCM
        let renamed = Pieces.hex(SHA256.hash(data: bad))
        XCTAssertThrowsError(try Pieces.openPiece(it.keys.piece, index: t.piece, cipher: bad, expectedHash: renamed))
    }

    // Coordinator's invariant: a key never seals two different plaintexts.
    func testAnEditedFileGetsANewKey() throws {
        let e = V.edited, c = V.cases[e.case]
        var d = plaintext(c.size)
        d[e.byte] ^= e.xor
        let it = try make(c, d)
        XCTAssertEqual(Pieces.hex(it.keys.item), e.itemKey)
        XCTAssertNotEqual(e.itemKey, c.itemKey)
    }

    func testAChangedFileIsRefusedUnderItsOldKey() throws {
        let c = V.cases[0]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pieces-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try plaintext(c.size).write(to: url)
        let it = try Pieces.make(file: url, groupSecret: group, name: c.name, type: c.type, origin: c.origin, created: c.created)
        XCTAssertEqual(it.manifest.pieces, c.pieces, "streaming from disk makes the same pieces as memory")
        // edit one byte in piece 1, on disk, in place
        let fh = try FileHandle(forUpdating: url)
        try fh.seek(toOffset: UInt64(c.pieceSize + 5))
        try fh.write(contentsOf: Data([0xFF]))
        let read = Pieces.reader(fh)
        XCTAssertThrowsError(try Pieces.servePiece(read: read, manifest: it.manifest, keys: it.keys, index: 1)) {
            XCTAssertEqual($0 as? PieceError, .fileChanged(1))
        }
        // untouched pieces still serve the exact bytes their manifest names
        for i in [0, 2] {
            let p = try Pieces.servePiece(read: read, manifest: it.manifest, keys: it.keys, index: i)
            XCTAssertEqual(Pieces.hex(SHA256.hash(data: p)), c.pieces[i])
        }
        try fh.close()
    }

    func testResumeAfterADropFetchesOnlyWhatIsMissing() throws {
        let c = V.cases[0], file = plaintext(c.size)
        let it = try make(c, file)
        let serve = { (i: Int) in try Pieces.servePiece(read: Pieces.reader(file), manifest: it.manifest, keys: it.keys, index: i) }
        var dl = Pieces.Download(manifest: it.manifest, keys: Keys(item: it.keys.item))
        var got: [Int: Data] = [:]
        got[0] = try dl.accept(0, cipher: serve(0))
        let kept = dl.have                       // the connection drops here; only `have` and the pieces survive
        var again = Pieces.Download(manifest: it.manifest, keys: Keys(item: it.keys.item), have: kept)
        XCTAssertEqual(again.missing, [1, 2])
        var fetched: [Int] = []
        for i in again.missing { fetched.append(i); got[i] = try again.accept(i, cipher: serve(i)) }
        XCTAssertEqual(fetched, [1, 2])
        XCTAssertTrue(again.complete)
        XCTAssertEqual((0..<3).reduce(Data()) { $0 + got[$1]! }, file)
    }

    func testPieceSizes() {
        XCTAssertEqual(Pieces.pieceSize(0), 262_144)
        XCTAssertEqual(Pieces.pieceCount(0), 0)
        XCTAssertEqual(Pieces.pieceCount(262_144), 1)
        XCTAssertEqual(Pieces.pieceCount(262_145), 2)
        XCTAssertEqual(Pieces.pieceSize(1 << 30), 1_048_576)
    }
}
typealias Keys = Pieces.Keys
