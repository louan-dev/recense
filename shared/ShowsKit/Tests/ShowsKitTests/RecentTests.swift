// Owner 11-10: newer media bumps what played before down to Recently Played; the app's own items (Recense's
// Listen episodes) merge with the catalog's by when each played, newest first.
import SwiftUI
import XCTest
@testable import ShowsKit

@MainActor
final class RecentTests: XCTestCase {
    func testAppItemsMergeByWhenTheyPlayed() async throws {
        let store = MemoryCatalog.sample(device: "ipad")
        let m = ShowsModel(store: store, gate: Gate { _ in nil })
        await m.reload()
        let played = m.recentlyPlayed
        XCTAssertFalse(played.isEmpty, "the sample has played episodes")
        let newest = try XCTUnwrap(played.first?.position?.at.wall)
        let x = { (id: String, at: Int64) in RecentItem(id: id, at: at, row: AnyView(EmptyView())) }
        let merged = Recent.merged(played, [x("old", 0), x("new", newest + 1)])
        XCTAssertEqual(merged.first?.id, "x:new", "a newer app item comes first")
        XCTAssertEqual(Recent.merged(played, [x("old", 0)], limit: .max).last?.id, "x:old", "an older app item goes below")
        XCTAssertEqual(merged.map(\.at), merged.map(\.at).sorted(by: >), "newest first")
        XCTAssertLessThanOrEqual(Recent.merged(played, (0..<20).map { x("l\($0)", Int64($0)) }).count, 12, "Home shows 12")
        XCTAssertEqual(Recent.merged([], [x("a", 5), x("b", 9)]).map(\.id), ["x:b", "x:a"])
    }
}
