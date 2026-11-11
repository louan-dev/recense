// The floating window's picture, moved out of Listen.swift (11-10) so mobile/ios/Tests/floatingcaption renders it on
// the Mac: SwiftUI and ShowsKit only.
import SwiftUI
import ShowsKit

/// The floating window's picture (Listener.draw() renders it): the transcript's own line look, left-aligned, newest at
/// the bottom, whole lines only (the sentence before shows when it fits with the current one).
struct FloatingCaption: View {
    struct Row {
        var line: TranscriptLine
        var on: Bool
        var t: Double?
        var alpha = 1.0
        var said: String? = nil   // Learn: the translation it dissolves into
        var turned = 0.0
        /// how much of the line is lit, so a frame is drawn again when the light moves
        var cut: Int { guard on, let t else { return -1 }; return line.text.distance(from: line.text.startIndex, to: TranscriptLight.spoken(line, at: t)) }
        /// The same row without its light: what it shows apart from how far it's been said.
        var unlit: Row { var r = self; r.t = nil; return r }
    }
    let rows: [Row]
    let learn: Bool
    let note: String?

    var body: some View {
        ZStack {
            Color(white: 0.04)
            if let note {
                Text(note).font(.system(.title2, design: .serif)).foregroundStyle(.white.opacity(0.6)).padding(18)
            } else if learn {
                VStack(spacing: 10) {
                    ForEach(rows.indices, id: \.self) { i in
                        let r = rows[i]
                        ZStack(alignment: .topLeading) {
                            TranscriptLineText(r.line, on: r.on, at: r.t, translation: false).opacity(r.alpha * (1 - r.turned))
                            if let said = r.said, r.turned > 0 {
                                TranscriptLineText(TranscriptLine(id: r.line.id + ".said", start: 0, end: 0, text: said), on: true, at: nil, translation: false)
                                    .opacity(r.alpha * r.turned)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            } else {
                // whole lines only: the sentence before shows when it fits with the current one, else the current one alone
                // (11-10: the older line was cut through at the top). Only a current line taller than the window still fades.
                ViewThatFits(in: .vertical) {
                    lines(rows)
                    lines(Array(rows.suffix(1)))
                    // a current line taller than the window: its newest words stay at the bottom, its start fades at the top
                    // (laid out at its full height, it was centred and cut at both ends)
                    Color.clear
                        .overlay(alignment: .bottomLeading) { lines(Array(rows.suffix(1))) }
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22)], startPoint: .top, endPoint: .bottom))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .clipped()
    }

    private func lines(_ rs: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rs.indices, id: \.self) { i in
                TranscriptLineText(rs[i].line, on: rs[i].on, at: rs[i].t).opacity(rs[i].alpha).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}
