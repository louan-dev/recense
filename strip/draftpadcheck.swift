import AppKit
import WebKit

/// `recense draftpad-check <folder>`: Draftpad's Recense layer on the real path (EditorHost, WKWebView, the bundled
/// editor page, shared/recensetext.swift, the on-device model) with a test page, in a window off the screen and with
/// throwaway web storage: the owner's notes, settings and screen are never touched. Saves a PNG per view to <folder>
/// and prints what it found; exits 1 if a step fails.
func draftpadCheck(out: URL) -> Never {
    let page = """
    Sunday, November 8, 2026
    <!-- saved chk001 -->

    A contract needs an offer, acceptance and consideration. In Carlill v Carbolic Smoke Ball Co, an advertisement was held to be a unilateral offer.

    Mrs Carlill used the smoke ball as directed and still caught influenza. So the company had to pay her the £100 it promised.

    The court said the deposit of £1,000 showed the company meant its promise. Theo Điều 385 Bộ luật Dân sự 2015, hợp đồng là sự thỏa thuận giữa các bên.

    # Formation in Vietnam

    Hợp đồng được giao kết vào thời điểm bên đề nghị nhận được chấp nhận giao kết. Im lặng không được coi là chấp nhận, trừ khi các bên có thỏa thuận.
    """
    let fm = FileManager.default
    try? fm.createDirectory(at: out, withIntermediateDirectories: true)
    let vault = fm.temporaryDirectory.appendingPathComponent("recense-draftpad-check-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // Off every screen: nothing appears, nothing takes focus.
    let frame = NSRect(x: -20000, y: -20000, width: 560, height: 1100)
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    let host = EditorHost(frame: NSRect(origin: .zero, size: frame.size), vault: vault, cache: vault, ephemeral: true)
    window.contentView = host.web
    window.orderFrontRegardless()
    host.setText(page)

    var failures: [String] = []
    func note(_ ok: Bool, _ what: String) { print("\(ok ? "ok  " : "FAIL") draftpad-check, \(what)"); if !ok { failures.append(what) } }
    func js(_ code: String, _ done: @escaping (Any?) -> Void) {
        host.web.evaluateJavaScript(code) { v, e in
            if let e { print("     js error: \(e.localizedDescription) in \(code.prefix(60))") }
            done(v)
        }
    }
    func wait(_ s: Double, _ then: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: then) }
    func until(_ code: String, timeout: Double, _ then: @escaping (Bool) -> Void) {
        let start = Date()
        func poll() {
            js(code) { v in
                if (v as? Bool) == true { then(true) }
                else if Date().timeIntervalSince(start) > timeout { then(false) }
                else { wait(0.5, poll) }
            }
        }
        poll()
    }
    func shot(_ name: String, _ then: @escaping () -> Void) {
        host.web.takeSnapshot(with: nil) { img, _ in
            if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: out.appendingPathComponent("\(name).png"))
                print("     saved \(out.appendingPathComponent("\(name).png").path)")
            } else { note(false, "snapshot \(name)") }
            then()
        }
    }
    /// M2's lenses, one at a time: switch, wait until every section has it (the model writes it then), screenshot.
    func lensSteps(_ steps: [(String, String)], _ then: @escaping () -> Void) {
        guard let (lens, name) = steps.first else { return then() }
        let t = Date()
        js("window.recenseEditor.closeWing('both'); window.recenseEditor.setRecenseLens('\(lens)'); true") { _ in
            until("(s => s && s.inflight === 0 && document.querySelectorAll('.rc-lens-\(lens)').length > 0)(window.recenseEditor.recenseStatus())", timeout: 240) { ok in
                js("[...document.querySelectorAll('.rc-lens-\(lens)')].map(e => e.innerText.replace(/\\s+/g, ' ')).join(' ¦ ')") { v in
                    let text = (v as? String) ?? ""
                    print("     \(lens): \(text.prefix(700))")
                    note(ok && !text.contains("needs the model"), "\(lens) written by the on-device model in \(Int(Date().timeIntervalSince(t))) s")
                    wait(0.6) { shot(name) { lensSteps(Array(steps.dropFirst()), then) } }
                }
            }
        }
    }
    func status(_ then: @escaping ([String: Any]) -> Void) { js("JSON.stringify(window.recenseEditor.recenseStatus())") { v in
        then((v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]) } }
    func finish() -> Never {
        try? fm.removeItem(at: vault)
        print(failures.isEmpty ? "draftpad-check: all steps passed" : "draftpad-check: \(failures.count) failed: \(failures)")
        exit(failures.isEmpty ? 0 : 1)
    }

    let t0 = Date()
    host.onLoad = {
        wait(0.5) {
            js("window.recenseEditor.setRecenseLayer(true); window.recenseEditor.recenseNow(); true") { _ in
                until("(s => s && s.recensed === s.sections && s.inflight === 0)(window.recenseEditor.recenseStatus())", timeout: 240) { done in
                    status { st in
                        note(done, "every section recensed in \(Int(Date().timeIntervalSince(t0))) s: \(st)")
                        note((st["engines"] as? [String]) == ["model"], "the on-device model wrote every section's lenses (none fell back to the extractive stand-in)")
                        js("JSON.stringify(window.recenseEditor.recenseShape())") { v in
                            let shape = ((v as? String)?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]] ?? []
                            print("     shape: \(v ?? "nil")")
                            note(!shape.isEmpty && shape.allSatisfy { ($0["gist"] as? Int) == ($0["paras"] as? Int) },
                                 "Gist: one line per paragraph in every section")
                            note(!shape.isEmpty && shape.allSatisfy { ($0["page"] as? Int) == min(3, ($0["sentences"] as? Int) ?? 0) },
                                 "the page gist has three lines (fewer only for a shorter section)")
                            note(shape.allSatisfy { (($0["mixed"] as? [Any]) ?? []).isEmpty }, "no lens line mixes two languages")
                        }
                        let saved = vault.appendingPathComponent("Recensed/chk001.json")
                        note(fm.fileExists(atPath: saved.path), "the saved page's lenses are in Recensed/chk001.json")
                        if let d = try? Data(contentsOf: saved), let s = String(data: d, encoding: .utf8) {
                            try? s.write(to: out.appendingPathComponent("Recensed-chk001.json"), atomically: true, encoding: .utf8)
                        }
                        wait(0.8) { shot("1-gist") {
                            js("window.recenseEditor.setRecenseLens('reformat'); true") { _ in wait(0.8) { shot("2-reformat") {
                                js("window.recenseEditor.setRecenseLens('source'); true") { _ in
                                    until("document.querySelectorAll('.rc-lens-source').length > 0", timeout: 60) { ok in
                                        note(ok, "the Source lens shows translations")
                                        wait(0.5) { shot("3-source") {
                                            js("window.recenseEditor.setRecenseLens('gist'); document.querySelector('#rc-outline-toggle-btn').click(); [...document.querySelectorAll('.rc-chapter')].map(r => r.textContent).join(' | ')") { v in
                                                note(((v as? String) ?? "").contains("✦"), "the Chapters tab lists a recensed title: \(v ?? "")")
                                                wait(0.6) { shot("4-chapters") {
                                                    js("document.querySelector('#rc-outline-toggle-btn').click(); window.recenseEditor.openWing('right'); const t = window.recenseEditor.getText(); JSON.stringify(window.recenseEditor.recenseCardAt(t.indexOf('Mrs Carlill') + 4))") { v in
                                                        note(((v as? String) ?? "null") != "null", "the wing card takes the caret paragraph's lens line: \(v ?? "")")
                                                        wait(0.8) { shot("5-wing-card") {
                                                            js("JSON.stringify({buttons: [...document.querySelectorAll('.rc-toolbar button')].filter(b => b.offsetParent).map(b => b.getAttribute('aria-label') || b.textContent.trim()), menu: [...document.querySelectorAll('.rc-menu-item')].filter(b => !b.hidden).map(b => b.textContent)})") { v in
                                                                print("     ui: \(v ?? "")")
                                                                lensSteps([("retell", "6-retell"), ("ask", "7-ask"), ("reapply", "8-reapply")]) { finish() }
                                                            }
                                                        } }
                                                    }
                                                } }
                                            }
                                        } }
                                    }
                                }
                            } } }
                        } }
                    }
                }
            }
        }
    }
    // Never hang: give up after 6 minutes.
    DispatchQueue.main.asyncAfter(deadline: .now() + 600) { note(false, "finished within 10 minutes"); finish() }
    app.run()
    exit(1)
}
