// Derived from Spec: FEAT-10 · runs TranslatePlan against the playing transcript, on device (RecenseText.translate).
import Foundation
import ShowsKit

@MainActor final class PlaybackTranslator {
    static let shared = PlaybackTranslator()
    @ObservationIgnored private var kept: [String: String] = [:]      // TranslatePlan.key(target, text) → translation
    @ObservationIgnored private var inFlight = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Call after the transcript changes, and after the owner changes Translate Into (ShowsModel.translateInto,
    /// which keeps itself on this device). `lang`: the file's own language (Listen's "Hear in"), the fallback for
    /// very short lines TranslatePlan.detect can't place on its own.
    func run(_ model: ShowsModel, lang: String) {
        task?.cancel()
        // T-0100: every run is a new generation, even one with no jobs, so a job still running from an older plan
        // (RecenseText.translate ignores cancel) can't write its translations after this plan cleared them
        let gen = inFlight + 1; inFlight = gen
        let choice = model.translateInto
        let lines = model.transcript.map { (id: $0.id, text: $0.text) }
        let p = TranslatePlan.plan(lines, choice: choice, kept: kept) { TranslatePlan.detect($0, fallback: lang) }
        apply(p.fills, to: model)
        guard !p.jobs.isEmpty else { return }
        task = Task { [weak model] in
            for job in p.jobs {
                guard let out = await RecenseText.translate(job.texts, from: job.source, to: job.target) else {
                    await MainActor.run { [weak model] in
                        guard let model, self.inFlight == gen else { return }
                        model.transcriptNote = TranslatePlan.missing(job.source, job.target)
                    }
                    continue
                }
                await MainActor.run { [weak model] in
                    guard let model, self.inFlight == gen else { return }
                    for i in job.ids.indices where i < out.count {
                        let (id, source, text) = (job.ids[i], job.texts[i], out[i])
                        self.kept[TranslatePlan.key(job.target, source)] = text
                        if let row = model.transcript.firstIndex(where: { $0.id == id }) { model.transcript[row].translation = text }
                    }
                }
            }
        }
    }

    private func apply(_ fills: [String: String?], to model: ShowsModel) {
        for (id, t) in fills {
            guard let i = model.transcript.firstIndex(where: { $0.id == id }) else { continue }
            model.transcript[i].translation = t
        }
    }
}
