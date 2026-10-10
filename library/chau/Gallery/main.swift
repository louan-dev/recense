// Gallery: open ~/Gallery (Public and Main) after Touch ID.
//
// Click Gallery in the Finder sidebar or the Dock: Touch ID (or your password), then the folder
// mounts if it isn't already and opens in Finder. It unmounts when the screen locks or the Mac
// sleeps, so the next open asks again. Runs without a Dock icon of its own while it waits.
//
// Build: zsh build.sh   (puts Gallery.app in /Applications)

import AppKit
import LocalAuthentication

let home = FileManager.default.homeDirectoryForCurrentUser.path
let mountPoint = home + "/Gallery"
let rclone = "/opt/homebrew/bin/rclone"
let logFile = home + "/Library/Logs/gallery-mount.log"

// the rclone remote "gallery" combines Public (gallery-public:folders) and Main (gallery-main:files)
let mountArgs = [
    "nfsmount", "gallery:", mountPoint,
    "--volname", "Gallery",
    "--vfs-cache-mode", "full",
    "--vfs-cache-max-size", "20G",
    "--dir-cache-time", "1m",
    "--metadata",
    "--log-file", logFile,
    "--log-level", "INFO",
]

final class App: NSObject, NSApplicationDelegate {
    var mount: Process?
    var busy = false

    func applicationDidFinishLaunching(_ note: Notification) {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(close), name: .init("com.apple.screenIsLocked"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(close), name: NSWorkspace.willSleepNotification, object: nil)
        open()
    }

    // a second click while it is running
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        open()
        return false
    }

    func applicationWillTerminate(_ note: Notification) {
        close()
    }

    func open() {
        if busy { return }
        busy = true

        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "open Gallery") { ok, _ in
            DispatchQueue.main.async {
                defer { self.busy = false }
                guard ok else { return }

                if !self.isMounted() && !self.startMount() {
                    self.say("Gallery couldn't connect. Check your internet connection, then try again.")
                    return
                }

                NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
            }
        }
    }

    func isMounted() -> Bool {
        var info = statfs()
        guard statfs(mountPoint, &info) == 0 else { return false }
        let target = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return target == mountPoint
    }

    func startMount() -> Bool {
        try? FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclone)
        p.arguments = mountArgs
        do { try p.run() } catch { return false }
        mount = p

        // wait up to 15 seconds for the mount to appear
        for _ in 0..<60 {
            if isMounted() { return true }
            if !p.isRunning { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return isMounted()
    }

    @objc func close() {
        if isMounted() {
            let u = Process()
            u.executableURL = URL(fileURLWithPath: "/sbin/umount")
            u.arguments = [mountPoint]
            try? u.run()
            u.waitUntilExit()
        }
        if let p = mount, p.isRunning { p.terminate() }
        mount = nil
    }

    func say(_ text: String) {
        let a = NSAlert()
        a.messageText = "Gallery"
        a.informativeText = text
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
