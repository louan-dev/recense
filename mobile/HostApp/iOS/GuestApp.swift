// Recense Guest (iPhone): Now Playing only. The same Listen code as Recense (Listen.swift, Captions, the broadcast
// extension), compiled with the GUEST flag into its own app: no Library, Draftpad, Archive in Files, or Gallery token,
// so it runs fully on the device and nothing reaches Gallery. Built by `zsh mobile/ios/build.sh --guest`.
#if GUEST
import SwiftUI
import ShowsKit

@main
struct RecenseGuestApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack { ListenView(title: "Now Playing") }
                .tint(Theme.accent)
                .listening()
        }
    }
}
#endif
