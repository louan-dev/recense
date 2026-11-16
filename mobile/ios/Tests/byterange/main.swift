// Regression guard: FEAT-19 P4 · the editor's embedded recordings are served in byte ranges (shared/embedfiles.swift).
// ByteRange is pure; it is copied out of embedfiles.swift so it compiles without WebKit:
// { echo 'import Foundation'; sed -n '/^enum ByteRange/,$p' shared/embedfiles.swift; } > "$TMPDIR/byterange.swift" && swiftc -O "$TMPDIR/byterange.swift" mobile/ios/Tests/byterange/main.swift -o "$TMPDIR/byterange" && "$TMPDIR/byterange"
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { failed += 1; print("FAIL L\(line): \(what)") } }

check(ByteRange.parse(nil, size: 100) == .whole, "no Range → the whole file")
check(ByteRange.parse("bytes=0-1", size: 100) == .part(0..<2), "WebKit's first probe: two bytes")
check(ByteRange.parse("bytes=10-", size: 100) == .part(10..<100), "open end → to the end")
check(ByteRange.parse("bytes=90-200", size: 100) == .part(90..<100), "end past the file → clamped")
check(ByteRange.parse("bytes=-10", size: 100) == .part(90..<100), "suffix → the last 10 bytes")
check(ByteRange.parse("bytes=100-", size: 100) == .unsatisfiable, "start at the size → 416")
check(ByteRange.parse("bytes=0-1,5-6", size: 100) == .whole, "several ranges → the whole file")
check(ByteRange.parse("items=0-1", size: 100) == .whole, "another unit → the whole file")
check(ByteRange.parse("bytes=5-2", size: 100) == .whole, "end before start → ignored")
check(ByteRange.contentRange(0..<2, size: 100) == "bytes 0-1/100", "Content-Range")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
