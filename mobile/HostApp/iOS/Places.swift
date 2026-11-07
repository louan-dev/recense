// The app's own places, shown as rows in the skin's Library (ShowsKit `Place`): what the old sidebar (Browser.swift)
// listed. Owner of this file and of the screens' re-skin: Claude 2 (`.handoff/reskin/INBOX.md`).
import SwiftUI
import ShowsKit

enum RecensePlaces {
    @MainActor static var all: [Place] {
        [
            Place(id: "draftpad", title: "Draftpad", symbol: "square.and.pencil") { DraftpadView() },
            Place(id: "listen", title: "Listen", symbol: "captions.bubble") { ListenView() },
            Place(id: "ask", title: "Ask", symbol: "lightbulb") {
                PlayerView(url: galleryURL("/main/archive", ["ask": "1"])).ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Ask").navigationBarTitleDisplayMode(.inline)
            },
            Place(id: "main", title: "Main", symbol: "square.grid.2x2") { MainView() },
            Place(id: "archive", title: "Archive", symbol: "icloud") { FolderView(path: Gallery.rootPath) },
            Place(id: "data", title: "Data", symbol: "externaldrive") {
                PlayerView(url: galleryURL("/main/archive", ["p": "Data"])).ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Data").navigationBarTitleDisplayMode(.inline)
            },
            Place(id: "exhibits", title: "Exhibits", symbol: "rectangle.stack") {
                PlayerView(url: galleryURL("/main", ["exhibits": "1"])).ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Exhibits").navigationBarTitleDisplayMode(.inline)
            },
            Place(id: "shared", title: "Shared", symbol: "person.2") {
                PlayerView(url: galleryURL("/main/shared")).ignoresSafeArea(edges: .bottom)
                    .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            },
        ]
    }
}
