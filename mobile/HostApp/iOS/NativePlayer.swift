// Our player on the iPhone and iPad (player P1 S2, 2026-11-13): an Archive file plays here, in Now Playing, with its
// transcript (PlaybackEars + ShowsKit's TranscriptSource), never in a web page. The bytes: this device's copy first
// (Recense/downloads/<path>); else the Worker streams them (fp content, this device's Access token) while a copy is
// saved here, so the next play needs no network and the ears can hear it.
import SwiftUI
import AVFoundation
import MediaPlayer
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
    @ObservationIgnored private var publishedDuration: Double?

    private init() {
        // a quarter-second refresh of the play state for the buttons; the transcript reads `time` itself, every frame
        tick = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        remote()
        // FEAT-07 P0: Loop starts the playing track again at its end
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.object as? AVPlayerItem) === self.player.currentItem, Playback.model?.loopOne == true else { return }
                self.player.seek(to: .zero) { _ in Task { @MainActor in self.play(); self.refresh() } }
            }
        }
    }

    // MARK: Transport

    /// Where the player is in the file: what it has sent to the speakers. The Lock Screen's time and skip read it.
    var position: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    /// Where the listener is (BUG-12): the position less the route's latency while it plays, so a word lights as it is
    /// heard through Bluetooth headphones, not as it leaves the phone. ShowsKit's transcript and the floating window
    /// read it; a seek to a line's start lights that line once its sound arrives.
    var time: Double { TranscriptLight.heard(position: position, rate: rate, latency: RouteLatency.current, playing: player.rate != 0) }
    /// The player's speed (0 paused): the route's latency is wall time, so it holds back `rate` times as much file (BUG-24).
    var rate: Double { Double(player.rate) }
    var duration: Double? {
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return nil }
        return d
    }
    func toggle() { isPlaying ? player.pause() : play(); refresh() }
    func skip(_ seconds: Double) { seek(to: max(0, position + seconds)) }
    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }

    private func play() {
        Self.session(hearing: Listener.shared.hearing)
        try? AVAudioSession.sharedInstance().setActive(true)
        RouteLatency.refresh()
        player.play()
    }
    /// One rule for the app's audio session (BUG-10), set by the player, the floating window and Listen: while our
    /// player holds a file and no broadcast hears, the player's (it takes the sound, as any player does, and iOS keeps
    /// its Lock Screen controls, BUG-09, even paused); otherwise mixed under other apps, so the window's silent
    /// keep-awake sound never stops another app. Before, each set its own and the last one won.
    static func session(hearing: Bool) {
        let s = AVAudioSession.sharedInstance()
        if NowPlayingInfo.ownsSession(holdsFile: shared.path != nil, hearingOutside: hearing) { try? s.setCategory(.playback, mode: .spokenAudio) }
        else { try? s.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers) }
    }
    private func refresh() {
        let on = player.timeControlStatus != .paused
        if on != isPlaying { isPlaying = on; publish() }
        if duration != publishedDuration { publish() }   // the duration arrives a moment after open
    }

    // MARK: Lock Screen, Control Center, headphones (BUG-09)

    /// Tells iOS what plays and where, so the Lock Screen draws the title and the scrubber.
    private func publish() {
        publishedDuration = duration
        guard let path else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = NowPlayingInfo.info(path: path, time: position, duration: duration, playing: isPlaying)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    /// The system's buttons drive this player: play, pause, ⏯, ±15/30 s, and dragging the scrubber.
    private func remote() {
        let c = MPRemoteCommandCenter.shared()
        // handlers may arrive off the main thread: hop to it, never assume it
        func on(_ cmd: MPRemoteCommand, _ act: @escaping @MainActor (NativePlayer, MPRemoteCommandEvent) -> Void) {
            cmd.addTarget { [weak self] e in
                guard let self else { return .commandFailed }
                Task { @MainActor in act(self, e) }
                return .success
            }
        }
        on(c.playCommand) { p, _ in if !p.isPlaying { p.toggle() } }
        on(c.pauseCommand) { p, _ in if p.isPlaying { p.toggle() } }
        on(c.togglePlayPauseCommand) { p, _ in p.toggle() }
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: NowPlayingInfo.skipBack)]
        on(c.skipBackwardCommand) { p, _ in p.skip(-NowPlayingInfo.skipBack) }
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: NowPlayingInfo.skipForward)]
        on(c.skipForwardCommand) { p, _ in p.skip(NowPlayingInfo.skipForward) }
        on(c.changePlaybackPositionCommand) { p, e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { p.seek(to: e.positionTime) }
        }
    }

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
        publish()
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
    /// FEAT-19 P2: lets go of the player in the background (locked or left), so iOS doesn't pause the video's sound.
    final class Host: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var player: AVPlayer? { didSet { apply() } }
        private var phase: BackgroundVideo.Phase = UIApplication.shared.applicationState == .background ? .background : .active
        private var observers: [NSObjectProtocol] = []
        override init(frame: CGRect) {
            super.init(frame: frame)
            let pairs: [(Notification.Name, BackgroundVideo.Event)] = [
                (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
                (UIApplication.willEnterForegroundNotification, .willEnterForeground)]
            observers = pairs.map { name, event in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.phase = BackgroundVideo.phase(after: event); self?.apply() }
                }
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        private func apply() {
            let want = BackgroundVideo.attached(phase) ? player : nil
            if playerLayer.player !== want { playerLayer.player = want }
        }
    }
    func makeUIView(context: Context) -> Host {
        let v = Host(); v.player = player; v.playerLayer.videoGravity = .resizeAspect; return v
    }
    func updateUIView(_ v: Host, context: Context) { if v.player !== player { v.player = player } }
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

    /// A played file's copy landed: the playing episode takes its content key (its marks work from now on).
    static func landed(_ path: String) {
        guard let model, model.playing?.item.path == path, model.playing?.item.key == nil, let copy = Offline.url(path) else { return }
        model.playing?.item.key = ContentKey.ofFile(copy)
        model.playing?.item.local = true
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
        // its content key from this device's copy, so Save, Played and Clicked / Not yet work on it (P1d audit, 11-13);
        // a file still streaming gets its key when the copy lands (Playback.landed)
        let copy = Offline.url(path)
        let item = PoolItem(id: "archive:" + path, path: path, key: copy.flatMap(ContentKey.ofFile), size: size, mtime: mtime, local: copy != nil)
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        NativePlayer.shared.open(path)
        model.transport = NativePlayer.shared
        model.play(ShowsKit.Episode(item: item, show: "", title: (name as NSString).deletingPathExtension))
        model.playingShow = folder.isEmpty || folder == Gallery.rootPath ? "Archive" : folder
        model.showsTranscript = true
    }
}
