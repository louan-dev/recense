// FEAT-13: what a show page does to its folder, on top of FEAT-07's Rename and Delete (`EpisodeFiles`): "+" adds
// files into the show's folder, ··· › Move to… takes an episode into another show, and rows show a thumbnail.
// The host does the file work (shared/homefiles.swift over shared/homes.swift); a host without them hides the controls.
import Foundation
import CoreGraphics

/// FEAT-13's part of the host's file work. Defaults hide "+" and Move to… for a host that doesn't do them.
@MainActor public protocol ShowFolderFiles {
    /// "+" shows on this show's page.
    func canAdd(to show: Show) -> Bool
    /// Takes each file into the show's folder: moved, never overwriting ("name 2.ext").
    func add(_ files: [URL], to show: Show) throws
    /// Moves the episode's file into another show's folder.
    func move(_ e: Episode, to show: Show) throws
    /// A first frame, first page or the image itself; nil for audio and anything without a picture.
    func thumbnail(for e: Episode, side: CGFloat) async -> CGImage?
}

extension ShowsModel {
    private var folders: ShowFolderFiles? { files as? ShowFolderFiles }

    public func canAdd(to show: Show) -> Bool { !isLocked(show) && (folders?.canAdd(to: show) ?? false) }

    /// Shows an episode can move to: the others in its space whose folder takes files, New excluded.
    public func destinations(for e: Episode) -> [Show] {
        guard let folders, canChange(e) else { return [] }
        let space = shows.first { $0.value.contains { $0.id == e.show } }?.key
        return (space.flatMap { shows[$0] } ?? []).filter { $0.id != e.show && $0.id != Show.newID && folders.canAdd(to: $0) }
    }

    public func add(_ urls: [URL], to show: Show) {
        guard let folders, !urls.isEmpty else { return }
        do { try folders.add(urls, to: show) } catch { problem = "Couldn't add \(Self.names(urls)): \(error.localizedDescription)" }
        changed()
    }

    public func move(_ e: Episode, to show: Show) {
        guard let folders else { return }
        do { try folders.move(e, to: show) } catch { problem = "Couldn't move \(e.title): \(error.localizedDescription)" }
        changed()
    }

    public func thumbnail(for e: Episode, side: CGFloat) async -> CGImage? {
        await folders?.thumbnail(for: e, side: side)
    }

    static func names(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
    }
}
