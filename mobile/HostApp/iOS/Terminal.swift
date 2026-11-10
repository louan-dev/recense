// Terminal (C2, owner 11-10: "SSH into a terminal from every device"): the Macs in Recense/ssh/hosts.json, each opened
// in a terminal over SSH. Routes are tried in order, LAN first, then Tailscale; the tunnel route is Mac-only for now.
// This device's own key lives in its Keychain; the owner adds its public line to the Mac's ~/.ssh/authorized_keys once.
import ShowsKit
import SSHKit
import SSHTerminal
import SwiftUI

enum DeviceSSH {
    static var comment: String { UIDevice.current.userInterfaceIdiom == .pad ? "recense-ipad" : "recense-iphone" }
    static var noun: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    static func key() throws -> DeviceKey { try DeviceKey.loadOrCreate(store: KeychainKeyStore(), comment: comment) }
    static var pins: PinStore { FilePinStore(SSHHosts.file.deletingLastPathComponent().appendingPathComponent("pins.json")) }
    /// The routes this device can use, in order.
    static func routes(_ h: SSHHost) -> [(host: String, port: Int)] {
        h.routes.filter { $0.kind != .tunnel }.map { ($0.address, $0.port) }
    }
}

struct TerminalPlace: View {
    @State private var hosts = SSHHosts.load()
    @State private var keyLine = (try? DeviceSSH.key().publicLine) ?? ""
    @State private var adding = false
    @State private var sharing = false
    @State private var copied = false

    var body: some View {
        List {
            Section("Macs") {
                if hosts.isEmpty {
                    Text("No Macs yet. Choose More › Add a Mac.").foregroundStyle(.secondary)
                }
                ForEach(hosts, id: \.name) { h in
                    NavigationLink { TerminalSessionView(host: h) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.name).font(.body)
                            Text("\(h.user) · " + h.routes.map { "\($0.kind.rawValue) \($0.address)" }.joined(separator: ", "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Text(keyLine).font(.footnote.monospaced()).textSelection(.enabled)
                if copied { Text("Copied.").font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("This \(DeviceSSH.noun)'s key")
            } footer: {
                Text("Add this line to ~/.ssh/authorized_keys on the Mac once. The private half never leaves this \(DeviceSSH.noun).")
            }
        }
        .navigationTitle("Terminal").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MoreMenu {
                    Button { adding = true } label: { Label("Add a Mac", systemImage: "plus") }
                    Button { UIPasteboard.general.string = keyLine; copied = true } label: {
                        Label("Copy This \(DeviceSSH.noun)'s Key", systemImage: "doc.on.doc")
                    }
                    Button { sharing = true } label: { Label("Share This \(DeviceSSH.noun)'s Key", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { AddMacForm { h in hosts.removeAll { $0.name == h.name }; hosts.append(h); try? SSHHosts.save(hosts) } }
        }
        .sheet(isPresented: $sharing) { ActivityView(items: [keyLine]).presentationDetents([.medium]) }
        .tint(Theme.accent)
    }
}

struct AddMacForm: View {
    let save: (SSHHost) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "MacBook Pro"
    @State private var user = ""
    @State private var lan = ""
    @State private var tailscale = ""

    var body: some View {
        Form {
            Section("Mac") {
                TextField("Name", text: $name)
                TextField("User name on the Mac", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                TextField("Same Wi-Fi, e.g. MacBook-Pro.local", text: $lan).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Tailscale, e.g. macbook-pro (optional)", text: $tailscale).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Addresses") } footer: { Text("Tried in this order: same Wi-Fi first, then Tailscale.") }
        }
        .navigationTitle("Add a Mac").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    var routes: [SSHRoute] = []
                    if !lan.isEmpty { routes.append(SSHRoute(kind: .lan, address: lan.trimmingCharacters(in: .whitespaces))) }
                    if !tailscale.isEmpty { routes.append(SSHRoute(kind: .tailscale, address: tailscale.trimmingCharacters(in: .whitespaces))) }
                    save(SSHHost(name: name, user: user.trimmingCharacters(in: .whitespaces), routes: routes))
                    dismiss()
                }.disabled(name.isEmpty || user.isEmpty || (lan.isEmpty && tailscale.isEmpty))
            }
        }
    }
}

struct TerminalSessionView: View {
    let host: SSHHost
    @StateObject private var session = TerminalSession()

    var body: some View {
        ZStack {
            TerminalScreen(session: session).ignoresSafeArea(.container, edges: .bottom)
            switch session.state {
            case .connecting:
                ProgressView("Connecting to \(host.name)…").padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            case .failed(let why):
                VStack(alignment: .leading, spacing: 10) {
                    Text(why)
                    if why.contains("key") { Text((try? DeviceSSH.key().publicLine) ?? "").font(.footnote.monospaced()).textSelection(.enabled) }
                }
                .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
            case .closed:
                Text("Disconnected.").padding().background(.thinMaterial, in: Capsule())
            default:
                EmptyView()
            }
        }
        .navigationTitle(session.title.isEmpty ? host.name : session.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MoreMenu {
                    if case .connected = session.state {
                        Button(role: .destructive) { session.disconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
                    } else {
                        Button { connect() } label: { Label("Connect", systemImage: "arrow.clockwise") }
                    }
                }
            }
        }
        .task { connect() }
        .onDisappear { session.disconnect() }
    }

    private func connect() {
        guard let key = try? DeviceSSH.key() else { return }
        Task { await session.connect(routes: DeviceSSH.routes(host), user: host.user, key: key, pins: DeviceSSH.pins) }
    }
}
