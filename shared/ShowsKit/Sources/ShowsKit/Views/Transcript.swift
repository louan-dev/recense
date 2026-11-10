// The transcript, as iOS Podcasts shows it (owner's screenshots 08, 13, 13b, 17, 40-45, 91 and NOTES.md in
// ~/.claude/context/recense/research/podcasts-ios/): large serif lines on the show's dark colour; the line being heard
// bold, its spoken words bright and the rest of it dim; the other lines quieter; the view follows the playhead; tap a
// line to play from it; hold a line for Play / Copy / Share from <time> / Select Text. Every one of those is also in
// the ··· menu, and scrolling away shows a "Now" button that brings the view back to the playhead.
// One view for both apps' places: iOS Listen (live captions of what plays in other apps) and Now Playing (our player).
// Words are lit by their own times (SpeechAnalyzer, shared/speechcore.swift); a line without word times is lit in
// proportion to its time, cut at the language's own word breaks (Foundation's, which know Vietnamese and French).
// Reduce Motion: the view jumps to the line instead of scrolling to it.
import SwiftUI

public struct TranscriptWord: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

public struct TranscriptLine: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [TranscriptWord]
    public var translation: String?
    /// A chapter that begins with this line (its heading is drawn above it).
    public var chapter: String?
    public init(id: String, start: Double, end: Double, text: String, words: [TranscriptWord] = [], translation: String? = nil, chapter: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.words = words; self.translation = translation; self.chapter = chapter
    }
}

/// What is lit at a time: the rules, apart from the view, so they can be tested.
public enum TranscriptLight {
    /// How often the lit word is redrawn: the screen's rate, capped at 60 a second (the Mac's light runs on its display
    /// link). At 12 a second a word could light up to 83 ms late, over the 50 ms the owner allows against the Mac.
    public static let frame: Double = 1.0 / 60
    /// How long the view takes to scroll to the next line.
    public static let scroll: Double = 0.45
    /// How far ahead the view turns to the next line: its scroll, plus a moment for the line to be still, bold and
    /// wrapped before its first word lights (blind critics, 11-10: started on the word, it was seen ~450 ms late;
    /// started one scroll ahead, the line was still moving and re-wrapping as the word lit).
    public static let lead: Double = scroll + 0.15
    /// The line the view turns to at `t` (scrolls to, draws bold): the one that begins within the next `lead`
    /// seconds, else the active one. With Reduce Motion the view jumps, so it goes to the active line.
    public static func following(_ lines: [TranscriptLine], at t: Double, jump: Bool = false) -> Int? {
        active(lines, at: jump ? t : t + lead)
    }
    /// The line being heard at `t`: the last one that has begun (nil before the first).
    public static func active(_ lines: [TranscriptLine], at t: Double) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi { let m = (lo + hi) / 2; if lines[m].start <= t { lo = m + 1 } else { hi = m } }
        return lo == 0 ? nil : lo - 1
    }

    /// Where each word sits in the line's text, found in order (a word the text doesn't have is skipped). Swift's
    /// String compares by canonical equivalence, so "Tòa" composed and decomposed are the same word.
    public static func ranges(_ line: TranscriptLine) -> [Range<String.Index>?] {
        var cur = line.text.startIndex
        return line.words.map { w in
            guard !w.text.isEmpty, let r = line.text.range(of: w.text, range: cur..<line.text.endIndex) else { return nil }
            cur = r.upperBound
            return r
        }
    }

    /// How much of the line's text has been said at `t`: up to the end of the last word begun. Without word times,
    /// in proportion to the line's time, at the end of a whole word.
    public static func spoken(_ line: TranscriptLine, at t: Double, ranges: [Range<String.Index>?]? = nil) -> String.Index {
        let text = line.text
        if !line.words.isEmpty {
            let rs = ranges ?? Self.ranges(line)
            var to = text.startIndex
            for (i, w) in line.words.enumerated() where w.start <= t { if let r = rs[i] { to = r.upperBound } }
            return to
        }
        let span = max(0.01, line.end - line.start)
        let f = min(1, max(0, (t - line.start) / span))
        guard f > 0 else { return text.startIndex }
        guard f < 1 else { return text.endIndex }
        let target = text.index(text.startIndex, offsetBy: Int((Double(text.count) * f).rounded()))
        var to = text.startIndex
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, r, _, stop in
            if r.lowerBound <= target { to = r.upperBound } else { stop = true }
        }
        return to
    }

    /// 754 → "12:34"; 4521 → "1:15:21".
    public static func clock(_ t: Double) -> String {
        let s = max(0, Int(t)), h = s / 3600, m = (s / 60) % 60, x = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, x) : String(format: "%d:%02d", m, x)
    }

    /// The whole transcript as text, a time before every line (Copy, Select Text).
    public static func text(_ lines: [TranscriptLine], translations: Bool) -> String {
        lines.map { l in
            var s = "[\(clock(l.start))] \(l.text)"
            if translations, let t = l.translation, !t.isEmpty { s += "\n\(t)" }
            return s
        }.joined(separator: "\n\n")
    }
}

/// The view's own state (an ObservableObject: the Mac builds ShowsKit without SwiftUI's macros, README).
final class TranscriptState: ObservableObject {
    @Published var following = true
    @Published var translations = true
    @Published var selecting = false
    var lastActive: Int?
}

public struct TranscriptView<Extra: View>: View {
    let lines: [TranscriptLine]
    let title: String
    let seed: String
    let time: () -> Double?
    let active: Int?
    let ticking: Bool
    let seek: ((Double) -> Void)?
    let empty: String
    let duration: Double?
    let extra: Extra
    @StateObject private var state = TranscriptState()
    @StateObject private var scrub = ScrubState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - lines: in time order. title: the episode's (shared lines say where they're from). seed: the show's colours.
    /// - time: the playhead now (nil: nothing is playing, so nothing is lit). ticking: read it every frame (TranscriptLight.frame).
    /// - active: the line being heard, when the host knows it better than the times do (Listen's live captions).
    /// - seek: plays from a time; nil where the audio can't be moved (another app's).
    /// - duration: the episode's length; with `seek`, our scrubber sits under the transcript (Scrubber.swift), and it
    ///   and the lines share one playhead: dragging it moves the lit line, tapping a line moves it.
    /// - extra: the host's own items, added to the ··· menu.
    public init(lines: [TranscriptLine], title: String, seed: String? = nil, time: @escaping () -> Double?, ticking: Bool = true,
                active: Int? = nil, seek: ((Double) -> Void)?, duration: Double? = nil, empty: String = "No transcript yet.",
                @ViewBuilder extra: () -> Extra) {
        self.lines = lines; self.title = title; self.seed = seed ?? title; self.time = time; self.ticking = ticking
        self.active = active; self.seek = seek; self.duration = duration; self.empty = empty; self.extra = extra()
    }

    /// The one playhead: the scrubber's while it's held, else the player's.
    private func now() -> Double? { scrub.held ?? time() }

    private var hasTranslations: Bool { lines.contains { !($0.translation ?? "").isEmpty } }

    public var body: some View {
        let (_, deep) = Theme.hues(seed)
        VStack(spacing: 0) {
        ZStack(alignment: .bottom) {
            if lines.isEmpty {
                Text(empty).font(.system(.title2, design: .serif)).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center).padding(Theme.gutter).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineView(.animation(minimumInterval: TranscriptLight.frame, paused: !ticking)) { _ in
                    let t = now()
                    let a = active ?? t.flatMap { TranscriptLight.active(lines, at: $0) }
                    let ahead = active ?? t.flatMap { TranscriptLight.following(lines, at: $0, jump: reduceMotion) }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 22) {
                                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                                    row(line, i: i, active: a, focus: ahead, t: t).id(line.id)
                                }
                            }
                            .padding(.horizontal, Theme.gutter).padding(.vertical, 120)
                            .frame(maxWidth: Theme.readable, alignment: .leading)
                            .frame(maxWidth: .infinity)
                        }
                        .scrollIndicators(.hidden)
                        .modifier(DetachOnDrag(state: state))
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                                                     .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .onAppear { if let a { proxy.scrollTo(lines[a].id, anchor: UnitPoint(x: 0.5, y: 0.3)) } }
                        .onChange(of: ahead) { _, now in follow(proxy, now) }
                        .onChange(of: state.following) { _, on in if on { follow(proxy, a, force: true) } }
                    }
                }
            }
            if !state.following && !lines.isEmpty {
                Button { state.following = true } label: {
                    Label("Now", systemImage: "arrow.down.to.line").font(.headline).padding(.horizontal, 16).padding(.vertical, 10)
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 16)
                .accessibilityLabel("Back to the line being heard")
            }
        }
        .overlay(alignment: .topTrailing) { menu.padding(12) }
            if let d = duration, d > 0, let seek {
                TimelineView(.periodic(from: .now, by: ticking ? 0.25 : 3600)) { _ in Scrubber(now: time() ?? 0, time: time, duration: d, seek: seek, state: scrub) }
                    .padding(.horizontal, Theme.gutter).padding(.top, 6)
                    .frame(maxWidth: Theme.readable)
            }
        }
        .background(LinearGradient(colors: [deep, Color(white: 0.06)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .onChange(of: scrub.held != nil) { _, held in if held { state.following = true } }
        .sheet(isPresented: $state.selecting) {
            SelectTextSheet(text: TranscriptLight.text(lines, translations: hasTranslations && state.translations), close: { state.selecting = false })
        }
    }

    private func follow(_ proxy: ScrollViewProxy, _ a: Int?, force: Bool = false) {
        guard let a, state.following, force || a != state.lastActive else { return }
        state.lastActive = a
        let go = { proxy.scrollTo(lines[a].id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
        if reduceMotion { go() } else { withAnimation(.easeInOut(duration: TranscriptLight.scroll)) { go() } }
    }

    /// - active: the line being heard (its words light by their times). focus: the line the view has turned to
    ///   (bold, its translation brighter): the next one just before it begins, so it doesn't re-wrap as its word lights.
    @ViewBuilder private func row(_ line: TranscriptLine, i: Int, active a: Int?, focus: Int?, t: Double?) -> some View {
        let on = i == a, bold = i == (focus ?? a)
        let content = VStack(alignment: .leading, spacing: 8) {
            if let c = line.chapter {
                Text(c).font(.title3.weight(.bold)).foregroundStyle(.white).padding(.top, i == 0 ? 0 : 14)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(lit(line, on: on, t: t))
                .font(.system(.title2, design: .serif).weight(bold ? .semibold : .regular))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if state.translations, let tr = line.translation, !tr.isEmpty {
                Text(tr).font(.system(.title3, design: .serif)).foregroundStyle(.white.opacity(bold ? 0.75 : 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        Group {
            if let seek {
                Button { state.following = true; seek(line.start) } label: { content }
                    .buttonStyle(.plain)
                    .accessibilityHint("Plays from \(TranscriptLight.clock(line.start))")
            } else { content }
        }
        .contextMenu { lineMenu(line) }
    }

    /// The active line: what's been said bright, the rest dim. Other lines: quieter, all alike (as Podcasts).
    private func lit(_ line: TranscriptLine, on: Bool, t: Double?) -> AttributedString {
        guard on else {
            var a = AttributedString(line.text); a.foregroundColor = .white.opacity(0.45); return a
        }
        guard let t else { var a = AttributedString(line.text); a.foregroundColor = .white; return a }
        let cut = TranscriptLight.spoken(line, at: t)
        var said = AttributedString(String(line.text[..<cut])), rest = AttributedString(String(line.text[cut...]))
        said.foregroundColor = .white
        rest.foregroundColor = .white.opacity(0.4)
        return said + rest
    }

    @ViewBuilder private func lineMenu(_ line: TranscriptLine) -> some View {
        if let seek { Button { state.following = true; seek(line.start) } label: { Label("Play", systemImage: "play") } }
        ShareLink(item: share(line)) { Label("Share from \(TranscriptLight.clock(line.start))…", systemImage: "square.and.arrow.up") }
        Button { Clipboard.copy(line.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
        Button { state.selecting = true } label: { Label("Select Text…", systemImage: "selection.pin.in.out") }
    }

    private func share(_ line: TranscriptLine) -> String { "“\(line.text)”\n\(title), from \(TranscriptLight.clock(line.start))" }

    private var menu: some View {
        Menu {
            if !state.following { Button { state.following = true } label: { Label("Follow the Playhead", systemImage: "arrow.down.to.line") } }
            if let a = active ?? now().flatMap({ TranscriptLight.active(lines, at: $0) }), lines.indices.contains(a) {
                ShareLink(item: share(lines[a])) { Label("Share from \(TranscriptLight.clock(lines[a].start))…", systemImage: "square.and.arrow.up") }
            }
            Button { state.selecting = true } label: { Label("Select Text…", systemImage: "selection.pin.in.out") }.disabled(lines.isEmpty)
            Button { Clipboard.copy(TranscriptLight.text(lines, translations: hasTranslations && state.translations)) } label: {
                Label("Copy Transcript", systemImage: "doc.on.doc")
            }.disabled(lines.isEmpty)
            if hasTranslations {
                Toggle(isOn: $state.translations) { Label("Show Translation", systemImage: "character.bubble") }
            }
            extra
        } label: {
            // not "···": that's the episode's menu beside it (one look per function)
            Image(systemName: "text.alignleft").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Transcript options")
    }
}

public extension TranscriptView where Extra == EmptyView {
    init(lines: [TranscriptLine], title: String, seed: String? = nil, time: @escaping () -> Double?, ticking: Bool = true,
         active: Int? = nil, seek: ((Double) -> Void)?, duration: Double? = nil, empty: String = "No transcript yet.") {
        self.init(lines: lines, title: title, seed: seed, time: time, ticking: ticking, active: active, seek: seek, duration: duration, empty: empty) { EmptyView() }
    }
}

/// Scrolling by hand lets go of the playhead until "Now" (or a line) is tapped. (macOS 15 / iOS 18 tell a drag apart
/// from the view's own scrolling; before that the view keeps following.)
private struct DetachOnDrag: ViewModifier {
    @ObservedObject var state: TranscriptState
    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.onScrollPhaseChange { _, phase in if phase == .interacting { state.following = false } }
        } else { content }
    }
}

enum Clipboard {
    static func copy(_ s: String) {
        #if os(iOS)
        UIPasteboard.general.string = s
        #elseif os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}

/// Select Text: the whole transcript in the system's own text view, so the handles and the menu are the system's
/// (Copy, Look Up, Translate, Share), as in Podcasts (43-45).
struct SelectTextSheet: View {
    let text: String
    let close: () -> Void
    var body: some View {
        NavigationStack {
            SelectableText(text: text).ignoresSafeArea(edges: .bottom)
                .navigationTitle("Select Text")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }
}

#if os(iOS)
struct SelectableText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false; v.isSelectable = true; v.alwaysBounceVertical = true
        v.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont(descriptor: UIFont.preferredFont(forTextStyle: .title3).fontDescriptor.withDesign(.serif) ?? UIFont.preferredFont(forTextStyle: .title3).fontDescriptor, size: 0))
        v.adjustsFontForContentSizeCategory = true
        v.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 40, right: 16)
        return v
    }
    func updateUIView(_ v: UITextView, context: Context) { if v.text != text { v.text = text } }
}
#elseif os(macOS)
struct SelectableText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let s = NSTextView.scrollableTextView()
        if let v = s.documentView as? NSTextView {
            v.isEditable = false; v.isSelectable = true
            v.font = NSFont(descriptor: NSFont.preferredFont(forTextStyle: .title3).fontDescriptor.withDesign(.serif) ?? NSFont.preferredFont(forTextStyle: .title3).fontDescriptor, size: 0)
            v.textContainerInset = NSSize(width: 16, height: 20)
        }
        return s
    }
    func updateNSView(_ s: NSScrollView, context: Context) {
        if let v = s.documentView as? NSTextView, v.string != text { v.string = text }
    }
}
#endif
