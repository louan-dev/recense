// The terminal on the iPhone and iPad: SwiftTerm draws it, SSHKit carries it to the Mac.
// SwiftTerm's own key bar (esc, ctrl, tab, arrows) sits above the keyboard, so every key is reachable by touch.
#if os(iOS)
import SSHKit
import SwiftTerm
import SwiftUI
import UIKit

@MainActor
public final class TerminalSession: NSObject, ObservableObject, TerminalViewDelegate {
    public enum State: Equatable { case idle, connecting, connected(String), failed(String), closed }
    @Published public private(set) var state: State = .idle
    @Published public private(set) var title = ""
    public let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    private var connection: SSHConnection?
    private var shell: SSHShell?

    public override init() {
        super.init()
        view.terminalDelegate = self
    }

    /// Connects by the first route that answers and opens a shell sized to the view.
    public func connect(routes: [(host: String, port: Int)], user: String, key: DeviceKey, pins: PinStore) async {
        state = .connecting
        do {
            let c = try await SSHConnection.connect(routes: routes, user: user, key: key, pins: pins)
            let t = view.getTerminal()
            let sh = try await c.shell(cols: max(t.cols, 20), rows: max(t.rows, 5),
                onData: { [weak self] bytes in DispatchQueue.main.async { self?.view.feed(byteArray: bytes[...]) } },
                onClose: { [weak self] in DispatchQueue.main.async { self?.ended() } })
            connection = c; shell = sh
            state = .connected(c.server)
            _ = view.becomeFirstResponder()
        } catch {
            state = .failed(Self.explain(error, key: key))
        }
    }

    public func disconnect() {
        shell?.close()
        ended()
    }

    private func ended() {
        shell = nil
        if let c = connection { connection = nil; Task { await c.close() } }
        if case .connected = state { state = .closed }
    }

    /// Plain words for the owner, with the one thing to do next.
    public static func explain(_ error: Error, key: DeviceKey) -> String {
        switch error {
        case SSHError.authRefused:
            return "The Mac refused this device's key. Add the key below to ~/.ssh/authorized_keys on the Mac, then connect again."
        case SSHError.hostKeyChanged:
            return "The Mac's identity changed since the last connection, so Recense stopped. If you reinstalled macOS, remove its pin in Recense/ssh/pins.json."
        case SSHError.timedOut:
            return "The Mac didn't answer in time. Check that it's awake and that Remote Login is on."
        case SSHError.noRoute(let tried):
            return "No route reached the Mac. Tried: " + tried.joined(separator: "; ")
        default:
            return "Couldn't connect: \(error.localizedDescription)"
        }
    }

    // MARK: TerminalViewDelegate
    public nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated { shell?.send(bytes) }
    }
    public nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { shell?.resize(cols: newCols, rows: newRows) }
    }
    public nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated { self.title = title }
    }
    public nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public nonisolated func scrolled(source: TerminalView, position: Double) {}
    public nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let u = URL(string: link) else { return }
        MainActor.assumeIsolated { UIApplication.shared.open(u) }
    }
    public nonisolated func bell(source: TerminalView) {}
    public nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let s = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated { UIPasteboard.general.string = s }
    }
    public nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    public nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// The session's terminal view inside SwiftUI.
public struct TerminalScreen: UIViewRepresentable {
    @ObservedObject var session: TerminalSession
    public init(session: TerminalSession) { self.session = session }
    public func makeUIView(context: Context) -> TerminalView { session.view }
    public func updateUIView(_ view: TerminalView, context: Context) {}
}
#endif
