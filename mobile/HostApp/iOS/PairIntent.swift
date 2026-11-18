// Derived from Spec: FEAT-09 (P1 pairing) — the voice/Shortcuts equivalent of tapping "Pair a Device…" on the
// Devices screen. iPadOS and iOS have no terminal of their own (the device's own "Devices" screen is the only
// other way in), so this is the non-tap path the project's own rule requires ("every action is also reachable
// by menu, voice or touch"), matching the Mac's `recense carry pair` terminal command.
//
// FEAT-09 P1b: one device shows six digits, the other types them. "Pair a Device" reads back the code to type on the
// other device, or says that this one asks for it; "Enter Pairing Code" types it by voice. "Confirm Pairing" stays
// for an older peer that still compares codes (P1).
#if GUEST
// Recense Guest has no homes of its own to carry into — no pairing intents either.
#else
import AppIntents
import MultipeerConnectivity
import ShowsKit

struct PairADeviceIntent: AppIntent {
    static var title: LocalizedStringResource = "Pair a Device"
    static var description = IntentDescription(
        "Opens this device to the next nearby Recense device (10 seconds) and reads back the six-digit code.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cm = CarryManager.shared
        cm.beginPairing()
        var waited = 0.0
        var invited: MCPeerID?
        // "Pair a device" only makes this device discoverable; the GUI sends the invite only once the owner taps
        // a specific name in the "Looking for a device to pair" list. Siri has no such list, so invite the first
        // not-yet-paired device seen — there is normally only one stranger nearby when this runs.
        while cm.pairingCode == nil && !cm.askingCode && cm.lastError == nil && waited < 10 {
            if invited == nil, let peer = cm.pairCandidates.first {
                invited = peer
                cm.invite(peer)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            waited += 0.3
        }
        if let err = cm.lastError { return .result(dialog: "Pairing failed: \(err)") }
        if cm.askingCode, let who = cm.pairingWith {
            return .result(dialog: "\(who) shows a six-digit code. Say Enter Pairing Code, or type it on this screen.")
        }
        guard let code = cm.pairingCode, let who = cm.pairingWith else {
            return .result(dialog: "No device answered. Try again once the other device is looking too.")
        }
        if !cm.codeIsCompare {
            return .result(dialog: "Type \(code.map(String.init).joined(separator: " ")) on \(who).")
        }
        return .result(dialog: "Code with \(who) is \(code). Check it matches the other screen, then say or tap Confirm Pairing.")
    }
}

struct ConfirmPairingIntent: AppIntent {
    static var title: LocalizedStringResource = "Confirm Pairing"
    static var description = IntentDescription(
        "The voice equivalent of tapping \"They Match\" — only once the six-digit code is confirmed the same on both screens.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cm = CarryManager.shared
        guard let who = cm.pairingWith else {
            return .result(dialog: "No pairing is waiting to be confirmed.")
        }
        cm.confirmMatch(for: who)
        var waited = 0.0
        while cm.pairingWith != nil && cm.lastError == nil && waited < 10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            waited += 0.3
        }
        if let err = cm.lastError { return .result(dialog: "Pairing failed: \(err)") }
        guard cm.pairingWith == nil else { return .result(dialog: "Confirmed here. Waiting for \(who) to confirm too.") }
        return .result(dialog: "Paired with \(who).")
    }
}

/// FEAT-09 P1b: the voice path for typing the code shown on the other device.
struct EnterPairingCodeIntent: AppIntent {
    static var title: LocalizedStringResource = "Enter Pairing Code"
    static var description = IntentDescription("Types the six-digit code shown on the other device, to pair with it.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Code", requestValueDialog: "What six digits does the other device show?")
    var code: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cm = CarryManager.shared
        guard cm.askingCode, let who = cm.pairingWith else {
            return .result(dialog: "No pairing is waiting for a code. Say Pair a Device first.")
        }
        cm.enterCode(code)
        var waited = 0.0
        while cm.pairingWith != nil && cm.lastError == nil && waited < 10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            waited += 0.3
        }
        if let err = cm.lastError { return .result(dialog: "\(err)") }
        guard cm.pairingWith == nil else { return .result(dialog: "Still checking the code with \(who).") }
        return .result(dialog: "Paired with \(who).")
    }
}

struct RecensePairingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PairADeviceIntent(),
            phrases: ["Pair a device with \(.applicationName)", "\(.applicationName), pair a device"],
            shortTitle: "Pair a Device",
            systemImageName: "antenna.radiowaves.left.and.right")
        AppShortcut(
            intent: ConfirmPairingIntent(),
            phrases: ["Confirm pairing with \(.applicationName)", "\(.applicationName), confirm pairing"],
            shortTitle: "Confirm Pairing",
            systemImageName: "checkmark.circle")
        AppShortcut(
            intent: EnterPairingCodeIntent(),
            phrases: ["Enter pairing code in \(.applicationName)", "\(.applicationName), enter pairing code"],
            shortTitle: "Enter Pairing Code",
            systemImageName: "number.square")
        AppShortcut(   // FEAT-08: the app has one AppShortcutsProvider, so Draftpad's voice shortcut lives here
            intent: AddToDraftpadIntent(),
            phrases: ["Add to Draftpad in \(.applicationName)", "\(.applicationName), add to Draftpad"],
            shortTitle: "Add to Draftpad",
            systemImageName: "waveform.badge.plus")
    }
}
#endif
