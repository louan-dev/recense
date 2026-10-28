// The File Provider extension (NSFileProviderReplicatedExtension): the system keeps the files and placeholders on
// disk; this answers what is in a folder, what changed, and the bytes of one file. Slice 1 is read-only: creates,
// edits and deletes are refused (docs/architecture.md §9). Same source for macOS and iOS.
import FileProvider
import UniformTypeIdentifiers

final class Item: NSObject, NSFileProviderItem {
    let r: Record?  // nil: the root

    init(_ r: Record?) { self.r = r }

    var itemIdentifier: NSFileProviderItemIdentifier { r.map { NSFileProviderItemIdentifier($0.id) } ?? .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard let r, r.parent != "root" else { return .rootContainer }
        return NSFileProviderItemIdentifier(r.parent)
    }
    var filename: String { r?.name ?? "Chauphan" }
    var contentType: UTType {
        guard let r, !r.dir else { return .folder }
        return UTType(filenameExtension: (r.name as NSString).pathExtension) ?? .data
    }
    var capabilities: NSFileProviderItemCapabilities {
        (r?.dir ?? true) ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
    }
    var documentSize: NSNumber? { r?.size.map { NSNumber(value: $0) } }
    var contentModificationDate: Date? { r?.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var itemVersion: NSFileProviderItemVersion {
        let content = Data((r?.etag ?? "dir").utf8)
        return NSFileProviderItemVersion(contentVersion: content, metadataVersion: Data(((r?.etag ?? "") + "|" + (r?.path ?? "")).utf8))
    }
}

func providerError(_ e: Error) -> Error {
    switch e as? FeedError {
    case .offline?: return NSFileProviderError(.serverUnreachable)
    case .notSignedIn?: return NSFileProviderError(.notAuthenticated)
    case .expired?: return NSFileProviderError(.syncAnchorExpired)
    case .notFound?: return NSFileProviderError(.noSuchItem)
    default: return NSFileProviderError(.serverUnreachable)
    }
}

func anchor(_ seq: Int) -> NSFileProviderSyncAnchor { NSFileProviderSyncAnchor(Data(String(seq).utf8)) }
func seq(_ a: NSFileProviderSyncAnchor) -> Int? { Int(String(decoding: a.rawValue, as: UTF8.self)) }

@objc(FileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let feed = Feed()
    let store = Store()

    required init(domain: NSFileProviderDomain) { super.init() }
    func invalidate() {}

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer { completionHandler(Item(nil), nil) }
        else if let r = store[identifier.rawValue] { completionHandler(Item(r), nil) }
        else { completionHandler(nil, NSFileProviderError(.noSuchItem)) }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let r = store[itemIdentifier.rawValue], !r.dir else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        return feed.content(r.path) { result in
            switch result {
            case .success(let url): completionHandler(url, Item(r), nil)
            case .failure(let e): completionHandler(nil, nil, providerError(e))
            }
        }
    }

    // read-only for now: the capabilities already tell Finder and Files not to offer these
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        // the system propagates the root folder itself on first sync: it's already there
        if itemTemplate.itemIdentifier == .rootContainer { completionHandler(Item(nil), [], false, nil) }
        else { completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)) }
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        if item.itemIdentifier == .rootContainer { completionHandler(Item(nil), [], false, nil) }
        else { completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)) }
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet { return Enumerator(path: nil, feed: feed, store: store) }
        if containerItemIdentifier == .rootContainer { return Enumerator(path: Gallery.rootPath, feed: feed, store: store) }
        guard let r = store[containerItemIdentifier.rawValue], r.dir else { throw NSFileProviderError(.noSuchItem) }
        return Enumerator(path: r.path, feed: feed, store: store)
    }
}

// one folder's children (path), or the working set (nil: it lists nothing; its changes are the whole feed)
final class Enumerator: NSObject, NSFileProviderEnumerator {
    let path: String?
    let feed: Feed
    let store: Store

    init(path: String?, feed: Feed, store: Store) { self.path = path; self.feed = feed; self.store = store }
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard let path else { return observer.finishEnumerating(upTo: nil) }
        let first = page.rawValue == (NSFileProviderPage.initialPageSortedByName as Data) || page.rawValue == (NSFileProviderPage.initialPageSortedByDate as Data)
        feed.items(path, cursor: first ? nil : String(decoding: page.rawValue, as: UTF8.self)) { result in
            switch result {
            case .success(let (records, cursor)):
                self.store.put(records)
                observer.didEnumerate(records.map(Item.init))
                observer.finishEnumerating(upTo: cursor.map { NSFileProviderPage(Data($0.utf8)) })
            case .failure(let e):
                observer.finishEnumeratingWithError(providerError(e))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        guard let since = seq(syncAnchor) else { return observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired)) }
        feed.changes(since: since) { result in
            switch result {
            case .success(let c):
                let inside = c.events.filter { $0.path.hasPrefix(Gallery.rootPath + "/") }
                let gone = inside.filter { $0.op == "delete" }.map(\.id)
                let updated = inside.filter { $0.op != "delete" }.map(\.record)
                self.store.put(updated)
                self.store.remove(gone)
                if !updated.isEmpty { observer.didUpdate(updated.map(Item.init)) }
                if !gone.isEmpty { observer.didDeleteItems(withIdentifiers: gone.map { NSFileProviderItemIdentifier($0) }) }
                observer.finishEnumeratingChanges(upTo: anchor(c.seq), moreComing: c.more)
            case .failure(let e):
                observer.finishEnumeratingWithError(providerError(e))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        feed.changes(since: nil) { completionHandler((try? $0.get()).map { anchor($0.seq) }) }
    }
}
