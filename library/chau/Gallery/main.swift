// Gallery: open ~/Gallery (Public and Main) after Touch ID.
//
// Click Gallery in the Finder sidebar or the Dock: Touch ID (or your password), then the folder
// mounts if it isn't already and opens in Finder. It unmounts when the screen locks, the Mac
// sleeps, another user switches in, or nobody has used the Mac for idleLock, so the next open asks again.
// Without Touch ID (no sensor, lid closed, no finger enrolled) it asks for the login password instead. Runs without a Dock icon of its own while it waits.
//
// Build: zsh build.sh   (puts Gallery.app in /Applications)

import AppKit
import LocalAuthentication

let home = FileManager.default.homeDirectoryForCurrentUser.path
let mountPoint = home + "/Gallery"
let rclone = "/opt/homebrew/bin/rclone"
let logFile = home + "/Library/Logs/gallery-mount.log"
// close Gallery after this many seconds with nobody at the Mac (0: only on lock, sleep or user switch)
let idleLock: Double = 15 * 60

// the rclone remote "gallery" combines Public (gallery-public:folders) and Main (gallery-main:files)
let mountArgs = [
    "nfsmount", "gallery:", mountPoint,
    "--volname", "Gallery",
    "--vfs-cache-mode", "full",
    "--vfs-cache-max-size", "20G",
    "--vfs-cache-max-age", "72h",
    // the internal disk has ~13 GiB free: the cache gives way before the disk fills, whatever max-size says
    "--vfs-cache-min-free-space", "5G",
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
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(close), name: NSWorkspace.willSleepNotification, object: nil)
        // another user switched in (fast user switching): they mustn't find it open
        ws.addObserver(self, selector: #selector(close), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        // nobody touched the Mac for idleLock: close it, so a Mac left unlocked doesn't leave Gallery open
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.idleCheck() }
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

        authenticate { ok in
            DispatchQueue.main.async {
                defer { self.busy = false }
                guard ok else { return }

                // a mount this app isn't serving is a leftover from a crash or rebuild: remount it
                let alive = self.isMounted() && (self.mount?.isRunning ?? false)
                if !alive && !self.startMount() {
                    let why = self.lastLog()
                    self.say("Gallery couldn't open.\n\n" + (why.isEmpty ? "rclone stopped before the folder appeared." : why) + "\n\nFull log: ~/Library/Logs/gallery-mount.log")
                    return
                }

                NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
            }
        }
    }

    // Touch ID, or the login password when Touch ID can't be used (no sensor, lid closed on an external
    // display, no finger enrolled, too many failed tries). Never opens without one of them.
    func authenticate(_ done: @escaping (Bool) -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        context.touchIDAuthenticationAllowableReuseDuration = 0

        var why: NSError?
        let biometric = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &why) else {
            say("Gallery stays closed: this Mac can't ask for Touch ID or your password.\n\n" + (why?.localizedDescription ?? ""))
            done(false)
            return
        }

        // .deviceOwnerAuthentication asks for Touch ID when it's available and the password otherwise
        let reason = biometric ? "open Gallery" : "open Gallery (Touch ID isn't available, so use your password)"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            if !ok, let e = error as? LAError, ![.userCancel, .systemCancel, .appCancel, .userFallback].contains(e.code) {
                DispatchQueue.main.async { self.say("Gallery stays closed.\n\n" + e.localizedDescription) }
            }
            done(ok)
        }
    }

    // seconds without a key press, click or mouse move from anyone at this Mac
    func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func idleCheck() {
        guard idleLock > 0, mount != nil || isMounted(), idleSeconds() >= idleLock else { return }
        // a transfer or open file keeps it in use: try again next minute rather than cut it off
        if isMounted() && unmount([mountPoint]) != 0 { return }
        close()
    }

    // reads the kernel's mount table instead of asking the volume, so a dead mount can't freeze the app
    func isMounted() -> Bool {
        var raw: UnsafeMutablePointer<statfs>?
        let count = Int(getmntinfo(&raw, MNT_NOWAIT))
        guard let list = raw, count > 0 else { return false }
        for i in 0..<count {
            var entry = list[i]
            let target = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if target == mountPoint { return true }
        }
        return false
    }

    func startMount() -> Bool {
        try? FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        // clear a dead mount left by a crash or sleep, or rclone refuses to mount again
        let u = Process()
        u.executableURL = URL(fileURLWithPath: "/sbin/umount")
        u.arguments = ["-f", mountPoint]
        try? u.run()
        u.waitUntilExit()

        guard FileManager.default.isExecutableFile(atPath: rclone) else { return false }

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
            // refused while Finder or a transfer is using the volume; force it, or killing rclone leaves a dead mount
            if unmount([mountPoint]) != 0 { unmount(["-f", mountPoint]) }
        }
        if let p = mount, p.isRunning { p.terminate() }
        mount = nil
    }

    @discardableResult
    func unmount(_ args: [String]) -> Int32 {
        let u = Process()
        u.executableURL = URL(fileURLWithPath: "/sbin/umount")
        u.arguments = args
        do { try u.run() } catch { return -1 }
        u.waitUntilExit()
        return u.terminationStatus
    }

    func lastLog() -> String {
        guard let text = try? String(contentsOfFile: logFile, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(3).joined(separator: "\n")
    }

    func say(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
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
