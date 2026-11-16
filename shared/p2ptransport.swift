// Derived from Spec: FEAT-02 · finds the other device and opens an encrypted session (Bluetooth or peer-to-peer
// Wi-Fi, no router, no internet — the OS picks the radio). One shared module: FEAT-09's pairing and carry ops ride
// its typed messages; FEAT-03's Share and the future messenger ride its file transfers.
import Foundation
import MultipeerConnectivity
#if os(iOS)
import UIKit
#endif

@MainActor final class P2PTransport: NSObject {
    static let shared = P2PTransport()
    static let serviceType = "recense-p2p"   // lowercase, digits, hyphens; 1-15 chars (Apple's limit)

    let myID = MCPeerID(displayName: P2PTransport.deviceName())
    private(set) lazy var session: MCSession = {
        let s = MCSession(peer: myID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        return s
    }()
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    /// FEAT-09 P1's invariant: a peer not in `peers.json` gets no session without the owner's own tap.
    var isPaired: (MCPeerID) -> Bool = { _ in false }
    /// Asks the owner before accepting an unpaired peer. Nil (the default) refuses silently.
    var confirmUnpaired: ((MCPeerID, @escaping (Bool) -> Void) -> Void)?
    var onPeerFound: ((MCPeerID) -> Void)?
    var onPeerLost: ((MCPeerID) -> Void)?
    /// A small message arrived: its type tag ("pair", "carryop", …), the payload bytes, who sent it.
    var onMessage: ((String, Data, MCPeerID) -> Void)?
    /// A file finished arriving, saved at this URL (move it before returning, the system reclaims it after).
    var onReceive: ((URL, MCPeerID) -> Void)?
    /// A connected peer's session state changed (FEAT-09's glue starts the pairing exchange on `.connected`).
    var onStateChange: ((MCPeerID, MCSessionState) -> Void)?

    override private init() { super.init() }

    static func deviceName() -> String {
        let raw: String
        #if os(iOS)
        raw = UIDevice.current.name
        #else
        raw = Host.current().localizedName ?? "Mac"
        #endif
        // MCPeerID.displayName must be 1-63 UTF-8 bytes (Apple's limit); truncate rather than crash on a long name.
        var s = raw
        while s.utf8.count > 63 { s.removeLast() }
        return s.isEmpty ? "Recense" : s
    }

    /// Idempotent: a second call keeps the running advertiser/browser (a fresh browser would forget the peers the
    /// first one found, and the screen's list would point at peers no running browser knows; BUG-17).
    func advertise() {
        guard advertiser == nil else { return }
        let a = MCNearbyServiceAdvertiser(peer: myID, discoveryInfo: nil, serviceType: Self.serviceType)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a
    }

    func browse() {
        guard browser == nil else { return }
        let b = MCNearbyServiceBrowser(peer: myID, serviceType: Self.serviceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    func stop() {
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
    }

    /// Invite a peer found while browsing (FEAT-09's "Pair a device": the owner picked it by name, not yet paired,
    /// so `isPaired` won't trigger the automatic invite in `browser(foundPeer:)`).
    func invite(_ peer: MCPeerID, timeout: TimeInterval = 10) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: timeout)
    }

    enum Failure: Error { case notConnected }

    /// One wire format for every caller: FEAT-09's PairMessage, carry ops, Share's handshake, all ride this.
    func send<T: Encodable>(_ value: T, type: String, to peer: MCPeerID) throws {
        guard session.connectedPeers.contains(peer) else { throw Failure.notConnected }
        let payload = try JSONEncoder().encode(value)
        let frame = try JSONEncoder().encode(Frame(type: type, payload: payload))
        try session.send(frame, toPeers: [peer], with: .reliable)
    }

    /// Streamed, not loaded fully into memory (large files, carry's pieces). `sent` reports success or the error.
    @discardableResult
    func send(fileAt url: URL, named name: String, to peer: MCPeerID, sent: ((Error?) -> Void)? = nil) -> Progress? {
        session.sendResource(at: url, withName: name, toPeer: peer) { error in
            guard let sent else { return }
            Task { @MainActor in sent(error) }
        }
    }

    private struct Frame: Codable { let type: String; let payload: Data }
}

extension P2PTransport: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in P2PTransport.shared.onStateChange?(peerID, state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let frame = try? JSONDecoder().decode(Frame.self, from: data) else { return }
        Task { @MainActor in P2PTransport.shared.onMessage?(frame.type, frame.payload, peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        guard let localURL, error == nil else { return }
        Task { @MainActor in P2PTransport.shared.onReceive?(localURL, peerID) }
    }
}

extension P2PTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            let t = P2PTransport.shared
            if t.isPaired(peerID) { invitationHandler(true, t.session); return }
            guard let confirm = t.confirmUnpaired else { invitationHandler(false, nil); return }
            confirm(peerID) { ok in invitationHandler(ok, ok ? t.session : nil) }
        }
    }
}

extension P2PTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            let t = P2PTransport.shared
            t.onPeerFound?(peerID)
            if t.isPaired(peerID) { browser.invitePeer(peerID, to: t.session, withContext: nil, timeout: 10) }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in P2PTransport.shared.onPeerLost?(peerID) }
    }
}
