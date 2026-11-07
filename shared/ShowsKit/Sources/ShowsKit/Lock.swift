// The Face ID / Touch ID gate for Matters and Raven (owner, 11-06: they open only with Face ID or Touch ID).
// Biometrics only, on purpose: no device-passcode fallback. A device with no Face ID or Touch ID cannot open them;
// the gate says so instead of failing silently. It closes again whenever the app leaves the screen.
import Foundation
import Observation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

@MainActor @Observable
public final class Gate {
    /// Asks the person; returns nil when they passed, else the sentence to show.
    public typealias Ask = @MainActor (_ reason: String) async -> String?

    public private(set) var isOpen = false
    public private(set) var message: String?
    private let ask: Ask

    public init(ask: @escaping Ask = Gate.biometrics) { self.ask = ask }

    public func unlock(_ reason: String = "Open Matters") async {
        guard !isOpen else { return }
        let refused = await ask(reason)
        isOpen = refused == nil
        message = refused
    }

    public func lock() { isOpen = false; message = nil }

    public static func biometrics(_ reason: String) async -> String? {
        #if canImport(LocalAuthentication)
        let c = LAContext()
        c.localizedFallbackTitle = ""   // hides "Enter Password": biometrics only
        var e: NSError?
        guard c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e) else {
            return "This device has no Face ID or Touch ID set up, so Matters stays closed here."
        }
        do {
            return try await c.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) ? nil : "Not unlocked."
        } catch let err as LAError where err.code == .userCancel || err.code == .appCancel || err.code == .systemCancel {
            return "Not unlocked."
        } catch {
            return error.localizedDescription
        }
        #else
        return "Face ID and Touch ID aren't available here."
        #endif
    }
}
