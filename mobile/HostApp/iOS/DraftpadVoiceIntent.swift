// Derived from Spec: FEAT-08 (P2, voice continuation while moving). "Add to Draftpad": say a passage from Siri, the
// Shortcuts app or the Action button (Settings › Action Button › Shortcut › Recense › Add to Draftpad) and it lands at
// the end of draftpad.md as its own passage, seeded as voice, without opening the app. The words go through
// VoiceAppend (shared/voiceappend.swift): planBlindSave, and the Unsaved folder when the note can't be read now.
#if GUEST
// Recense Guest has no Draftpad of its own.
#else
import AppIntents
import UIKit

struct AddToDraftpadIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Draftpad"
    static var description = IntentDescription("Adds what you say to the end of Draftpad, as its own passage, without opening the app.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Words", requestValueDialog: "What should Draftpad keep?")
    var words: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let file = DraftpadFile()
        guard let vault = file.vault else { return .result(dialog: "Open Draftpad once and choose its folder first.") }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        switch VoiceAppend.append(words, vault: vault, device: device, unsavedDir: DraftpadFile.unsavedFolder) {
        case .added: return .result(dialog: "Added to Draftpad.")
        case .kept: return .result(dialog: "Kept. It joins Draftpad when the note can be read.")
        case .nothing: return .result(dialog: "Nothing to add.")
        }
    }
}
#endif
