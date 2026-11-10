import Foundation
import XCTest
@testable import SSHKit

final class SSHKitTests: XCTestCase {
    func testDeviceKeyIsMadeOnceThenReused() throws {
        let store = MemoryKeyStore()
        let a = try DeviceKey.loadOrCreate(store: store, comment: "recense-iphone")
        let b = try DeviceKey.loadOrCreate(store: store, comment: "recense-iphone")
        XCTAssertEqual(a.publicLine, b.publicLine)
        XCTAssertTrue(a.publicLine.hasPrefix("ssh-ed25519 AAAA"))
        XCTAssertTrue(a.publicLine.hasSuffix(" recense-iphone"))
        XCTAssertEqual(store.load()?.count, 32)
    }

    func testFilePinsPersist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sshkit-pins-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        FilePinStore(url).setPin("ssh-ed25519 AAAAX", for: "mac.local:22")
        XCTAssertEqual(FilePinStore(url).pin(for: "mac.local:22"), "ssh-ed25519 AAAAX")
        XCTAssertNil(FilePinStore(url).pin(for: "other:22"))
    }

    func testNoRouteListsEveryAddressTried() async throws {
        let key = try DeviceKey.loadOrCreate(store: MemoryKeyStore(), comment: "t")
        do {
            _ = try await SSHConnection.connect(routes: [("127.0.0.1", 1), ("127.0.0.1", 2)], user: "nobody", key: key,
                                                pins: MemoryPinStore(), timeout: .seconds(2))
            XCTFail("connected to a closed port")
        } catch SSHError.noRoute(let tried) {
            XCTAssertEqual(tried.count, 2)
        }
    }

    // Live checks against this Mac's sshd, only when SSHKIT_LIVE_KEY names an authorized raw Ed25519 key file.
    var live: (key: DeviceKey, user: String)? {
        guard let p = ProcessInfo.processInfo.environment["SSHKIT_LIVE_KEY"],
              let k = try? DeviceKey.loadOrCreate(store: FileKeyStore(URL(fileURLWithPath: p)), comment: "live") else { return nil }
        return (k, NSUserName())
    }

    func testLiveExec() async throws {
        guard let l = live else { throw XCTSkip("SSHKIT_LIVE_KEY not set") }
        let c = try await SSHConnection.connect(host: "127.0.0.1", user: l.user, key: l.key, pins: MemoryPinStore())
        let r = try await c.exec("uname -m; echo done")
        await c.close()
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.output.contains("arm64") && r.output.contains("done"), r.output)
    }

    func testLiveShellEchoesThroughATerminal() async throws {
        guard let l = live else { throw XCTSkip("SSHKIT_LIVE_KEY not set") }
        let c = try await SSHConnection.connect(host: "127.0.0.1", user: l.user, key: l.key, pins: MemoryPinStore())
        let got = Received()
        let closed = expectation(description: "shell closed")
        let sh = try await c.shell(cols: 80, rows: 24, onData: { got.add($0) }, onClose: { closed.fulfill() })
        sh.send(Array("echo recense-$((40+2))\nexit\n".utf8))
        await fulfillment(of: [closed], timeout: 10)
        await c.close()
        XCTAssertTrue(got.text.contains("recense-42"), got.text)
    }

    func testLiveChangedHostKeyIsRefused() async throws {
        guard let l = live else { throw XCTSkip("SSHKIT_LIVE_KEY not set") }
        let pins = MemoryPinStore(["127.0.0.1:22": "ssh-ed25519 AAAAnot-the-real-key"])
        do {
            _ = try await SSHConnection.connect(host: "127.0.0.1", user: l.user, key: l.key, pins: pins)
            XCTFail("accepted a host key that does not match the pin")
        } catch SSHError.hostKeyChanged(let pinned, _) {
            XCTAssertEqual(pinned, "ssh-ed25519 AAAAnot-the-real-key")
        }
    }
}

final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    func add(_ b: [UInt8]) { lock.lock(); bytes += b; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}
