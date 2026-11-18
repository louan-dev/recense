# BUG-32 · Draftpad reads French â ê ô as Vietnamese, and decomposed text as English

From: T-0029 (owner 2026-11-12: "broken autodetect language. recense iphone, ipad, mac"), PLAN-1118 §3 "Translation + languages" ·
Guards: FEAT-08 (a passage's `lang`), law/languages (en · fr · vi) ·
Status: `[x]` (editor; every host loads `editor/dist/editor.html`)

## Evidence
- `guessLang` (`editor/src/matter.js`) tested â ê ô as Vietnamese first: `fête`, `château`, `hôtel`, `forêt` → `vi`.
  French writes â ê ô too; only ă đ ơ ư, the tone marks (dot below, hook above, tilde) and the acute/grave on a i o u y
  are Vietnamese alone.
- It never composed its input: a file name or a pasted text from the file system comes decomposed (NFD,
  `e` + U+0302), so `cảm ơn` in NFD matched neither list → `en`. Same family as T-0146 (Swift cache paths, NFD bytes).
- Red: `editor/test/bug-guesslang-vi-fr.test.mjs`, 2 of 4 failing (`'vi' !== 'fr'`, `'en' !== 'vi'`).

## Invariants (each has a test marked `// Regression guard: BUG-32`)
1. Input is composed (`normalize('NFC')`) before any test: NFD and NFC read the same.
2. Vietnamese only on a letter French never writes: ă đ ơ ư; ạ ả ã ẹ ẻ ẽ ỉ ị ĩ ọ ỏ õ ụ ủ ũ ỳ ỵ ỷ ỹ; ấ ầ ẩ ẫ ậ ắ ằ ẳ ẵ ặ
   ế ề ể ễ ệ ố ồ ổ ỗ ộ ớ ờ ở ỡ ợ ứ ừ ử ữ ự; á í ó ú ý ì ò.
2b. Vietnamese also on a whole word with no tone mark that French never writes: và · không · tôi · ông · bà · cô ·
   bên · lên · tên · nên (`Tôi là sinh viên`, `Không`, `Bên kia`; `là` is left out: French writes it). Review fix 11-18:
   without it these read French, a regression on main.
3. French on é è ê ë à â ç ù û ü ô î ï œ æ ÿ, or on le · la · les · des · est · une · du · et.
4. Else English. Three languages only: a Spanish `está` reads Vietnamese (no Spanish target exists).
Test: `editor/test/bug-guesslang-vi-fr.test.mjs`.

## Propagation
- Swift line language is `NLLanguageRecognizer` (`shared/translateplan.swift`), not this rule: unaffected.
- T-0146 (NFD cache keys) is the same class in Swift; it stays its own entry.
