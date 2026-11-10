// Home's "Listening" card (owner 11-09: Listen belongs on Home, not tucked under Library). One look at what Listen
// is doing: which ear hears and in which language, the line being heard now in the transcript's own look (ShowsKit
// TranscriptLineText, as Read along and the floating window), and the one Pause. Tapping the card opens Listen.
import SwiftUI
import ShowsKit

struct ListeningCard: View {
    @ObservedObject var l = Listener.shared

    /// One line: what hears, in what.
    private var status: String {
        if l.paused { return "Paused" }
        switch l.ear {
        case .broadcast: return "Listening · \(Listener.name(l.lang))"
        case .mic: return "Listening through the microphone · \(Listener.name(l.lang))"
        case .none: return l.prompting ? "Not hearing · tap once to keep hearing" : "Not hearing"
        }
    }
    private var symbol: String { l.paused ? "pause.circle.fill" : l.hearing ? "waveform" : "ear.trianglebadge.exclamationmark" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Listening").font(.title2.bold()).padding(.horizontal, Theme.gutter)  // one way in: the card itself
            VStack(alignment: .leading, spacing: 14) {
                NavigationLink { ListenView() } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(status, systemImage: symbol).font(.headline).foregroundStyle(l.hearing ? Theme.accent : .secondary)
                        line
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Listen")
                Button { l.paused ? l.resume() : l.pause() } label: {
                    Label(l.paused ? "Resume" : "Pause", systemImage: l.paused ? "play.fill" : "pause.fill")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            }
            .padding(16)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.artCorner, style: .continuous))
            .padding(.horizontal, Theme.gutter)
        }
    }

    /// The sentence being heard, lit as it's said, its translation under it; the light moves only while hearing.
    @ViewBuilder private var line: some View {
        if let e = l.episode, e.place < e.sentences.count {
            let s = e.sentences[e.place]
            let tl = TranscriptLine(id: s.id, start: s.time, end: s.time, text: s.heard, words: s.words ?? [],
                                    translation: s.said.isEmpty || s.said == s.heard ? nil : s.said)
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                TranscriptLineText(tl, on: true, at: l.hearing ? Date().timeIntervalSince1970 - l.lag : nil)
                    .lineLimit(6)
            }
        } else {
            Text(l.hearing ? "Nothing heard yet. Play something in any app." : "Lines heard appear here.")
                .font(.system(.title3, design: .serif)).foregroundStyle(.secondary)
        }
    }
}
