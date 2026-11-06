// Gallery: open Gallery (Public, Main and tmp, mounted at the hidden ~/.gallery) after Touch ID.
//
// Click Gallery in the Finder sidebar or the Dock: Touch ID (or your password), then the folder
// mounts if it isn't already and opens in Finder. It stays open while you work (closing its window doesn't close it) and unmounts
// when the screen locks, the Mac sleeps, another user switches in, or nobody has used the Mac for idleLock, so the next open asks again.
// Without Touch ID (no sensor, lid closed, no finger enrolled) it asks for the login password instead. Runs without a Dock icon of its own while it waits.
//
// Build: zsh build.sh   (puts Gallery.app in /Applications)

import AppKit
import CryptoKit
import LocalAuthentication

let home = FileManager.default.homeDirectoryForCurrentUser.path
// rclone's keys. Once locked (`rclone config encryption set`), Gallery asks for that password once per Mac and keeps it
// sealed by a Secure Enclave key that only Touch ID or the login password opens. Unattended jobs use jobs.conf instead.
let rcloneConf = home + "/.config/rclone/rclone.conf"
let sealedPass = home + "/Library/Application Support/Gallery/config-pass.json"
let recoveryDoc = home + "/Developer/recense/docs/runbooks/recovery.md"
// hidden, so nobody browsing your home folder finds a way in; Gallery.app opens it after Touch ID
let mountPoint = home + "/.gallery"
let rclone = "/opt/homebrew/bin/rclone"
let logFile = home + "/Library/Logs/gallery-mount.log"
// rclone's default --cache-dir on macOS: copies of what you opened in vfs/gallery, their state in vfsMeta/gallery
let cacheDir = home + "/Library/Caches/rclone"
// close Gallery after this many seconds with nobody at the Mac (0: only on lock, sleep or user switch)
let idleLock: Double = 15 * 60

// the rclone remote "gallery" combines Public (gallery-public:folders) and Main (gallery-main:files)
let mountArgs = [
    "nfsmount", "gallery:", mountPoint,
    "--volname", "Gallery",
    // keeps the "localhost" volume out of Finder's sidebar and the Desktop
    "-o", "nobrowse",
    // rclone's NFS server has no lock manager; without local locks TextEdit and most document apps won't open a file
    "-o", "locallocks",
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
        // the screen went dark or the screensaver started without a lock: close anyway
        ws.addObserver(self, selector: #selector(close), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(close), name: .init("com.apple.screensaver.didstart"), object: nil)
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

        authenticate { context in
            DispatchQueue.main.async {
                defer { self.busy = false }
                guard let context = context else { return }

                // a mount this app isn't serving is a leftover from a crash or rebuild: remount it
                let alive = self.isMounted() && (self.mount?.isRunning ?? false)
                if !alive {
                    guard let pass = self.configPassword(context) else { return }
                    if !self.startMount(pass) {
                        let why = self.lastLog()
                        self.say("Gallery couldn't open.\n\n" + (why.isEmpty ? "rclone stopped before the folder appeared." : why) + "\n\nFull log: ~/Library/Logs/gallery-mount.log")
                        return
                    }
                }

                NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
            }
        }
    }

    // Touch ID, or the login password when Touch ID can't be used (no sensor, lid closed on an external
    // display, no finger enrolled, too many failed tries). Never opens without one of them.
    // -> the unlocked context (it also opens the sealed rclone password, so one prompt does both), or nil
    func authenticate(_ done: @escaping (LAContext?) -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        context.touchIDAuthenticationAllowableReuseDuration = 0

        var why: NSError?
        let biometric = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &why) else {
            say("Gallery stays closed: this Mac can't ask for Touch ID or your password.\n\n" + (why?.localizedDescription ?? ""))
            done(nil)
            return
        }

        // .deviceOwnerAuthentication asks for Touch ID when it's available and the password otherwise
        let reason = biometric ? "open Gallery" : "open Gallery (Touch ID isn't available, so use your password)"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            if !ok, let e = error as? LAError, ![.userCancel, .systemCancel, .appCancel, .userFallback].contains(e.code) {
                DispatchQueue.main.async { self.say("Gallery stays closed.\n\n" + e.localizedDescription) }
            }
            done(ok ? context : nil)
        }
    }

    // ---------- the rclone password (only once rclone.conf is locked) ----------

    // "" when rclone.conf isn't locked; nil when Gallery should stay closed
    func configPassword(_ context: LAContext) -> String? {
        let head = (try? String(contentsOfFile: rcloneConf, encoding: .utf8))?.prefix(40) ?? ""
        guard head.hasPrefix("# Encrypted rclone configuration File") else { return "" }
        if let p = unseal(context), rcloneAccepts(p) { return p }
        // first open on this Mac, after a repair, or the sealed copy is gone: ask once, then Touch ID is enough again
        var hint = "Type the Gallery keys password once. After that, Touch ID is enough on this Mac."
        while let p = askPassword(hint) {
            if rcloneAccepts(p) {
                seal(p)
                return p
            }
            hint = "That isn't it. Try again, or choose \"I forgot it\": nothing in Gallery is lost, you only make new keys."
        }
        return nil
    }

    func askPassword(_ hint: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Gallery keys password"
        a.informativeText = hint
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: "Open")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "I forgot it")
        a.window.initialFirstResponder = field
        switch a.runModal() {
        case .alertFirstButtonReturn: return field.stringValue
        case .alertThirdButtonReturn:
            say("Your files are safe in R2: this password only locks the keys on this Mac.\n\nTo get in again, make new keys in the Cloudflare dashboard. The steps are in recovery.md, which opens now.")
            NSWorkspace.shared.open(URL(fileURLWithPath: recoveryDoc))
            return nil
        default: return nil
        }
    }

    // rclone reads the password from stdin through --password-command, so it never sits in an environment ps can show
    func rcloneRun(_ args: [String], pass: String) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclone)
        p.arguments = (pass.isEmpty ? [] : ["--password-command", "cat"]) + args
        let input = Pipe()
        p.standardInput = input
        do { try p.run() } catch { return nil }
        if !pass.isEmpty { input.fileHandleForWriting.write(Data((pass + "\n").utf8)) }
        try? input.fileHandleForWriting.close()
        return p
    }

    func rcloneAccepts(_ pass: String) -> Bool {
        guard let p = rcloneRun(["listremotes"], pass: pass) else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // ECIES to a Secure Enclave key: sealing needs only its public half; opening needs Touch ID or the login password
    func seal(_ pass: String) {
        var err: Unmanaged<CFError>?
        guard SecureEnclave.isAvailable,
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &err),
              let se = try? SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access) else { return }
        let eph = P256.KeyAgreement.PrivateKey()
        guard let shared = try? eph.sharedSecretFromKeyAgreement(with: se.publicKey),
              let box = try? AES.GCM.seal(Data(pass.utf8), using: boxKey(shared)).combined else { return }
        let file: [String: String] = [
            "key": se.dataRepresentation.base64EncodedString(),
            "eph": eph.publicKey.rawRepresentation.base64EncodedString(),
            "box": box.base64EncodedString(),
        ]
        try? FileManager.default.createDirectory(atPath: (sealedPass as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: file) else { return }
        FileManager.default.createFile(atPath: sealedPass, contents: data, attributes: [.posixPermissions: 0o600])
    }

    func unseal(_ context: LAContext) -> String? {
        guard let data = FileManager.default.contents(atPath: sealedPass),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let key = Data(base64Encoded: file["key"] ?? ""), let eph = Data(base64Encoded: file["eph"] ?? ""),
              let box = Data(base64Encoded: file["box"] ?? ""),
              let se = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: key, authenticationContext: context),
              let pub = try? P256.KeyAgreement.PublicKey(rawRepresentation: eph),
              let shared = try? se.sharedSecretFromKeyAgreement(with: pub),
              let sealed = try? AES.GCM.SealedBox(combined: box),
              let plain = try? AES.GCM.open(sealed, using: boxKey(shared)) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    func boxKey(_ shared: SharedSecret) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("gallery rclone password".utf8), outputByteCount: 32)
    }

    // seconds without a key press, click or mouse move from anyone at this Mac
    func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func idleCheck() {
        guard idleLock > 0, mount != nil || isMounted(), idleSeconds() >= idleLock else { return }
        // force it like a lock does: Finder showing the folder counts as "in use" and would keep it open forever
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

    func startMount(_ pass: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        // clear a dead mount left by a crash or sleep, or rclone refuses to mount again
        let u = Process()
        u.executableURL = URL(fileURLWithPath: "/sbin/umount")
        u.arguments = ["-f", mountPoint]
        try? u.run()
        u.waitUntilExit()

        guard FileManager.default.isExecutableFile(atPath: rclone) else { return false }

        guard let p = rcloneRun(mountArgs, pass: pass) else { return false }
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
        let wasOpen = mount != nil || isMounted()
        if isMounted() {
            // refused while Finder or a transfer is using the volume; force it, or killing rclone leaves a dead mount
            if unmount([mountPoint]) != 0 { unmount(["-f", mountPoint]) }
        }
        if let p = mount, p.isRunning {
            p.terminate()
            // let rclone finish writing its cache before it's wiped
            for _ in 0..<20 where p.isRunning { Thread.sleep(forTimeInterval: 0.25) }
        }
        let stopped = !(mount?.isRunning ?? false)
        mount = nil
        if wasOpen { wipeTraces(cache: stopped) }
    }

    // leave nothing of Gallery on this Mac once it's closed: rclone's copies of the files you opened,
    // and the Quick Look thumbnails Finder made of them
    func wipeTraces(cache: Bool) {
        if cache && !waitingToUpload(cacheDir + "/vfsMeta/gallery") {
            for dir in ["/vfs/gallery", "/vfsMeta/gallery"] { try? FileManager.default.removeItem(atPath: cacheDir + dir) }
        } else {
            // a file you saved hasn't reached R2 yet and lives only in the cache: keep it, the next open uploads it
            note("cache kept: rclone still running or files waiting to upload")
        }
        let q = Process()
        q.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        q.arguments = ["-r", "cache"]
        q.standardOutput = FileHandle.nullDevice
        q.standardError = FileHandle.nullDevice
        try? q.run()
        q.waitUntilExit()
    }

    // rclone marks a cached file "Dirty" until it has uploaded it
    func waitingToUpload(_ dir: String) -> Bool {
        guard let files = FileManager.default.enumerator(atPath: dir) else { return false }
        for case let f as String in files {
            guard let data = FileManager.default.contents(atPath: dir + "/" + f),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if info["Dirty"] as? Bool == true { return true }
        }
        return false
    }

    func note(_ text: String) {
        guard let h = FileHandle(forWritingAtPath: logFile) else { return }
        h.seekToEndOfFile()
        h.write(Data("\(Date()) Gallery.app: \(text)\n".utf8))
        h.closeFile()
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
