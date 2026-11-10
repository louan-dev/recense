// Pieces: a file cut into pieces, each sealed with AES-256-GCM and named by the SHA-256 of its ciphertext, so any
// seed or peer can check and serve a piece without being able to read it. The item key travels only in a link's
// #fragment. Twin of library/src/client/pieces.js; the format is described there and in README.md.
//
// The one safety rule: GCM breaks if one key seals two different plaintexts under one nonce (nonce = piece index).
// - The item key comes from the file's hash, so an edited file gets a new key.
// - servePiece re-seals a piece only to hand out exactly the ciphertext its manifest names; if the file changed on
//   disk it throws .fileChanged instead, so the old key never seals a second plaintext.
// - The manifest can differ for the same file (name, time), so it gets its own random nonce, stored in front.
import CryptoKit
import Foundation

public enum PieceError: Error, Equatable {
    case hashMismatch(Int)     // a piece's ciphertext isn't the one its manifest names (tampered or wrong)
    case fileChanged(Int)      // the plain file on disk no longer makes the piece its manifest names
    case idMismatch            // a manifest blob isn't the one its item id names
    case badLink
    case badManifest
}

public enum Pieces {
    static let label = "recense.pieces.v1."
    static let KiB = 1024, GiB: Int64 = 1 << 30

    // MARK: sizes
    public static func pieceSize(_ size: Int64) -> Int { size < GiB ? 256 * KiB : 1024 * KiB }
    public static func pieceCount(_ size: Int64) -> Int { Int((size + Int64(pieceSize(size)) - 1) / Int64(pieceSize(size))) }

    // MARK: keys
    public struct Keys {
        public let item: Data
        public let manifest: SymmetricKey
        public let piece: SymmetricKey
        public init(item: Data) {
            self.item = item
            manifest = Pieces.hkdf(item, "manifest")
            piece = Pieces.hkdf(item, "piece")
        }
    }
    public static func itemKey(groupSecret: Data, fileHash: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data((label + "item").utf8) + fileHash, using: SymmetricKey(data: groupSecret)))
    }
    static func hkdf(_ ikm: Data, _ what: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: Data(), info: Data((label + what).utf8), outputByteCount: 32)
    }

    // MARK: one piece
    static func nonce(_ i: Int) -> AES.GCM.Nonce {
        var n = Data(count: 4)
        withUnsafeBytes(of: UInt64(i).bigEndian) { n.append(contentsOf: $0) }
        return try! AES.GCM.Nonce(data: n)
    }
    /// ciphertext ‖ 16-byte tag, the same bytes WebCrypto makes.
    public static func sealPiece(_ key: SymmetricKey, index: Int, plain: Data) -> Data {
        let box = try! AES.GCM.seal(plain, using: key, nonce: nonce(index))
        return box.ciphertext + box.tag
    }
    /// Checks the name first (any seed could have sent it), then GCM.
    public static func openPiece(_ key: SymmetricKey, index: Int, cipher: Data, expectedHash: String) throws -> Data {
        guard hex(SHA256.hash(data: cipher)) == expectedHash else { throw PieceError.hashMismatch(index) }
        return try openGCM(key, nonce(index), cipher)
    }
    static func openGCM(_ key: SymmetricKey, _ n: AES.GCM.Nonce, _ cipher: Data) throws -> Data {
        guard cipher.count >= 16 else { throw PieceError.badManifest }
        let box = try AES.GCM.SealedBox(nonce: n, ciphertext: cipher.dropLast(16), tag: cipher.suffix(16))
        return try AES.GCM.open(box, using: key)
    }

    // MARK: manifest
    public struct Manifest: Codable, Equatable {
        public var created: Int64, file: String, name: String, origin: String
        public var piece: Int, pieces: [String], size: Int64, type: String, v: Int
        /// Canonical JSON: keys sorted, strings escape only " \ and U+0000–U+001F (\u00xx), as the JS twin writes.
        public var canonical: String {
            "{\"created\":\(created),\"file\":\(q(file)),\"name\":\(q(name)),\"origin\":\(q(origin)),\"piece\":\(piece),"
                + "\"pieces\":[\(pieces.map(q).joined(separator: ","))],\"size\":\(size),\"type\":\(q(type)),\"v\":\(v)}"
        }
    }
    static func q(_ s: String) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case _ where u.value < 0x20: o += String(format: "\\u%04x", u.value)
            default: o.unicodeScalars.append(u)
            }
        }
        return o + "\""
    }

    public struct Item {
        public let manifest: Manifest
        public let blob: Data
        public let id: String
        public let keys: Keys
    }

    /// Reads `count` bytes at `offset` of the plain file.
    public typealias Reader = (_ offset: Int64, _ count: Int) throws -> Data

    /// Seals a file in two streaming passes (hash, then pieces), never holding more than one piece in memory.
    /// manifestNonce only for test vectors; otherwise random.
    public static func make(size: Int64, read: Reader, groupSecret: Data, name: String, type: String, origin: String,
                            created: Int64, manifestNonce: Data? = nil) throws -> Item {
        var h = SHA256()
        var off: Int64 = 0
        while off < size {
            let chunk = try read(off, Int(min(Int64(1 << 20), size - off)))
            h.update(data: chunk)
            off += Int64(chunk.count)
        }
        let fileHash = Data(h.finalize())
        let keys = Keys(item: itemKey(groupSecret: groupSecret, fileHash: fileHash))
        let ps = pieceSize(size)
        var hashes: [String] = []
        for i in 0..<pieceCount(size) {
            let start = Int64(i) * Int64(ps)
            let plain = try read(start, Int(min(Int64(ps), size - start)))
            hashes.append(hex(SHA256.hash(data: sealPiece(keys.piece, index: i, plain: plain))))
        }
        let m = Manifest(created: created, file: hex(fileHash), name: name, origin: origin, piece: ps, pieces: hashes,
                         size: size, type: type, v: 1)
        let n = try AES.GCM.Nonce(data: manifestNonce ?? Data(AES.GCM.Nonce()))
        let box = try AES.GCM.seal(Data(m.canonical.utf8), using: keys.manifest, nonce: n)
        let blob = Data(n) + box.ciphertext + box.tag
        return Item(manifest: m, blob: blob, id: hex(SHA256.hash(data: blob)), keys: keys)
    }
    public static func make(file: URL, groupSecret: Data, name: String, type: String, origin: String, created: Int64) throws -> Item {
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        let size = Int64(try fh.seekToEnd())
        return try make(size: size, read: reader(fh), groupSecret: groupSecret, name: name, type: type, origin: origin, created: created)
    }
    public static func reader(_ fh: FileHandle) -> Reader {
        { off, count in try fh.seek(toOffset: UInt64(off)); return try fh.read(upToCount: count) ?? Data() }
    }
    public static func reader(_ d: Data) -> Reader {
        { off, count in d.subdata(in: Int(off)..<Int(off) + count) }
    }

    public static func openManifest(itemKey: Data, blob: Data, expectedId: String? = nil) throws -> (Manifest, Keys) {
        if let id = expectedId, hex(SHA256.hash(data: blob)) != id { throw PieceError.idMismatch }
        guard blob.count >= 28 else { throw PieceError.badManifest }
        let keys = Keys(item: itemKey)
        let plain = try openGCM(keys.manifest, try AES.GCM.Nonce(data: blob.prefix(12)), blob.dropFirst(12))
        guard let m = try? JSONDecoder().decode(Manifest.self, from: plain) else { throw PieceError.badManifest }
        return (m, keys)
    }

    /// The only way a device hands out a piece of its own file: re-seal, and refuse unless it is the manifest's piece.
    public static func servePiece(read: Reader, manifest m: Manifest, keys: Keys, index i: Int) throws -> Data {
        let start = Int64(i) * Int64(m.piece)
        let plain = try read(start, Int(min(Int64(m.piece), m.size - start)))
        let c = sealPiece(keys.piece, index: i, plain: plain)
        guard hex(SHA256.hash(data: c)) == m.pieces[i] else { throw PieceError.fileChanged(i) }
        return c
    }

    // MARK: links (the key only ever after "#")
    public static func link(host: String, id: String, itemKey: Data) -> String { "https://\(host)/x/\(id)#\(b64url(itemKey))" }
    public static func parseLink(_ s: String) throws -> (host: String, id: String, itemKey: Data) {
        let re = #/^https:\/\/([^\/]+)\/x\/([0-9a-f]{64})#([A-Za-z0-9_-]{43})$/#
        guard let m = s.wholeMatch(of: re), let key = unb64url(String(m.3)), key.count == 32 else { throw PieceError.badLink }
        return (String(m.1), String(m.2), key)
    }

    // MARK: download with resume
    /// `have` is the set of verified pieces (the caller keeps it, with the pieces, on disk), so a drop costs nothing.
    public struct Download {
        public let manifest: Manifest
        public let keys: Keys
        public private(set) var have: Set<Int>
        public init(manifest: Manifest, keys: Keys, have: Set<Int> = []) { self.manifest = manifest; self.keys = keys; self.have = have }
        public var missing: [Int] { manifest.pieces.indices.filter { !have.contains($0) } }
        public var complete: Bool { have.count == manifest.pieces.count }
        public mutating func accept(_ i: Int, cipher: Data) throws -> Data {
            let p = try Pieces.openPiece(keys.piece, index: i, cipher: cipher, expectedHash: manifest.pieces[i])
            have.insert(i)
            return p
        }
    }

    // MARK: encodings
    public static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
    public static func unhex(_ s: String) -> Data {
        var d = Data(), i = s.startIndex
        while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex), let b = UInt8(s[i..<j], radix: 16) { d.append(b); i = j }
        return d
    }
    public static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func unb64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
