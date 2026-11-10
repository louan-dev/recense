// The app's own places, shown as rows in the skin's Library (ShowsKit `Place`): what the old sidebar (Browser.swift)
// listed. Owner of this file and of the screens' re-skin: Claude 2 (`.handoff/reskin/INBOX.md`).
import SwiftUI
import ShowsKit

enum RecensePlaces {
    @MainActor static var all: [Place] {
        [
            Place(id: "draftpad", title: "Draftpad", symbol: "square.and.pencil") { DraftpadView() },
            // Listen: on Home, as the "Listening" card (ListeningCard.swift, owner 11-09), no longer a row here
            Place(id: "archive", title: "Archive", symbol: "icloud") { FolderView(path: Gallery.rootPath) },
            Place(id: "main", title: "Main", symbol: "square.grid.2x2") { MainView() },
            Place(id: "terminal", title: "Terminal", symbol: "terminal") { TerminalPlace() },  // SSH to the Macs (Terminal.swift)
            Place(id: "ask", title: "Ask", symbol: "lightbulb") {
                PlayerView(url: galleryURL("/main/archive", ["ask": "1"])).webPlace("Ask")
            },
            Place(id: "data", title: "Data", symbol: "externaldrive") {
                PlayerView(url: galleryURL("/main/archive", ["p": "Data"])).webPlace("Data")
            },
            Place(id: "exhibits", title: "Exhibits", symbol: "rectangle.stack") {
                PlayerView(url: galleryURL("/main", ["exhibits": "1"])).webPlace("Exhibits")
            },
            // the site's Shared section draws its own title bar (Personal | Shared | Activity): only the way back here
            Place(id: "shared", title: "Shared", symbol: "person.2") {
                PlayerView(url: galleryURL("/main/shared")).webPlace("")
            },
        ]
    }
}

// The skin's chrome for the app's own screens (proposed for ShowsKit's Theme once both apps use it).
extension View {
    /// A web place (Gallery's page in a PlayerView): the page to the bottom edge, an inline title, the accent.
    func webPlace(_ title: String) -> some View {
        self.ignoresSafeArea(edges: .bottom)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .tint(Theme.accent)
    }

    /// A round toolbar button, like Podcasts' `···`: glass on iOS 26, a plain circle before.
    @ViewBuilder func glassCircle() -> some View {
        // the accent set here too: a toolbar item takes its tint from the bar, not from the screen under it
        if #available(iOS 26, *) { self.labelStyle(.iconOnly).buttonBorderShape(.circle).buttonStyle(.glass).tint(Theme.accent) }
        else { self.labelStyle(.iconOnly).buttonBorderShape(.circle).buttonStyle(.bordered).tint(Theme.accent) }
    }
}

/// The `···` button every screen carries: each action of the screen is also here (never a gesture or shortcut alone).
struct MoreMenu<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Menu { content } label: { Label("More", systemImage: "ellipsis") }.menuStyle(.button).glassCircle()  // .button: so the circle applies
    }
}
