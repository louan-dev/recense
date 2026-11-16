// Derived from Spec: FEAT-09 P1b (pair by typing the code, T-0086)
// The Mac's pairing code, in a window you can see: Recense is LSUIElement (no Dock icon, its menu hidden in the strip),
// so a code only in a menu would be missed. The window opens when this Mac shows a code or asks for one, and closes
// when pairing ends. The same actions as Library › Devices on the iPhone and iPad: type, Pair, Stop Pairing.
import AppKit
import Combine
import SwiftUI

@MainActor final class PairCodeWindow {
    static let shared = PairCodeWindow()
    private var panel: NSPanel?
    private var watch: AnyCancellable?

    /// Called once at launch: follows CarryManager and shows or hides the window.
    func follow(_ cm: CarryManager = .shared) {
        watch = cm.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.update(cm) }   // objectWillChange fires before the value changes
        }
    }

    private func update(_ cm: CarryManager) {
        let wanted = cm.askingCode || (cm.pairingCode != nil && !cm.codeIsCompare)
        if wanted, panel == nil { open(cm) }
        if !wanted, let p = panel { p.close(); panel = nil }
    }

    private func open(_ cm: CarryManager) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "Pair a Device"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.contentViewController = NSHostingController(rootView: PairCodeView(cm: cm))
        p.center()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p
    }
}

final class TypedCode: ObservableObject { @Published var text = "" }

struct PairCodeView: View {
    @ObservedObject var cm: CarryManager
    @StateObject private var box = TypedCode()   // not @State: the CLT toolchain has no SwiftUIMacros plugin
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            if cm.askingCode, let who = cm.pairingWith {
                Text("Type the code shown on \(who)").font(.title3)
                TextField("6-digit code", text: $box.text)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onChange(of: box.text) { _, v in
                        box.text = String(v.filter(\.isNumber).prefix(6))
                        if box.text.count == 6 { cm.enterCode(box.text); box.text = "" }
                    }
                    .onSubmit { cm.enterCode(box.text); box.text = "" }
                    .onAppear { focused = true }
                Button("Pair") { cm.enterCode(box.text); box.text = "" }
                    .keyboardShortcut(.defaultAction).disabled(box.text.count != 6)
            } else if let code = cm.pairingCode, let who = cm.pairingWith {
                Text("Type this code on \(who)").font(.title3)
                Text(code).font(.system(size: 56, weight: .bold, design: .monospaced))
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))
            }
            if let err = cm.lastError { Text(err).font(.callout).foregroundStyle(.red) }
            Button("Stop Pairing", role: .cancel) { cm.stopPairing() }
        }
        .padding(24)
        .frame(width: 360)
    }
}
