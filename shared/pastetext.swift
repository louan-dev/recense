// Derived from Spec: FEAT-26 (Paste as Text)
import Foundation
import PDFKit
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO

/// Turns a copied file into editable text, on this device, no network. Never changes or deletes the file.
enum PasteText {
    static let textLimit = 50_000
    static let pdfOCRPages = 20

    /// One section per file, joined by a blank line.
    static func text(for urls: [URL]) -> String {
        urls.map { text(for: $0) }.joined(separator: "\n\n")
    }

    static func text(for url: URL) -> String {
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let link = "[\(name)](\(url.absoluteString))"
        guard let t = type else { return link }
        if t.conforms(to: .pdf) {
            let s = pdfText(url)
            return s.isEmpty ? link : "> **From \(name):**\n\n\(s)"
        }
        if t.conforms(to: .image) {
            let s = imageText(url)
            return s.isEmpty ? "![\(name)](\(url.absoluteString))" : s
        }
        if t.conforms(to: .zip) { return zipListing(url).map { "\(name):\n\($0)" } ?? link }
        if t.conforms(to: .text) || t.conforms(to: .sourceCode) || t.conforms(to: .json) {
            guard let data = try? Data(contentsOf: url) else { return link }
            let cut = data.count > textLimit
            let body = String(decoding: data.prefix(textLimit), as: UTF8.self)
            let lang = url.pathExtension.lowercased()
            return "```\(lang)\n\(body)\(body.hasSuffix("\n") ? "" : "\n")```" + (cut ? "\n(truncated at 50 KB)" : "")
        }
        return link
    }

    /// The PDF's text layer; for a scan with none, Vision OCR on the first pages.
    static func pdfText(_ url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        let s = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        var out: [String] = []
        for i in 0..<min(doc.pageCount, pdfOCRPages) {
            guard let page = doc.page(at: i), let img = render(page) else { continue }
            let t = InkOCR.recognize(img)
            if !t.isEmpty { out.append(t) }
        }
        return out.joined(separator: "\n\n")
    }

    static func imageText(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "" }
        return InkOCR.recognize(img)
    }

    /// File names inside a zip, read-only (/usr/bin/zipinfo, arguments passed as an array: no shell).
    static func zipListing(_ url: URL) -> String? {
        #if os(macOS)
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-1", url.path]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { "- \($0)" }.joined(separator: "\n")
        #else
        return nil
        #endif
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox); let scale: CGFloat = 2
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}

#if os(macOS)
import AppKit

extension PasteText {
    /// Reads copied files, pastes their text into the front app with ⌘V, then puts the original clipboard back.
    /// No file on the clipboard: a plain ⌘V.
    static func pasteFromClipboard() {
        let pb = NSPasteboard.general
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { sendCommandV(); return }
        let saved = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let text = PasteText.text(for: urls)
            DispatchQueue.main.async {
                pb.clearContents(); pb.setString(text, forType: .string)
                let mine = pb.changeCount
                sendCommandV()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard pb.changeCount == mine else { return }   // the user copied something new: leave it
                    pb.clearContents(); pb.writeObjects(saved)
                }
            }
        }
    }

    static func sendCommandV() {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down) else { continue }
            e.flags = .maskCommand
            e.post(tap: .cghidEventTap)
        }
    }
}
#endif
