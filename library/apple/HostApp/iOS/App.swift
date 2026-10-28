// Gallery Files (iOS/iPadOS): adds the "Chauphan" location to the Files app and says whether it's working.
// The device's Access token comes inside the app (ios/Secrets/token.json, written by ios/build.sh from the Mac's
// Keychain, never in git) and is moved into the shared Keychain group on first launch, where the extension reads it.
import SwiftUI
import FileProvider

let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("chauphan"), displayName: "Chauphan")

@main
struct GalleryFilesApp: App {
    @State private var status = "Adding Chauphan to Files…"

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Image(systemName: "folder.badge.gearshape").font(.system(size: 48))
                Text("Gallery Files").font(.title2.bold())
                Text(status).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("Open the Files app › Browse › Chauphan.").font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            .task { status = await setUp() }
        }
    }

    func setUp() async -> String {
        if Token.read() == nil, let bundled = Bundle.main.url(forResource: "token", withExtension: "json"),
           let d = try? Data(contentsOf: bundled), !d.isEmpty {
            _ = Token.write(d)
        }
        guard Token.read() != nil else { return "No access token in this build." }
        do {
            try await NSFileProviderManager.add(domain)
            try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
            return "Chauphan is in Files."
        } catch {
            return "Couldn't add it: \(error.localizedDescription)"
        }
    }
}
