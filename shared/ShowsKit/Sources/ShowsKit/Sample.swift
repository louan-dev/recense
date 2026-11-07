// A small made-up pool for previews and tests, until B1's pool store feeds the skin real files.
// Every name here is invented; nothing is read from the device.
import Foundation

public extension MemoryCatalog {
    static func sample(device: String) -> MemoryCatalog {
        func k(_ s: String) -> ContentKey { ContentKey(rawValue: String(repeating: "0", count: 24 - s.count) + s)! }
        let day: Int64 = 86_400, now = HLCClock.wallNow() / 1000
        let files: [(String, String)] = [
            ("inbox/Voice memo 11-06.m4a", "a1"),
            ("inbox/Lecture clip.mp4", "a2"),
            ("library/Study/MPEP/Chapter 2100/2106 Eligibility.m4a", "b1"),
            ("library/Study/MPEP/Chapter 2100/2111 Claim interpretation.m4a", "b2"),
            ("library/Study/MPEP/Chapter 2100/2131 Anticipation.m4a", "b3"),
            ("library/Study/MPEP/Chapter 2100/2141 Obviousness.m4a", "b4"),
            ("library/Study/MPEP/Chapter 700/706 Rejections.m4a", "b5"),
            ("library/Folio/Essays/Draft reading.m4a", "c1"),
            ("library/Podcasts/Law and language.mp3", "d1"),
            ("library/Matters/Client A/Call notes.m4a", "e1"),
        ]
        let items = files.enumerated().map { n, f in
            PoolItem(id: "s\(n)", path: f.0, key: k(f.1), size: 1_000_000, mtime: now - Int64(n) * day, added: now - Int64(n) * day,
                     local: true, kind: Kind(path: f.0))
        }
        let mpep = ShowManifest(title: "MPEP", lang: "en", episodes: [
            .init(n: 1, title: "2106 Patent subject matter eligibility", file: "Chapter 2100/2106 Eligibility.m4a", duration: 392),
            .init(n: 2, title: "2111 Claim interpretation", file: "Chapter 2100/2111 Claim interpretation.m4a", duration: 410),
            .init(n: 3, title: "2131 Anticipation", file: "Chapter 2100/2131 Anticipation.m4a", duration: 365),
            .init(n: 4, title: "2141 Obviousness", file: "Chapter 2100/2141 Obviousness.m4a", duration: 455),
            .init(n: 5, title: "706 Rejection of claims", file: "Chapter 700/706 Rejections.m4a", duration: 300),
        ])
        let inbox = ShowManifest(episodes: [
            .init(title: "Voice memo, 6 November", file: "Voice memo 11-06.m4a", duration: 154),
            .init(title: "Lecture clip: treaty interpretation", file: "Lecture clip.mp4", duration: 1260),
        ])
        let podcasts = ShowManifest(title: "Law and Language", episodes: [
            .init(n: 1, title: "Reading statutes in two languages", file: "Law and language.mp3", duration: 2580,
                  summary: "How bilingual codes are read when the versions disagree."),
        ])
        let ms = now * 1000
        let listens = [
            ListenPosition(device: "iphone", key: k("b1"), seconds: 120, at: HLC(wall: ms - 3_600_000, node: "iphone")),
            ListenPosition(device: "ipad", key: k("d1"), seconds: 1500, at: HLC(wall: ms - 3 * 86_400_000, node: "ipad")),
        ]
        let states = [ItemState(key: k("b2"), starred: Stamped(true, at: HLC(wall: ms - 86_400_000, node: "mac")))]
        return MemoryCatalog(device: device, items: items,
                             manifests: ["library/Study/MPEP": mpep, "inbox": inbox, "library/Podcasts": podcasts],
                             transcripts: [k("b1"): .ready, k("b2"): .ready, k("a1"): .transcribing], states: states, listens: listens)
    }
}
