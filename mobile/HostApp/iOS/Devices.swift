// Devices (FEAT-09): pair once with the Mac or the other device, then "Carry Now" pushes new files to every
// paired, connected device. One screen, driven by carrymanager.swift — no second copy of this logic on iOS.
#if GUEST
// Recense Guest has no homes of its own to carry into.
import SwiftUI
struct DevicesPlace: View { var body: some View { EmptyView() } }
#else
import MultipeerConnectivity
import ShowsKit
import SwiftUI

struct DevicesPlace: View {
    @ObservedObject private var carry = CarryManager.shared

    var body: some View {
        List {
            Section("Paired") {
                if carry.peers.isEmpty {
                    Text("No paired devices yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(carry.peers, id: \.name) { p in
                        VStack(alignment: .leading) {
                            Text(p.name)
                            Text("Paired \(p.paired)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let code = carry.pairingCode, let who = carry.pairingWith {
                Section("Confirm") {
                    Text("Code with \(who)").foregroundStyle(.secondary)
                    Text(code).font(.system(.largeTitle, design: .monospaced)).bold()
                    Button("They Match") { carry.confirmMatch(for: who) }
                }
            } else if carry.isLookingToPair {
                Section("Looking for a device to pair") {
                    ForEach(carry.pairCandidates, id: \.displayName) { peer in
                        Button(peer.displayName) { carry.invite(peer) }
                    }
                    Button("Stop Pairing", role: .cancel) { carry.stopPairing() }
                }
            } else {
                Section {
                    Button("Pair a Device…") { carry.beginPairing() }
                }
            }
            Section {
                Button("Carry Now") { carry.carryNow() }.disabled(carry.peers.isEmpty)
                Text(carry.status).font(.caption).foregroundStyle(.secondary)
                if let err = carry.lastError { Text(err).font(.caption).foregroundStyle(.red) }
            }
        }
        .recenseScreen("Devices")
        .onAppear { carry.reloadFromDisk(); carry.start() }
    }
}
#endif
