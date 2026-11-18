// Derived from Spec: FEAT-01
// Regression guard: BUG-33 (the export bookkeeping is ExportJobs and ExportGate in shared/exportjobs.swift; this file
// adds no second queue and no second naming rule).
// Writes an audio file as one M4B: AAC audio, a chapter track from a ChapterPlan, title/author/album tags and the
// language tag. AVFoundation only, no network, no ffmpeg. Errors are returned, never discarded.
import Foundation
import AVFoundation
import CoreMedia

struct M4BMetadata: Sendable {
    var title: String
    var author: String = ""
    var album: String = ""
    /// BCP 47 ("en", "vi", "fr-CA"); written on the audio and the chapter track and on the tags.
    var language: String = "en"
}

struct M4BError: Error, Sendable, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

enum M4BWriter {
    /// One audiobook at a time (ExportGate), into `dir`, as `base.m4b` or `base 2.m4b` … : never replaces a file.
    /// The audio is written under a `.partial` name and renamed only when finished, so a failure leaves no half file.
    static func write(audio: URL, chapters: [M4BChapter], metadata: M4BMetadata, dir: URL, base: String) async -> Result<URL, M4BError> {
        await ExportGate.shared.run {
            await encode(audio: audio, chapters: chapters, metadata: metadata, dir: dir, base: base)
        }
    }

    private static func encode(audio: URL, chapters: [M4BChapter], metadata: M4BMetadata, dir: URL, base: String) async -> Result<URL, M4BError> {
        guard FileManager.default.fileExists(atPath: audio.path) else { return .failure(M4BError("The audio file is missing: \(audio.lastPathComponent)")) }
        guard !chapters.isEmpty else { return .failure(M4BError("No chapters to write")) }
        let partial = dir.appendingPathComponent(".\(UUID().uuidString).m4b.partial")
        let result: Result<Void, M4BError> = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: run(audio: audio, chapters: chapters, metadata: metadata, partial: partial))
            }
        }
        switch result {
        case .failure(let e):
            try? FileManager.default.removeItem(at: partial)
            return .failure(e)
        case .success:
            let out = ExportJobs.freeURL(dir, base: base, ext: "m4b")
            do { try FileManager.default.moveItem(at: partial, to: out); return .success(out) }
            catch { try? FileManager.default.removeItem(at: partial); return .failure(M4BError("Couldn't save the audiobook: \(error.localizedDescription)")) }
        }
    }

    /// The blocking part: read PCM from `audio`, write AAC plus the chapter track to `partial`.
    private static func run(audio: URL, chapters: [M4BChapter], metadata: M4BMetadata, partial: URL) -> Result<Void, M4BError> {
        do {
            let asset = AVURLAsset(url: audio)
            guard let track = asset.tracks(withMediaType: .audio).first else { return .failure(M4BError("No audio in \(audio.lastPathComponent)")) }
            let reader = try AVAssetReader(asset: asset)
            let pcm = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100])
            reader.add(pcm)

            let writer = try AVAssetWriter(outputURL: partial, fileType: .m4a)
            writer.metadata = tags(metadata)
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100, AVEncoderBitRateKey: 64_000])
            audioIn.languageCode = iso639_2(metadata.language)
            guard let fdesc = textFormat() else { return .failure(M4BError("Couldn't make the chapter track format")) }
            let textIn = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: fdesc)
            textIn.languageCode = iso639_2(metadata.language)
            textIn.marksOutputTrackAsEnabled = false
            guard writer.canAdd(audioIn), writer.canAdd(textIn) else { return .failure(M4BError("The writer refused the audio or chapter track")) }
            writer.add(audioIn); writer.add(textIn)
            audioIn.addTrackAssociation(withTrackOf: textIn, type: AVAssetTrack.AssociationType.chapterList.rawValue)

            guard reader.startReading() else { return .failure(M4BError("Couldn't read the audio: \(reader.error?.localizedDescription ?? "unknown")")) }
            guard writer.startWriting() else { return .failure(M4BError("Couldn't start writing: \(writer.error?.localizedDescription ?? "unknown")")) }
            writer.startSession(atSourceTime: .zero)

            var next = 0
            func appendChapters(upTo t: TimeInterval) throws {
                while next < chapters.count, chapters[next].start <= t {
                    while !textIn.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                    guard let sb = chapterSample(chapters[next], format: fdesc) else { throw M4BError("Couldn't make chapter \(next + 1)") }
                    if !textIn.append(sb) { throw M4BError("Couldn't write chapter \(next + 1): \(writer.error?.localizedDescription ?? "unknown")") }
                    next += 1
                }
            }
            try appendChapters(upTo: 0)
            while let sb = pcm.copyNextSampleBuffer() {
                try appendChapters(upTo: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)))
                while !audioIn.isReadyForMoreMediaData {
                    if writer.status == .failed { throw M4BError("Writing failed: \(writer.error?.localizedDescription ?? "unknown")") }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                if !audioIn.append(sb) { throw M4BError("Couldn't write audio: \(writer.error?.localizedDescription ?? "unknown")") }
            }
            if reader.status == .failed { throw M4BError("Reading the audio failed: \(reader.error?.localizedDescription ?? "unknown")") }
            try appendChapters(upTo: .infinity)
            audioIn.markAsFinished(); textIn.markAsFinished()
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            if writer.status != .completed { return .failure(M4BError("Couldn't finish the audiobook: \(writer.error.map { "\($0)" } ?? "unknown")")) }
            return .success(())
        } catch let e as M4BError { return .failure(e) }
        catch { return .failure(M4BError(error.localizedDescription)) }
    }

    private static func tags(_ m: M4BMetadata) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ v: String) -> AVMetadataItem? {
            if v.isEmpty { return nil }
            let i = AVMutableMetadataItem(); i.identifier = id; i.value = v as NSString; i.extendedLanguageTag = m.language; return i
        }
        return [item(.commonIdentifierTitle, m.title), item(.commonIdentifierArtist, m.author),
                item(.commonIdentifierAlbumName, m.album.isEmpty ? m.title : m.album)].compactMap { $0 }
    }

    private static func textFormat() -> CMFormatDescription? {
        var fd: CMFormatDescription?
        let ext: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: 0x0800_0000 as Int,
            kCMTextFormatDescriptionExtension_BackgroundColor as String: [kCMTextFormatDescriptionColor_Red as String: 0, kCMTextFormatDescriptionColor_Green as String: 0,
                                                                          kCMTextFormatDescriptionColor_Blue as String: 0, kCMTextFormatDescriptionColor_Alpha as String: 255],
            kCMTextFormatDescriptionExtension_HorizontalJustification as String: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification as String: 0,
            kCMTextFormatDescriptionExtension_DefaultTextBox as String: [kCMTextFormatDescriptionRect_Top as String: 0, kCMTextFormatDescriptionRect_Left as String: 0,
                                                                         kCMTextFormatDescriptionRect_Bottom as String: 0, kCMTextFormatDescriptionRect_Right as String: 0],
            kCMTextFormatDescriptionExtension_FontTable as String: ["1": "Helvetica"],
            kCMTextFormatDescriptionExtension_DefaultStyle as String: [
                kCMTextFormatDescriptionStyle_StartChar as String: 0, kCMTextFormatDescriptionStyle_EndChar as String: 0,
                kCMTextFormatDescriptionStyle_Font as String: 1, kCMTextFormatDescriptionStyle_FontFace as String: 0,
                kCMTextFormatDescriptionStyle_ForegroundColor as String: [kCMTextFormatDescriptionColor_Red as String: 255, kCMTextFormatDescriptionColor_Green as String: 255,
                                                                          kCMTextFormatDescriptionColor_Blue as String: 255, kCMTextFormatDescriptionColor_Alpha as String: 255],
                kCMTextFormatDescriptionStyle_FontSize as String: 12]]
        CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Text, mediaSubType: 0x74783367 /* 'tx3g' */,
                                  extensions: ext as CFDictionary, formatDescriptionOut: &fd)
        return fd
    }

    /// A 3GPP text sample: a 2-byte big-endian length, then the UTF-8 title. It lasts until the next chapter.
    private static func chapterSample(_ c: M4BChapter, format: CMFormatDescription) -> CMSampleBuffer? {
        let utf8 = Array(c.title.utf8.prefix(60_000))
        var bytes = [UInt8](); bytes.append(UInt8(utf8.count >> 8)); bytes.append(UInt8(utf8.count & 0xff)); bytes += utf8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr,
              let b = block,
              CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: b, offsetIntoDestination: 0, dataLength: bytes.count) == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: max(c.end - c.start, 0.001), preferredTimescale: 44100),
                                        presentationTimeStamp: CMTime(seconds: c.start, preferredTimescale: 44100), decodeTimeStamp: .invalid)
        var size = bytes.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: b, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    /// "en" to "eng", "vi" to "vie", "fr-CA" to "fra": the three-letter code the m4b language box holds ("und" if unknown).
    static func iso639_2(_ tag: String) -> String {
        let code = tag.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
        let map = ["en": "eng", "vi": "vie", "fr": "fra", "es": "spa", "de": "deu", "it": "ita", "pt": "por", "ja": "jpn", "ko": "kor",
                   "zh": "zho", "ar": "ara", "ru": "rus", "hi": "hin", "th": "tha", "nl": "nld"]
        if code.count == 3 { return code }
        return map[code] ?? "und"
    }
}
