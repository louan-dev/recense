// Disks Helper: launchd (com.chauphan.disks-mount) runs this instead of /bin/zsh, so macOS checks this app's
// privacy grant (Full Disk Access) and not zsh's. Run by zsh directly, the script is refused the network volume
// (ls ~/.disks: "Operation not permitted") and attaches nothing.
// It runs bin/disks-mount.zsh as a child (children inherit the grant) and passes launchd's SIGTERM on, so the
// script can detach the disks before it exits.
import Foundation

let script = CommandLine.arguments.count > 1
  ? CommandLine.arguments[1] : NSHomeDirectory() + "/Developer/sync/bin/disks-mount.zsh"
let child = Process()
child.executableURL = URL(fileURLWithPath: "/bin/zsh")
child.arguments = [script]
child.terminationHandler = { exit($0.terminationStatus) }

signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { child.terminate() }
term.resume()

do { try child.run() } catch {
  FileHandle.standardError.write("disks helper: \(error)\n".data(using: .utf8)!)
  exit(1)
}
dispatchMain()
