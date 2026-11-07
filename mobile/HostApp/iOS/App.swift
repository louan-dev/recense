// Gallery (iOS/iPadOS): the app's own Files-like browser and Gallery's player (Browser.swift, Player.swift), and the
// "Archive" location in the Files app.
// The device's Access token comes inside the app (ios/Secrets/token.json, written by ios/build.sh from the Mac's
// Keychain, never in git) and is moved into the shared Keychain group on first launch, where the extension reads it.
import SwiftUI
import FileProvider

let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("archive"), displayName: "Archive")

@main
struct GalleryFilesApp: App {
    @State private var status = "Adding Archive to Files…"

    var body: some Scene {
        WindowGroup {
            RecenseRoot()   // the Podcasts-style shell (Shows.swift); Browser() was the root until 11-07
                .modifier(MaybeListening(on: ProcessInfo.processInfo.environment["RECENSE_NO_LISTEN"] == nil))
                .task { status = await setUp() }
                .overlay(alignment: .bottom) {
                    // only says something when the Files location couldn't be set up
                    if status.hasPrefix("Couldn") || status.hasPrefix("No access") {
                        Text(status).font(.footnote).padding(10).background(.thinMaterial, in: Capsule()).padding()
                    }
                }
        }
    }

    func setUp() async -> String {
        if Token.read() == nil, let bundled = Bundle.main.url(forResource: "token", withExtension: "json"),
           let d = try? Data(contentsOf: bundled), !d.isEmpty {
            _ = Token.write(d)
        }
        guard Token.read() != nil else { return "No access token in this build." }
        do {
            try? await NSFileProviderManager.remove(NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("chauphan"), displayName: "Chauphan"))  // the old name
            try await NSFileProviderManager.add(domain)
            try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
            return "Archive is in Files."
        } catch {
            return "Couldn't add it: \(error.localizedDescription)"
        }
    }
}

/// Captions' listener on the root; simulator screenshots set RECENSE_NO_LISTEN to skip its speech prompt.
struct MaybeListening: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.listening() } else { content }
    }
}
