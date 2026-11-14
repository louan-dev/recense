// This device's pool, read from its folders (player P1 S3, B1's first slice, 2026-11-13): every file under library/,
// downloads/ and inbox/ of Recense/ becomes a PoolItem with its content key, so Home, New and Library show what is
// really here, with no network. Dot files and dot folders, keep/ and trash/ are never listed. The catalog takes the
// result with MemoryCatalog.replaceLocal; the feed's files (B1's next slice) join beside them.
import Foundation

public enum PoolScan {
    /// The folders of the pool that hold media and documents.
    public static let tops = ["library", Rules.downloads, Zone.inbox.folder]

    /// Every file under the pool's tops, by path; ids by fp.js's rule, keys by content. Slow work (two 64 KiB reads a
    /// file): call it off the main thread.
    public static func items(root: URL) -> [PoolItem] {
        let fm = FileManager.default
        var out: [PoolItem] = []
        for top in tops {
            let base = root.appendingPathComponent(top)
            guard let walk = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in walk {
                guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      v.isRegularFile == true else { continue }
                let path = relative(u, to: root)
                let mtime = Int64(v.contentModificationDate?.timeIntervalSince1970 ?? 0)
                out.append(PoolItem(id: Rules.fileID(path), path: path, key: ContentKey.ofFile(u), size: Int64(v.fileSize ?? 0),
                                    mtime: mtime, added: mtime, local: true))
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    static func relative(_ u: URL, to root: URL) -> String {
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path, p = u.standardizedFileURL.resolvingSymlinksInPath().path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : u.lastPathComponent
    }
}
