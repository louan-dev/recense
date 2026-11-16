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

    @State private var typed = ""
    @FocusState private var codeFocused: Bool

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
            if carry.askingCode, let who = carry.pairingWith {
                // P1b: type the six digits shown on the other device
                Section("Type the code shown on \(who)") {
                    TextField("6-digit code", text: $typed)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .font(.system(.largeTitle, design: .monospaced))
                        .focused($codeFocused)
                        .onChange(of: typed) { _, v in
                            typed = String(v.filter(\.isNumber).prefix(6))
                            if typed.count == 6 { carry.enterCode(typed); typed = "" }
                        }
                        .onAppear { codeFocused = true }
                    Button("Pair") { carry.enterCode(typed); typed = "" }.disabled(typed.count != 6)
                    Button("Stop Pairing", role: .cancel) { carry.stopPairing() }
                }
            } else if let code = carry.pairingCode, let who = carry.pairingWith {
                Section(carry.codeIsCompare ? "Confirm" : "Type this code on \(who)") {
                    Text(carry.codeIsCompare ? "Code with \(who)" : "Enter it on \(who) to pair").foregroundStyle(.secondary)
                    Text(code).font(.system(size: 48, weight: .bold, design: .monospaced))
                        .accessibilityLabel(code.map(String.init).joined(separator: " "))
                    if carry.codeIsCompare { Button("They Match") { carry.confirmMatch(for: who) } }
                    Button("Stop Pairing", role: .cancel) { carry.stopPairing() }
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
