// upload-status.swift: read-only. For each file under the given iCloud folders, asks Foundation (public
// NSURL ubiquity keys) whether iCloud has it. Prints totals and up to 10 stuck files per folder.
//   swift tools/upload-status.swift "<folder>" [...]      exit 0 = everything uploaded
import Foundation
let keys: [URLResourceKey] = [.isRegularFileKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey, .fileSizeKey]
var stuckAny = false
for root in CommandLine.arguments.dropFirst() {
  var total = 0, uploaded = 0, pending = 0, bytes = 0; var errors: [String: Int] = [:]; var sample: [String] = []
  let en = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [])
  while let u = en?.nextObject() as? URL {
    if u.path.contains("~gingerlabs~Notability") { en?.skipDescendants(); continue }
    if u.lastPathComponent == ".DS_Store" { continue } // never synced by design
    guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
    total += 1
    if v.ubiquitousItemIsUploaded == true { uploaded += 1; continue }
    pending += 1; bytes += v.fileSize ?? 0
    if let e = v.ubiquitousItemUploadingError { errors[e.localizedDescription, default: 0] += 1 }
    if sample.count < 10 { sample.append(String(u.path.dropFirst(root.count))) }
  }
  print("\(root)\n  files \(total), uploaded \(uploaded), not uploaded \(pending) (\(bytes) bytes)")
  for (e, n) in errors { print("  error ×\(n): \(e)") }
  for s in sample { print("  · \(s)") }
  if pending > 0 { stuckAny = true }
}
exit(stuckAny ? 1 : 0)
