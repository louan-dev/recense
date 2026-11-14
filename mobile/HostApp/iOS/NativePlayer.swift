// Our player on the iPhone and iPad (player P1 S2, 2026-11-13): an Archive file plays here, in Now Playing, with its
// transcript (PlaybackEars + ShowsKit's TranscriptSource), never in a web page. The bytes: this device's copy first
// (Recense/downloads/<path>); else the Worker streams them (fp content, this device's Access token) while a copy is
// saved here, so the next play needs no network and the ears can hear it.
import SwiftUI
import AVFoundation
import ShowsKit

@MainActor @Observable
final class NativePlayer: Transport {
    static let shared = NativePlayer()
    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var path: String?
    private(set) var isVideo = false
    @ObservationIgnored private var tick: Any?
    @ObservationIgnored private var saving: URLSessionDownloadTask?
    /// Called when a file's copy lands on this device (the ears can hear it now).
    @ObservationIgnored var saved: ((String) -> Void)?

    private init() {
        // a quarter-second refresh of the play state for the buttons; the transcript reads `time` itself, every frame
        tick = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Transport

    var time: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    var duration: Double? {
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return nil }
        return d
    }
    func toggle() { isPlaying ? player.pause() : play(); refresh() }
    func skip(_ seconds: Double) { seek(to: max(0, time + seconds)) }
    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func play() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }
    private func refresh() { let on = player.timeControlStatus != .paused; if on != isPlaying { isPlaying = on } }

    // MARK: Opening a file

    /// Opens a file of the archive bucket (`archive/…`) and plays it from the start.
    func open(_ path: String) {
        saving?.cancel(); saving = nil
        self.path = path
        isVideo = Kind(path: path) == .video
        if let local = Offline.url(path) {
            player.replaceCurrentItem(with: AVPlayerItem(url: local))
        } else if let r = Offline.remote(path) {
            player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: r.url, options: ["AVURLAssetHTTPHeaderFieldsKey": r.headers])))
            save(path, r)
        } else {
            player.replaceCurrentItem(with: nil)
        }
        play()
        refresh()
    }

    /// Saves the file to Recense/downloads/<path> while it streams (a file over 2 GB stays streamed only).
    private func save(_ path: String, _ r: (url: URL, headers: [String: String])) {
        var q = URLRequest(url: r.url)
        r.headers.forEach { q.setValue($1, forHTTPHeaderField: $0) }
        let t = URLSession.shared.downloadTask(with: q) { tmp, resp, _ in
            guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200, resp?.expectedContentLength ?? 0 < 2_000_000_000 else { return }
            let dest = Offline.saveURL(path)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { return }
            Task { @MainActor in NativePlayer.shared.saved?(path) }
        }
        saving = t
        t.resume()
    }
}

/// Where a file's bytes are: this device first, the Worker only as the fallback.
enum Offline {
    static var root: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recense") }
    /// Where a played file's copy is saved (the places contract's downloads/).
    static func saveURL(_ path: String) -> URL { root.appendingPathComponent("downloads/" + path) }
    /// This device's copy: in the pool (Recense/<path>) or saved from a play (Recense/downloads/<path>).
    static func url(_ path: String) -> URL? {
        [root.appendingPathComponent(path), saveURL(path)].first { FileManager.default.fileExists(atPath: $0.path) }
    }
    /// The path the file has where it came from (a played file's copy sits at downloads/<that path>): the Mac's
    /// transcript and this device's saved transcript go by it.
    static func origin(_ path: String) -> String {
        path.hasPrefix(Rules.downloads + "/archive/") ? String(path.dropFirst(Rules.downloads.count + 1)) : path
    }
    /// The Worker's stream of an archive file, with this device's Access token; nil when the device isn't signed in.
    static func remote(_ path: String) -> (url: URL, headers: [String: String])? {
        guard let d = Token.read(), let t = try? JSONDecoder().decode([String: String].self, from: d),
              let id = t["id"], let secret = t["secret"], let host = Gallery.base.host else { return nil }
        var c = URLComponents()
        c.scheme = "https"; c.host = host; c.path = "/main/api/fp/archive/content"
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = c.url else { return nil }
        return (url, ["CF-Access-Client-Id": id, "CF-Access-Client-Secret": secret])
    }
}

/// Now Playing's picture: the video itself, or for sound a calm card with the file's kind (no web page, no controls of
/// its own: Now Playing's are the only ones).
struct NativePlayerView: View {
    let episode: ShowsKit.Episode
    var body: some View {
        if NativePlayer.shared.isVideo && NativePlayer.shared.path == episode.item.path {
            VideoLayer(player: NativePlayer.shared.player).background(.black)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "waveform").font(.system(size: 56, weight: .light)).foregroundStyle(Theme.accent)
                Text((episode.item.path as NSString).pathExtension.uppercased()).font(.headline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        }
    }
}

private struct VideoLayer: UIViewRepresentable {
    let player: AVPlayer
    final class Host: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> Host {
        let v = Host(); v.playerLayer.player = player; v.playerLayer.videoGravity = .resizeAspect; return v
    }
    func updateUIView(_ v: Host, context: Context) { v.playerLayer.player = player }
}

/// One way in for every file the app plays natively: an episode from a path, on the root's model, Now Playing open on
/// its transcript (P2: a file opens straight into its transcript).
@MainActor enum Playback {
    static weak var model: ShowsModel?

    static func canPlay(_ path: String) -> Bool { Kind(path: path).isMedia }

    /// An episode the catalog's views started (model.play): our player plays it, when it isn't already.
    static func follow() {
        guard let model, let e = model.playing, canPlay(e.item.path) else { return }
        if NativePlayer.shared.path != e.item.path { NativePlayer.shared.open(e.item.path) }
        model.transport = NativePlayer.shared
        model.showsTranscript = true
    }

    /// Reads this device's pool again (PoolScan) into the catalog, off the main thread.
    static func rescan() {
        guard let store = model?.store as? MemoryCatalog else { return }
        let root = Offline.root
        Task.detached(priority: .utility) { await store.replaceLocal(PoolScan.items(root: root)) }
    }

    static func open(_ path: String, size: Int64 = 0, mtime: Int64 = 0) {
        guard let model else { return }
        let name = (path as NSString).lastPathComponent
        let item = PoolItem(id: "archive:" + path, path: path, size: size, mtime: mtime, local: Offline.url(path) != nil)
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        NativePlayer.shared.open(path)
        model.transport = NativePlayer.shared
        model.play(ShowsKit.Episode(item: item, show: "", title: (name as NSString).deletingPathExtension))
        model.playingShow = folder.isEmpty || folder == Gallery.rootPath ? "Archive" : folder
        model.showsTranscript = true
    }
}
