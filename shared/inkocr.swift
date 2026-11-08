import Foundation
import Vision
import CoreGraphics
import ImageIO

/// Handwriting in Draftpad's ink, read on this device so Find (⌘F) finds it too. Apple's Vision text recogniser, on
/// device, no network. The page renders one group of strokes (dark ink on white) and sends it as a PNG; the text comes
/// back to the page, which keeps it with those strokes in the ink file. Built into both apps (strip/ links this file;
/// the iOS project syncs shared/).
enum InkOCR {
    /// The owner writes English, French and Vietnamese; Vision tries those it has (and detects which one).
    static let languages = ["en-US", "fr-FR", "vi-VT"]

    /// Reads the handwriting in a base64 PNG. `done` runs on the main queue with the text ("" when none is found).
    static func read(pngBase64: String, done: @escaping (String) -> Void) {
        guard let data = Data(base64Encoded: pngBase64),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            DispatchQueue.main.async { done("") }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let text = recognize(image)
            DispatchQueue.main.async { done(text) }
        }
    }

    /// The recognised lines, top to bottom, joined with spaces.
    static func recognize(_ image: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let supported = (try? req.supportedRecognitionLanguages()) ?? []
        let langs = languages.filter { supported.contains($0) }
        if !langs.isEmpty { req.recognitionLanguages = langs }
        req.automaticallyDetectsLanguage = true
        do { try VNImageRequestHandler(cgImage: image).perform([req]) } catch { return "" }
        let lines = (req.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
