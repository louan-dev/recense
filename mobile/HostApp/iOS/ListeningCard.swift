// Home's "Now Playing" (renamed from "Listening", owner 11-10) (owner 11-10: "the transcript of what's currently playing on the home"; Listen is not tucked
// away in Library). What hears and in which language, the transcript of what plays (the same view Listen and Now
// Playing use, lit as it's said), and the one Pause. "Now Playing ›" opens Listen, as "Up Next ›" opens its list.
// The floating window's layer sits behind the transcript: leaving Recense from Home while something plays turns it
// into the window (PiP starts only from a layer on screen).
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
        case .none: return l.prompting ? "Not hearing · open Now Playing to keep hearing" : "Not hearing"
        }
    }
    private var symbol: String { l.paused ? "pause.circle.fill" : l.hearing ? "waveform" : "ear.trianglebadge.exclamationmark" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Now Playing") { ListenView() }   // a view link, as every way into Listen
            VStack(alignment: .leading, spacing: 14) {
                Label(status, systemImage: symbol).font(.headline).foregroundStyle(l.hearing ? Theme.accent : .secondary)
                ZStack {
                    CaptionLayer()
                    ListenView.transcript(l, l.sentences, place: l.episode?.place, title: l.episode?.title ?? "Now Playing", live: true)
                }
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button { l.paused ? l.resume() : l.pause() } label: {
                    Label(l.paused ? "Resume listening" : "Pause listening", systemImage: l.paused ? "play.fill" : "pause.fill")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .disabled(l.stopping)
            }
            .padding(16)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.artCorner, style: .continuous))
            .padding(.horizontal, Theme.gutter)
        }
    }
}
