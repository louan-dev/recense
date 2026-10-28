// Prosody: the language layer the brush × filament variants share. Once per clip it reads every word's letters and
// the measured voice (Recense Features + the harness signals) and fuses them into one precomputed line per word, so
// every variant draws the same facts and only differs in how it draws them:
//   height    = inflection: measured pitch, normalised as Pataca & Costa do (mean of a whole-clip and a 15-syllable
//               min-max), drawn toward the textbook shape of the Vietnamese tone or the French intonation event
//   weight    = loudness (vowels only), same normalisation, shaped by the frame envelope
//   gaps      = articulation: plosive onsets, checked/glottal tones, staccato and pauses lift the line; legato,
//               liaison, enchaînement and elision keep it joined
//   nodes     = the inflection points, at the exact glyph of the accented (tone-bearing) vowel or the stressed syllable
//   links     = French liaisons / enchaînements / elisions, between the exact two letters, with the sound
//   breaths   = pauses, with their length
// Nothing here is random and nothing depends on the frame: a variant only reveals what is already decided.
//
//   const P = Prosody.analyze(data, { at, progress, words, measure? })   (the harness calls this and passes f.pro)
//   P.word[w.flat] -> { syl[], pts{u,h,w,cut,n}, nodes[], link, inner[], breathAfter, phraseEnd, ... }   see bottom
(() => {
  const clamp = (x, a = 0, b = 1) => x < a ? a : x > b ? b : x
  const lerp = (a, b, f) => a + (b - a) * f
  const pctl = (a, q) => { if (!a.length) return 0; const s = Float64Array.from(a).sort(); return s[Math.min(s.length - 1, Math.floor(s.length * q))] }

  // ---- letters -------------------------------------------------------------------------------------------------
  const VOW = new Set('aàâäeéèêëiîïoôöuùûüyÿæœ')
  const base = ch => ch.normalize('NFD')[0].toLowerCase()
  const isVowelVi = ch => 'aeiouy'.includes(base(ch))
  const isLetter = ch => /\p{L}/u.test(ch)
  /** the word's body: [i0, i1) without leading/trailing punctuation (apostrophes and hyphens inside stay) */
  function core(text) {
    const ch = [...text]; let a = 0, b = ch.length
    while (a < b && !isLetter(ch[a]) && !/\d/.test(ch[a])) a++
    while (b > a && !isLetter(ch[b - 1]) && !/\d/.test(ch[b - 1])) b--
    return [a, b]
  }
  const trail = text => { const [, b] = core(text); return [...text].slice(b).join('') }
  const bare = text => { const [a, b] = core(text); return [...text].slice(a, b).join('').toLowerCase() }

  // ---- Vietnamese: six tones, Northern norm (Chao: ngang 33, huyền 21, sắc 35, hỏi 313, ngã 3ʔ5, nặng 21ʔ) --------
  // Values are pitch in the speaker's range, −1 low … +1 high; τ is time through the syllable, its tone lives at τ = 0.5,
  // which is drawn under the tone-bearing vowel. sharp: how detached (pointy) the tone is; glottal: τ of a glottal break.
  const TONE_MARK = { '̀': 'huyen', '́': 'sac', '̃': 'nga', '̉': 'hoi', '̣': 'nang' }
  const VI_TONE = {
    ngang:   { pts: [[0, .18], [1, .12]], sharp: 0, soft: 0, glottal: -1, label: 'ngang · level' },
    huyen:   { pts: [[0, -.1], [1, -.62]], sharp: 0, soft: .45, glottal: -1, label: 'huyền · low falling, breathy' },
    sac:     { pts: [[0, -.02], [.45, .18], [1, .9]], sharp: .35, soft: 0, glottal: -1, label: 'sắc · high rising' },
    sacK:    { pts: [[0, .38], [1, .95]], sharp: .8, soft: 0, glottal: 1, label: 'sắc (checked) · short high, stopped' },
    hoi:     { pts: [[0, -.05], [.55, -.72], [1, -.12]], sharp: .1, soft: .2, glottal: -1, label: 'hỏi · dipping' },
    nga:     { pts: [[0, 0], [.42, .22], [.5, .12], [.58, .42], [1, 1]], sharp: .55, soft: 0, glottal: .5, label: 'ngã · rising, broken' },
    nang:    { pts: [[0, -.22], [.8, -.85], [1, -.92]], sharp: .7, soft: .15, glottal: .9, label: 'nặng · low, falling, cut' },
    nangK:   { pts: [[0, -.3], [1, -.9]], sharp: .85, soft: .1, glottal: 1, label: 'nặng (checked) · short low, stopped' },
  }
  function viSyllable(text) {
    const [a, b] = core(text), ch = [...text]
    let tone = 'ngang', mark = -1
    for (let i = a; i < b; i++) for (const m of ch[i].normalize('NFD')) if (TONE_MARK[m]) { tone = TONE_MARK[m]; mark = i }
    const plain = ch.slice(a, b).map(c => c.normalize('NFD').replace(/[̣̀́̃̉]/g, '').normalize('NFC').toLowerCase()).join('')
    const checked = /(p|t|c|ch)$/.test(plain)
    let nucleus = mark
    if (nucleus < 0) {                        // no tone mark: the main vowel, by the placement rule
      let i = 0; const L = [...plain]
      if (/^gi[aeiouyăâêôơư]/.test(plain) || /^qu/.test(plain)) i = 2
      while (i < L.length && !'aeiouyăâêôơư'.includes(L[i])) i++
      let j = i; while (j < L.length && 'aeiouyăâêôơư'.includes(L[j])) j++
      const cl = L.slice(i, j).join(''), closed = j < L.length
      let k = 0
      const q = [...cl].findIndex((c, n) => 'ăâêôơư'.includes(c) && !(c === 'ư' && cl[n + 1] === 'ơ'))
      if (q >= 0) k = q
      else if (cl.length === 1) k = 0
      else if (closed) k = cl.length - 1
      else if (cl.length === 3) k = 1
      else k = /^(oa|oe|uy|uê|ua(?=$))/.test(cl) && cl !== 'ua' ? 1 : 0
      nucleus = i < L.length ? a + i + Math.min(k, Math.max(0, cl.length - 1)) : a + Math.floor((b - a) / 2)
    }
    const key = checked && tone === 'sac' ? 'sacK' : checked && tone === 'nang' ? 'nangK' : tone
    return { c0: a, c1: b, nucleus, tone, key, checked, onset: viOnsetSharp(plain) }
  }
  function viOnsetSharp(p) {                  // a stop at the start lifts the line a little (bow détaché)
    if (/^(tr|ch|th|t|c|k|q|p|b|đ)/.test(p)) return /^(b|đ)/.test(p) ? .25 : .4
    if (/^(ph|x|s|kh|h|g|gh|gi|d|r|v)/.test(p)) return .1
    return 0
  }

  // ---- French ----------------------------------------------------------------------------------------------------
  const H_ASPIRE = /^(hache|hach|haie|haine|haï|hair|hall|halte|halo|hamac|hameau|hamster|hamburger|hanche|hand|hangar|hant|happ|harc|hardi|hareng|haricot|harem|harnais|harp|hasard|hâte|hâti|hauss|haut|havre|henn|hériss|hernie|héron|héros|hêtre|heurt|hibou|hideu|hiérarch|hippie|hiss|hobby|hockey|hold|hollande|holland|homard|hongr|honte|honteu|hooligan|hoquet|horde|hors|hot|hotte|houill|houle|houpp|hourra|housse|houx|hublot|huche|hue|huer|hu[eé]e|huit|hulul|humer|hurl|hutte)/
  const NO_LIAISON_BEFORE = new Set(['oui', 'onze', 'onzième', 'huit', 'huitième', 'yaourt', 'yoga', 'yacht', 'yéti', 'ouistiti', 'ouah', 'uhlan'])
  const ACRO_VOWEL = 'AEFHILMNORSUX'          // letters whose French names begin with a vowel (H: ache, a vowel, but h aspiré by usage: kept)
  const DET = new Set(['les', 'des', 'ces', 'mes', 'tes', 'ses', 'nos', 'vos', 'leurs', 'aux', 'un', 'aucun', 'quelques', 'plusieurs',
    'certains', 'certaines', 'quels', 'quelles', 'tous', 'toutes', 'deux', 'trois', 'six', 'dix', 'vingt', 'cent', 'mon', 'ton', 'son',
    'chaque', 'divers', 'diverses', 'différents', 'différentes', 'nombreux', 'nombreuses', 'autres', 'mêmes', 'quelqu', 'aucuns', 'ses'])
  const PRON = new Set(['nous', 'vous', 'ils', 'elles', 'on', 'en', 'les', 'leur', 'eux', 'chez'])
  const ADV_PREP = new Set(['en', 'dans', 'chez', 'sans', 'sous', 'très', 'plus', 'moins', 'bien', 'rien', 'tout', 'quand', 'dont', 'trop', 'pas', 'mais', 'jamais', 'toujours', 'assez', 'beaucoup', 'après', 'depuis', 'avant', 'pendant'])
  const ADV_OBLIG = new Set(['en', 'dans', 'chez', 'sans', 'sous', 'très', 'plus', 'moins', 'bien', 'rien', 'tout', 'quand'])
  const ADJ_PRENOM = new Set(['grand', 'grands', 'grandes', 'petit', 'petits', 'petites', 'gros', 'bon', 'bons', 'bonnes', 'mauvais', 'ancien', 'anciens',
    'premier', 'premiers', 'dernier', 'derniers', 'léger', 'beau', 'beaux', 'bel', 'nouvel', 'nouveaux', 'vieil', 'vieux', 'jeunes', 'faux', 'vrais',
    'long', 'longs', 'hauts', 'seul', 'seuls', 'certain', 'plein', 'moyen', 'prochain', 'prochains', 'vrai', 'chers', 'meilleurs', 'pires', 'doux', 'heureux'])
  const VERB_LIAISON = new Set(['est', 'sont', 'ont', 'était', 'étaient', 'avait', 'avaient', 'font', 'vont', 'peut', 'peuvent', 'doit', 'doivent', 'faut', 'suis',
    'es', 'êtes', 'sommes', 'avons', 'avez', 'allons', 'allez', 'aient', 'soient', 'fut', 'serait', 'seraient', 'aurait', 'pourrait', 'veut', 'veulent', 'sait', 'dit', 'fait'])
  const FREQUENT = new Set(["c'est", 'c’est', 'est', 'ont', 'sont', 'pas', 'étaient', 'allez', 'avons'])   // optional liaisons speakers usually make
  const FUNC = new Set(['le', 'la', 'les', "l'", 'un', 'une', 'des', 'du', 'de', "d'", 'au', 'aux', 'ce', 'cet', 'cette', 'ces', 'mon', 'ma', 'mes', 'ton', 'ta',
    'tes', 'son', 'sa', 'ses', 'notre', 'nos', 'votre', 'vos', 'leur', 'leurs', 'je', "j'", 'tu', 'il', 'elle', 'on', 'nous', 'vous', 'ils', 'elles', 'me', "m'",
    'te', "t'", 'se', "s'", 'y', 'ne', "n'", 'que', "qu'", 'qui', 'dont', 'où', 'et', 'ou', 'mais', 'donc', 'or', 'ni', 'car', 'à', 'dans', 'par', 'pour',
    'sur', 'sous', 'avec', 'sans', 'chez', 'vers', 'en', 'entre', 'comme', 'si', 'quand', 'lorsque', 'puisque', 'parce'])
  const WH = new Set(['qui', 'quoi', 'où', 'quand', 'comment', 'pourquoi', 'combien', 'quel', 'quelle', 'quels', 'quelles', 'lequel', 'laquelle', 'lesquels', 'que', "qu'"])
  const ENT_PRONOUNCED = /(ment|ments)$|^(souvent|parent|parents|argent|cent|cents|dent|dents|vent|vents|client|clients|patient|patients|président|présidents|accident|accidents|différent|différents|récent|récents|talent|talents|urgent|évident|absent|absents|content|contents|lent|lents|comment|serpent|agent|agents|adolescent|adolescents|innocent|innocents|silent|équivalent|régent|torrent|continent|continents|incident|incidents|événement|ent|dent)$/
  const R_PRONOUNCED = /^(hier|fier|cher|mer|fer|ver|hiver|enfer|super|amer|cancer|laser|hamster|reporter|cuiller|leader|poster|master|bar|car|par|pour|sur|leur|leurs|soir|noir|or|cœur|sœur|peur|fleur|mur|dur|pur|air|clair|faire|jour|tour|amour|four|cour)$/
  const isVow = c => VOW.has(c)
  /** French syllables over the word's letters: vowel groups (u after q/g is part of the onset; tréma and é+V split),
   *  consonants between groups split VC.CV (keeping obstruent+liquid and digraphs as onsets), mute e folded into
   *  the syllable before it as a soft tail. */
  function frSyllables(text) {
    const [a, b] = core(text), ch = [...text].map(c => c.toLowerCase()), w = bare(text)
    const groups = []                         // [g0, g1) over char indices
    let i = a
    while (i < b) {
      if (!isVow(ch[i]) || (ch[i] === 'u' && i > a && (ch[i - 1] === 'q' || (ch[i - 1] === 'g' && 'eéèêiîy'.includes(ch[i + 1] || ''))))) { i++; continue }
      let j = i + 1
      const silentE = k => ch[k] === 'e' && (k + 1 === b || (ch[k + 1] === 's' && k + 2 === b))      // the -e/-es of -ée(s), -ie(s)…
      while (j < b && isVow(ch[j]) && !'ëïü'.includes(ch[j]) && !(ch[j - 1] === 'é' && !silentE(j)) && !(ch[j - 1] === 'y' && j - 1 > i)) j++
      groups.push([i, j]); i = j
    }
    if (!groups.length) return { syl: [{ c0: a, c1: b, nucleus: a, schwa: 0, mute: -1, accent: null, onset: 0, coda: 0 }], silentEnt: false }
    // mute e: a final bare "e"/"es" (and a 3rd-person "-ent") after another syllable; e in le/de/que… is a schwa
    let silentEnt = false
    const last = groups[groups.length - 1], lastV = ch.slice(last[0], last[1]).join(''), after = ch.slice(last[1], b).join('')
    let muteFrom = -1
    if (groups.length > 1 && lastV === 'e' && (after === '' || after === 's')) muteFrom = last[0]
    else if (groups.length > 1 && lastV === 'e' && after === 'nt' && !ENT_PRONOUNCED.test(w)) { muteFrom = last[0]; silentEnt = true }
    else if (groups.length > 1 && /e$|es$/.test(lastV) && lastV.length > 1 && (after === '' || after === 's')) muteFrom = last[0] + lastV.length - 1 // "-ée", "-ie", "-ue"
    if (muteFrom >= 0 && muteFrom === last[0]) groups.pop()
    const mono = groups.length === 1 && /^(le|de|que|qu|ce|je|me|te|se|ne|j|l|d|m|t|s|n|c)$/.test(w.replace(/['’].*$/, ''))
    // split points between groups
    const ONSET2 = /^(pl|pr|bl|br|tr|dr|cr|cl|gr|gl|fr|fl|vr|ch|ph|th|gn|qu|gu)$/
    const syl = []
    let start = a
    for (let g = 0; g < groups.length; g++) {
      const [g0, g1] = groups[g]
      let end = b
      if (g + 1 < groups.length) {
        const n0 = groups[g + 1][0], run = ch.slice(g1, n0).join('').replace(/[-'’]/g, '')
        if (run.length === 0) end = g1
        else if (run.length === 1) end = n0 - 1
        else end = ONSET2.test(ch.slice(n0 - 2, n0).join('')) ? n0 - 2 : n0 - 1
      }
      const v = ch.slice(g0, g1).join('')
      // which vowel letter the inflection sits on: an accented letter, else the group's last full vowel (eau → a? no: e)
      let nucleus = g0
      for (let k = g0; k < g1; k++) if ('éèêëàâîïôöûùü'.includes(ch[k])) { nucleus = k; break }
      if (nucleus === g0 && g1 - g0 > 1) nucleus = /^(ou|au|eau|eu|œu|ai|ei|oi)/.test(v) ? g0 + Math.floor((g1 - g0 - 1) / 2) : g1 - 1
      const accent = /é/.test(v) || (g === groups.length - 1 && /^(er|ez|et)$/.test(ch.slice(g0, b).join('')) && v === 'e') ? 'aigu'
        : /[èà]/.test(v) ? (/è/.test(v) ? 'grave' : 'grave-gram') : /[êâîôû]/.test(v) ? 'circ' : /[ëïü]/.test(v) ? 'trema' : null
      const on = ch.slice(start, g0).join('').replace(/[-'’]/g, '')
      syl.push({ c0: start, c1: end, nucleus, accent, schwa: mono && v === 'e' ? .6 : 0, mute: -1, onset: frOnsetSharp(on, w, start === a), coda: 0, trema: /[ëïü]/.test(ch[g0]) })
      start = end
    }
    const ls = syl[syl.length - 1]
    ls.c1 = b
    if (muteFrom >= 0) ls.mute = muteFrom
    // a pronounced final stop (avec, sept, net, chef…) detaches what follows
    const coda = muteFrom >= 0 ? '' : ch.slice(groups[groups.length - 1][1], b).join('')
    if (/^(c|k|q|p|t|ct|pt|b|d|g|f|ff)$/.test(coda) && /^(avec|sec|bac|sac|lac|choc|truc|parc|sept|huit|net|but|chef|neuf|soif|vif|sud|zinc|stop|cap|club|gag|bus|sens|fils|ours|os|mars)$/.test(w)) ls.coda = .4
    return { syl, silentEnt, schwaWord: mono }
  }
  function frOnsetSharp(on, w, first) {
    if (!on) return 0
    if (first && on[0] === 'h' && !H_ASPIRE.test(w)) on = on.slice(1)
    if (!on) return 0
    const c = on[0]
    if ('ptk'.includes(c) || (c === 'c' && !'eiéèêy'.includes(on[1] || 'a')) || c === 'q') return .45
    if ('bdg'.includes(c) && !(c === 'g' && 'eiy'.includes(on[1] || ''))) return .3
    if ('fsxzvjç'.includes(c) || c === 'c' || c === 'g' || on.startsWith('ch')) return .12
    return 0
  }
  /** the first vowel letter that starts w2's sound (skipping a mute h), or -1 when w2 starts with a consonant sound */
  function frVowelStart(text) {
    const [a, b] = core(text), ch = [...text], w = bare(text)
    if (a >= b) return -1
    const raw = [...text].slice(a, b).join('')
    if (/^[A-Z]{2,}$/.test(raw.replace(/[-.]/g, ''))) return ACRO_VOWEL.includes(raw[0]) && raw[0] !== 'H' ? a : -1
    if (NO_LIAISON_BEFORE.has(w)) return -1
    const c = ch[a].toLowerCase()
    if (c === 'h') return H_ASPIRE.test(w) ? -1 : (isVow(ch[a + 1]?.toLowerCase()) ? a + 1 : -1)
    if (c === 'y') return (w === 'y' || /^y[^aeiouéèêô]/.test(w) || /^yeu/.test(w)) ? a : -1     // y (pronoun), yeux are vowels; yaourt, yoga aren't
    return isVow(c) ? a : -1
  }
  const SOUND = { s: 'z', x: 'z', z: 'z', t: 't', d: 't', n: 'n', r: 'ʁ', p: 'p', f: 'v', g: 'k' }
  /** the link from word w1 to w2: liaison (a latent consonant sounded), enchaînement (a pronounced one resyllabified), or null */
  function frLink(t1, t2, prevBare) {
    if (/[.,;:!?…»)\]]/.test(trail(t1)) || /^[«(“"\[]/.test(t2)) return null
    const to = frVowelStart(t2); if (to < 0) return null
    const [a1, b1] = core(t1), ch = [...t1], low = ch.map(c => c.toLowerCase()), w = bare(t1)
    const parts = w.split('-'), head = parts[parts.length - 1]
    const last = low[b1 - 1]
    if (w === 'et') return null                                                   // never after "et"
    if (prevBare !== null && /^[A-ZÀ-Ý][a-zà-ÿ]/.test([...t1].slice(a1).join('')) && !FUNC.has(w) && !DET.has(w)) return null   // a name mid-sentence
    if (parts.length > 1 && /^(ils|elles|il|elle|on|nous|vous|je|tu)$/.test(head)) return null   // inverted subject: no liaison after "vont-ils"
    const g2 = bare(t2)
    // liaison: a latent consonant letter at the end
    if (SOUND[last] && !(last === 'r' && R_PRONOUNCED.test(head)) && !(last === 'f' && head !== 'neuf') && !(last === 'g' && !/^(sang|long|rang)$/.test(head))) {
      let status = null
      if (last === 'f') status = /^(ans|heures|hommes)$/.test(g2) ? 'obligatory' : null
      else if (DET.has(head) || PRON.has(head) || ADJ_PRENOM.has(head) || ADV_OBLIG.has(head)) status = 'obligatory'
      else if (/^(c'est|c’est)$/.test(w)) status = 'optional'
      else if (w === 'comment' && /^allez/.test(g2)) status = 'obligatory'
      else if (VERB_LIAISON.has(head) || /ent$/.test(head) && !ENT_PRONOUNCED.test(head) || ADV_PREP.has(head)) status = 'optional'
      else if (/[sx]$/.test(head) && head.length > 2) status = 'optional'               // a plural noun or adjective before a vowel
      if (head === 'les' && prevBare !== null && /^(tous|toutes)$/.test(prevBare)) status = 'obligatory'
      if (status) {
        let from = b1 - 1
        const sound = SOUND[last]
        const prior = status === 'obligatory' ? 1 : FREQUENT.has(w) || FREQUENT.has(head) ? .8 : /[sx]$/.test(head) ? .4 : .5
        return { kind: 'liaison', sound, from, to, status, prior, denasal: sound === 'n' && /(ien|on|bon|ancien|moyen|certain|plein|prochain)$/.test(head) && !/^(un|aucun|on|en|bien|rien|mon|ton|son)$/.test(head) }
      }
      if (last !== 'r' && last !== 'c' && last !== 'l' && last !== 'f') return null     // a silent latent consonant, no liaison here
    }
    // enchaînement: the word ends in a sounded consonant (…C + mute e, or a sounded c/r/f/l/q/k), it moves onto w2's vowel
    let from = -1, sound = null
    if (low[b1 - 1] === 'e' && b1 - 2 >= a1 && !isVow(low[b1 - 2])) {
      from = b1 - 2
      const c = low[from], prev = low[from - 1]
      sound = c === 'c' ? 's' : c === 'g' ? (prev === 'g' ? 'g' : 'ʒ') : c === 'r' ? 'ʁ' : c === 'n' && prev === 'g' ? 'ɲ' : c === 'h' && prev === 'c' ? 'ʃ' : c === 'u' && prev === 'q' ? 'k' : c === 's' && !isVow(prev) ? 's' : c === 's' && prev !== 's' ? 'z' : c
    } else if ('crflqk'.includes(last) && (last !== 'r' || R_PRONOUNCED.test(head) || head.length <= 3 && head !== 'les')) {
      from = b1 - 1; sound = last === 'r' ? 'ʁ' : last === 'c' || last === 'q' ? 'k' : last
    }
    if (from < 0) return null
    return { kind: 'enchainement', sound, from, to, status: 'enchainement', prior: .9, denasal: false }
  }
  /** apostrophes (elision) and hyphens with a latent consonant (allez-y, a-t-il) inside one written word */
  function frInner(text) {
    const ch = [...text], out = []
    for (let i = 1; i < ch.length - 1; i++) {
      if ((ch[i] === "'" || ch[i] === '’') && isLetter(ch[i - 1]) && isLetter(ch[i + 1])) out.push({ kind: 'elision', from: i - 1, to: i + 1, sound: base(ch[i - 1]) === 'u' && base(ch[i - 2] || '') === 'q' ? 'k' : base(ch[i - 1]) })
      if (ch[i] === '-' && isLetter(ch[i - 1]) && isVow((ch[i + 1] || '').toLowerCase())) {
        const c = ch[i - 1].toLowerCase()
        if ('sxztd'.includes(c)) out.push({ kind: 'liaison', from: i - 1, to: i + 1, sound: SOUND[c], status: 'obligatory', prior: 1 })
      }
    }
    return out
  }

  // ---- generic (any language): vowel groups as syllables --------------------------------------------------------
  function genSyllables(text) {
    const [a, b] = core(text), ch = [...text].map(c => base(c))
    const syl = []; let i = a, start = a
    const isV = c => 'aeiouy'.includes(c)
    const groups = []
    while (i < b) { if (!isV(ch[i])) { i++; continue } let j = i + 1; while (j < b && isV(ch[j])) j++; groups.push([i, j]); i = j }
    if (!groups.length) return [{ c0: a, c1: b, nucleus: a, accent: null, schwa: 0, mute: -1, onset: 0, coda: 0 }]
    for (let g = 0; g < groups.length; g++) {
      const end = g + 1 < groups.length ? Math.max(groups[g][1], groups[g + 1][0] - 1) : b
      let nucleus = groups[g][0]
      for (let k = groups[g][0]; k < groups[g][1]; k++) if ([...text][k].normalize('NFD').length > 1) nucleus = k
      syl.push({ c0: start, c1: end, nucleus, accent: [...text][nucleus].normalize('NFD').length > 1 ? 'mark' : null, schwa: 0, mute: -1, onset: 0, coda: 0 })
      start = end
    }
    syl[syl.length - 1].c1 = b
    return syl
  }

  // ---- shape helpers ---------------------------------------------------------------------------------------------
  function shapeAt(pts, x) {                 // piecewise-linear through [[τ, v]], smoothed with a cosine ease
    if (x <= pts[0][0]) return pts[0][1]
    for (let i = 1; i < pts.length; i++) if (x <= pts[i][0]) {
      const [x0, y0] = pts[i - 1], [x1, y1] = pts[i], f = (x - x0) / Math.max(1e-6, x1 - x0)
      return y0 + (y1 - y0) * (0.5 - 0.5 * Math.cos(Math.PI * f))
    }
    return pts[pts.length - 1][1]
  }
  // French intonation events on the stressed (last full) syllable of a rhythmic group, relative to where it starts
  const FR_EVENT = {
    minor:       { pts: [[0, 0], [1, .38]], label: 'continuation (minor rise)' },
    continuation:{ pts: [[0, 0], [1, .7]], label: 'continuation (major rise, before a comma)' },
    final:       { pts: [[0, 0], [.3, .05], [1, -.75]], label: 'final fall (statement)' },
    question:    { pts: [[0, 0], [1, .95]], label: 'yes/no question (high rise)' },
    wh:          { pts: [[0, .25], [1, -.6]], label: 'wh-question (fall from high)' },
    exclamation: { pts: [[0, .55], [.35, .7], [1, -.45]], label: 'exclamation (high fall)' },
    colon:       { pts: [[0, 0], [1, .45]], label: 'announcing (rise before a colon)' },
  }

  // ---- analysis --------------------------------------------------------------------------------------------------
  function analyze(data, api) {
    const { at, progress, words } = api, F = data.features, hop = data.hop, n = data.frames
    const lang = data.lang || 'vi', kind = data.kind || 'song'
    for (const w of words) if (w.text !== w.text.normalize('NFC')) w.text = w.text.normalize('NFC')
    const measure = api.measure || defaultMeasure()
    const fr = k => Math.max(0, Math.min(n - 1, Math.round(k / hop)))
    const pitched = k => F.voiced[k] === 1 && F.pitch[k] > 0
    // inverse of the light's progress: the time it reaches u, per word
    function invert(w) {
      const T = [], U = []
      for (let t = w.s; t <= w.e + 1e-6; t += 0.005) { T.push(t); U.push(progress(w, t)) }
      return u => {
        if (u <= U[0]) return T[0]
        for (let i = 1; i < U.length; i++) if (U[i] >= u) { const f = (u - U[i - 1]) / Math.max(1e-6, U[i] - U[i - 1]); return T[i - 1] + (T[i] - T[i - 1]) * f }
        return T[T.length - 1]
      }
    }
    // smoothed semitone track: 5-frame median, then a 5-frame mean, held through ≤ 50 ms unpitched gaps
    const st = new Float32Array(n).fill(NaN)
    { let last = NaN, gap = 99
      for (let k = 0; k < n; k++) {
        if (pitched(k)) {
          const win = []; for (let j = k - 2; j <= k + 2; j++) if (j >= 0 && j < n && pitched(j)) win.push(F.pitch[j] / 100)
          win.sort((x, y) => x - y); last = win[win.length >> 1]; gap = 0
        } else gap++
        st[k] = gap <= 5 ? last : NaN
      }
      const m = Float32Array.from(st)
      for (let k = 2; k < n - 2; k++) { let s = 0, c = 0; for (let j = k - 2; j <= k + 2; j++) if (!isNaN(m[j])) { s += m[j]; c++ } if (!isNaN(m[k]) && c) st[k] = s / c }
    }
    const semi = t => st[fr(t)]
    const dB = k => F.db[k] / 10

    // words → syllables (letters)
    const ALL = words.map(w => ({ w, text: w.text, bare: bare(w.text), core: core(w.text), syl: [], link: null, inner: [], phraseEnd: null, nodes: [],
      punct: core(w.text)[0] >= core(w.text)[1], breathAfter: 0, gapAfter: 0, cutAfter: 0, pts: { u: new Float32Array(0), h: new Float32Array(0), w: new Float32Array(0), cut: new Float32Array(0), syl: new Uint8Array(0), n: 0 } }))
    // a token with no letters (French sets "?", "!", ":", ";" apart with a space) gives its punctuation to the word before
    for (let i = 1; i < ALL.length; i++) if (ALL[i].punct) { let j = i - 1; while (j > 0 && ALL[j].punct) j--; ALL[j].tail = (ALL[j].tail || '') + ALL[i].text.trim() }
    const W = ALL.filter(x => !x.punct)
    for (const x of W) {
      if (lang === 'vi') {
        const s = viSyllable(x.text)
        x.syl = [{ c0: s.c0, c1: s.c1, nucleus: s.nucleus, tone: s.tone, toneKey: s.key, checked: s.checked, accent: s.tone, schwa: 0, mute: -1, onset: s.onset, coda: 0 }]
      } else if (lang === 'fr') {
        const r = frSyllables(x.text); x.syl = r.syl; x.silentEnt = r.silentEnt
        x.inner = frInner(x.text)
      } else x.syl = genSyllables(x.text)
      x.uChar = measure(x.text)                                  // char boundary → fraction of the word's width
    }
    // sentences / phrase ends (punctuation), French rhythmic groups and their stressed syllables, French links
    for (let i = 0; i < W.length; i++) {
      const p = trail(W[i].text) + (W[i].tail || '')
      W[i].phraseEnd = /\?/.test(p) ? 'question' : /!/.test(p) ? 'exclamation' : /[.…]/.test(p) ? 'final' : /:/.test(p) ? 'colon' : /[,;]/.test(p) ? 'continuation' : null
      if (i === W.length - 1 && !W[i].phraseEnd) W[i].phraseEnd = 'final'
    }
    { let s0 = 0
      for (let i = 0; i < W.length; i++) if (W[i].phraseEnd && W[i].phraseEnd !== 'continuation' && W[i].phraseEnd !== 'colon') {
        if (W[i].phraseEnd === 'question') {
          let k = s0; while (k < i && /^(mais|et|alors|donc|bon|eh|oh)$/.test(W[k].bare)) k++
          if (lang === 'fr' && WH.has(W[k].bare) && !(W[k + 1] && /^est-ce$/.test(W[k].bare))) W[i].phraseEnd = 'wh'
          if (lang === 'fr' && W[k].bare === 'que' ) W[i].phraseEnd = 'wh'
        }
        for (let k = s0; k <= i; k++) W[k].sentence = [s0, i]
        s0 = i + 1
      }
      for (let k = s0; k < W.length; k++) W[k].sentence = [s0, W.length - 1]
    }
    if (lang === 'fr') {
      for (let i = 0; i + 1 < W.length; i++) {
        W[i].link = W[i].tail ? null : frLink(W[i].text, W[i + 1].text, i > 0 && !W[i - 1].phraseEnd ? W[i - 1].bare : null)
      }
      // rhythmic groups: end at punctuation, or after a content word that a function word follows, once ≥ 3 syllables
      let syls = 0
      for (let i = 0; i < W.length; i++) {
        syls += W[i].syl.length
        const next = W[i + 1], content = !FUNC.has(W[i].bare) && !/^(l|d|j|m|t|s|n|qu|c)['’]/.test(W[i].bare) || /['’]/.test(W[i].bare) && W[i].bare.length > 3
        const endGroup = !!W[i].phraseEnd || (next && content && (FUNC.has(next.bare) || /^(l|d|j|m|t|s|n|qu|c)['’]/.test(next.bare)) && !/^(pas|y|en|plus)$/.test(next.bare) && syls >= 3 && !(W[i].link && W[i].link.status === 'obligatory'))
        if (endGroup) {
          W[i].groupEnd = W[i].phraseEnd || 'minor'
          // the stressed syllable: the last one without a schwa
          const s = W[i].syl; let k = s.length - 1; while (k > 0 && s[k].schwa) k--
          s[k].stressed = W[i].groupEnd
          syls = 0
        }
      }
    } else {
      for (const x of W) if (x.phraseEnd) x.groupEnd = x.phraseEnd
    }

    // syllable times (from the light's progress) and acoustics
    const S = []                                                   // every syllable, in order
    for (const x of W) {
      const inv = invert(x.w), U = x.uChar
      for (const s of x.syl) {
        s.u0 = U[s.c0]; s.u1 = U[s.c1]; s.un = (U[s.nucleus] + U[s.nucleus + 1]) / 2
        s.t0 = inv(s.u0); s.t1 = Math.max(s.t0 + 0.02, inv(s.u1)); s.word = x
        const k0 = fr(s.t0), k1 = Math.max(k0 + 1, fr(s.t1))
        let e = 0, ec = 0, ps = [], v = 0, att = 0
        for (let k = k0; k < k1; k++) {
          if (F.voiced[k]) { v++; if (pitched(k)) { e += dB(k); ec++ } }
          if (!isNaN(st[k])) ps.push(st[k])
          if (k < k0 + 6 && F.voiced[Math.min(n - 1, k + 2)]) att = Math.max(att, F.onset[k] / 100)
        }
        s.loud = ec ? e / ec : (v ? F.floor : NaN)                 // loudness over the vowel (pitched voiced frames) only
        s.pitch = ps.length ? pctl(ps, 0.5) : NaN
        s.rel = clamp(ps.length / Math.max(1, k1 - k0) * 1.3)        // how much of it has a pitch to trust
        s.dur = s.t1 - s.t0; s.attack = att; s.voicedFrac = v / Math.max(1, k1 - k0)
        // first / last voiced frame, for gaps
        let fv = -1, lv = -1; for (let k = k0; k < k1; k++) if (F.voiced[k]) { if (fv < 0) fv = k; lv = k }
        s.v0 = fv < 0 ? s.t0 : fv * hop; s.v1 = lv < 0 ? s.t1 : (lv + 1) * hop
        S.push(s)
      }
    }
    // normalisation (Pataca & Costa): mean of a whole-clip min-max (robust: p5/p95) and a min-max over the 15 syllables i−10 … i+5
    function normalise(key) {
      const vals = S.map(s => s[key]).filter(v => !isNaN(v)), g0 = pctl(vals, .05), g1 = pctl(vals, .95)
      const out = new Float32Array(S.length), loc = []
      S.forEach((s, i) => {
        const x = s[key]; if (isNaN(x)) { out[i] = NaN; loc.push(null); return }
        let lo = Infinity, hi = -Infinity
        for (let j = Math.max(0, i - 10); j <= Math.min(S.length - 1, i + 5); j++) { const y = S[j][key]; if (!isNaN(y)) { lo = Math.min(lo, y); hi = Math.max(hi, y) } }
        const gl = clamp((x - g0) / Math.max(1e-6, g1 - g0)), lc = hi - lo > 1e-6 ? (x - lo) / (hi - lo) : 0.5
        out[i] = (gl + lc) / 2; loc.push([lo, hi])
      })
      return { out, g0, g1, loc }
    }
    const NL = normalise('loud')
    // pitch keeps its intervals: one fixed scale per clip (h units per semitone, from the speaker's p5–p95 span), and
    // only the reference follows the register (the mean of the clip median and the 15-syllable median), so a minor
    // third is the same height everywhere in the clip (the intervals between syllables carry meaning: a sad voice
    // falls by minor thirds)
    const pv = S.map(s => s.pitch).filter(v => !isNaN(v)), gRef = pv.length ? pctl(pv, .5) : 60
    const span = clamp(pv.length ? pctl(pv, .95) - pctl(pv, .05) : 12, 8, 18), scale = 2 / span
    const durs = S.map(s => s.dur).sort((a, b) => a - b), medDur = durs[durs.length >> 1] || 0.2
    const atts = S.map(s => s.attack).sort((a, b) => a - b), attHi = atts[Math.floor(atts.length * 0.8)] || 0.5
    S.forEach((s, i) => {
      s.nE = isNaN(NL.out[i]) ? 0.15 : NL.out[i]
      const loc = []; for (let j = Math.max(0, i - 10); j <= Math.min(S.length - 1, i + 5); j++) if (!isNaN(S[j].pitch)) loc.push(S[j].pitch)
      s.center = loc.length ? (gRef + pctl(loc, .5)) / 2 : gRef
      s.nP = isNaN(s.pitch) ? NaN : clamp((s.pitch - s.center) * scale, -1, 1)
      s.lengthen = clamp((s.dur / medDur - 1) / 1.0)                 // syllable-timed languages: longer than usual is meaningful
    })
    // the interval from the previous syllable's nucleus, in semitones (none across a pause)
    const NAMES = ['P1', 'm2', 'M2', 'm3', 'M3', 'P4', 'TT', 'P5', 'm6', 'M6', 'm7', 'M7', 'P8']
    for (let i = 1; i < S.length; i++) {
      const s = S[i], p = S[i - 1]
      if (isNaN(s.pitch) || isNaN(p.pitch) || s.v0 - p.v1 > 0.18) continue
      const d = s.pitch - p.pitch, r = Math.round(Math.abs(d))
      s.interval = d; s.intervalName = (d > 0 ? '↗' : d < 0 ? '↘' : '') + (r > 12 ? 'P8+' : NAMES[r])
    }
    // gaps, articulation
    for (let i = 0; i < S.length; i++) {
      const s = S[i], p = S[i - 1], q = S[i + 1]
      s.gapBefore = p ? Math.max(0, s.v0 - p.v1) : 1
      s.gapAfter = q ? Math.max(0, q.v0 - s.v1) : 1
    }
    for (let i = 0; i < S.length; i++) {
      const s = S[i], q = S[i + 1]
      const short = s.dur < 0.6 * medDur, loud = s.nE > 0.6
      s.art = s.lengthen > 0.6 ? 'tenuto' : short && s.gapAfter > 0.05 ? 'staccato' : s.attack >= attHi && loud ? 'marcato' : 'legato'
      if (s.art === 'legato' && q && s.gapAfter < 0.03 && q.attack >= attHi * 0.8 && q.word === s.word) s.art = 'portato'
    }
    for (let i = 0; i + 2 < S.length; i++) {                          // ricochet: three or more quick, short, bouncing syllables
      let j = i
      // each one short, struck (an onset of its own) and quick after the last, relative to this voice's own pace
      const hop2 = k => S[k].dur < 0.62 * medDur && S[k + 1].t0 - S[k].t0 <= 0.62 * medDur && S[k + 1].attack >= attHi * 0.6 && S[k].gapAfter < 0.25
      while (j + 1 < S.length && hop2(j)) j++
      if (j - i >= 2) { for (let k = i; k <= j; k++) { S[k].art = 'ricochet'; S[k].bounce = k - i } i = j }
    }

    // words: breath after, link realization, nodes, the line
    const W2 = new Map()
    for (let i = 0; i < W.length; i++) {
      const x = W[i], nxt = W[i + 1], sl = x.syl[x.syl.length - 1], sn = nxt && nxt.syl[0]
      x.gapAfter = sn ? Math.max(0, sn.v0 - sl.v1) : 1
      x.breathAfter = x.gapAfter >= 0.18 ? x.gapAfter : 0
      // an audible inhale in the pause: unvoiced but above the floor
      if (x.breathAfter) { let air = 0, c = 0; for (let k = fr(sl.v1); k < fr(sn ? sn.v0 : sl.v1 + 0.3); k++) { c++; if (!F.voiced[k] && dB(k) > F.floor + 6) air++ } x.inhale = c ? air / c : 0 }
      x.legatoNext = !!sn && x.gapAfter < 0.04
      if (x.link) {
        const voiceJoined = x.gapAfter < (/^[tpksfʃ]$/.test(x.link.sound) ? 0.16 : 0.06)    // a voiceless liaison leaves its own short gap
        x.link.realized = x.link.status === 'obligatory' ? 1 : x.link.status === 'enchainement' ? (voiceJoined ? 1 : 0.4) : voiceJoined ? Math.max(0.75, x.link.prior) : x.link.prior * 0.5
        x.link.uFrom = (x.uChar[x.link.from] + x.uChar[x.link.from + 1]) / 2
        x.link.uTo = (nxt.uChar[x.link.to] + nxt.uChar[x.link.to + 1]) / 2
        x.link.next = nxt.w.flat
        if (x.breathAfter) x.link = null                               // a pause breaks any liaison
      }
      for (const l of x.inner) { l.uFrom = (x.uChar[l.from] + x.uChar[l.from + 1]) / 2; l.uTo = (x.uChar[l.to] + x.uChar[l.to + 1]) / 2 }
      W2.set(x.w.flat, x)
    }
    // phrases between breaths, for hairpins
    const phrases = []
    { let a = 0
      for (let i = 0; i < W.length; i++) if (W[i].breathAfter || i === W.length - 1) {
        const ss = []; for (let k = a; k <= i; k++) ss.push(...W[k].syl)
        let hair = null
        if (ss.length >= 4) {
          const h = Math.floor(ss.length / 2), e0 = ss.slice(0, h).reduce((m, s) => m + s.nE, 0) / h, e1 = ss.slice(h).reduce((m, s) => m + s.nE, 0) / (ss.length - h)
          if (e1 - e0 > 0.18) hair = 'cresc'; else if (e0 - e1 > 0.18) hair = 'decresc'
        }
        phrases.push({ w0: W[a].w.flat, w1: W[i].w.flat, hairpin: hair, end: W[i].phraseEnd })
        a = i + 1
      }
    }

    // the line: per syllable, K samples through τ, placed along x so the tone's characteristic point sits under the
    // tone-bearing vowel. The mark decides the direction, the voice decides how far: the syllable's measured contour is
    // projected on the tone's (or the French intonation event's) shape; agreeing, the line moves as far as the voice did,
    // flattened or contrary, it still turns the way the mark says, by less. Level, weight and timing are the voice's.
    // In songs the melody leads (a small floor for the shape, most of the measured residual kept).
    const song = kind === 'song', K = 12
    const FLOOR = song ? 0.3 : 0.55, RESID = song ? 0.8 : 0.3
    let prevLevel = 0
    for (const x of W) {
      const N = x.syl.length * K + 1, u = new Float32Array(N), h = new Float32Array(N), wt = new Float32Array(N), cut = new Float32Array(N), sIdx = new Uint8Array(N)
      const sent = x.sentence || [0, 0], sw = W.indexOf(x), sentPos = (sw - sent[0]) / Math.max(1, sent[1] - sent[0])
      let m = 0
      x.syl.forEach((s, si) => {
        const tpl = lang === 'vi' ? VI_TONE[s.toneKey] : null
        const ev = s.stressed ? FR_EVENT[s.stressed] || null : null
        const shape = tpl || ev, measured = !isNaN(s.nP)
        // a host may have no source for a signal and return null for it (never a flag zero): treat that as absent
        let eMax = 1e-6; for (let k = fr(s.t0); k <= fr(s.t1); k++) eMax = Math.max(eMax, at('E', k * hop) ?? 0)
        const k0 = si === 0 ? 0 : 1, taus = [], hm = [], T = []
        for (let k = k0; k <= K; k++) {
          const tau = k / K, sv = semi(lerp(s.t0, s.t1, tau))
          taus.push(tau); hm.push(isNaN(sv) ? NaN : clamp((sv - s.center) * scale, -1.1, 1.1)); T.push(shape ? shapeAt(shape.pts, tau) : 0)
        }
        const valid = hm.map(v => !isNaN(v)), nv = valid.filter(Boolean).length
        const mMean = nv ? hm.reduce((acc, v, i) => valid[i] ? acc + v : acc, 0) / nv : NaN
        const tMean = T.reduce((acc, v) => acc + v, 0) / T.length
        // the level: measured mean; unmeasured, the shape's register (Vietnamese) or the last level drifting down
        const level = nv >= 3 ? mMean : tpl ? 0.6 * tMean + 0.4 * prevLevel : prevLevel * 0.85 - 0.04 * sentPos
        let amp = 1, c = 1
        if (shape && nv >= 4) {
          let num = 0, den = 0
          for (let i = 0; i < T.length; i++) if (valid[i]) { const td = T[i] - tMean; num += (hm[i] - mMean) * td; den += td * td }
          if (den > 1e-4) { c = num / den; amp = c > 0 ? clamp(c, FLOOR, 1.6) : FLOOR }
        }
        // without a shape: a quadratic through the measured contour (the polished line), else the level
        let qa = 0, qb = 0, qc = level
        if (!shape && nv >= 4) {
          let S0 = 0, S1 = 0, S2 = 0, S3 = 0, S4 = 0, Y0 = 0, Y1 = 0, Y2 = 0
          for (let i = 0; i < taus.length; i++) if (valid[i]) { const t = taus[i] - 0.5, y = hm[i]; S0++; S1 += t; S2 += t * t; S3 += t * t * t; S4 += t * t * t * t; Y0 += y; Y1 += y * t; Y2 += y * t * t }
          const det = S0 * (S2 * S4 - S3 * S3) - S1 * (S1 * S4 - S3 * S2) + S2 * (S1 * S3 - S2 * S2)
          if (Math.abs(det) > 1e-9) {
            qc = (Y0 * (S2 * S4 - S3 * S3) - S1 * (Y1 * S4 - S3 * Y2) + S2 * (Y1 * S3 - S2 * Y2)) / det
            qb = (S0 * (Y1 * S4 - S3 * Y2) - Y0 * (S1 * S4 - S3 * S2) + S2 * (S1 * Y2 - Y1 * S2)) / det
            qa = (S0 * (S2 * Y2 - Y1 * S3) - S1 * (S1 * Y2 - Y1 * S2) + Y0 * (S1 * S3 - S2 * S2)) / det
            qa = clamp(qa, -3, 3); qb = clamp(qb, -2.5, 2.5)
          }
        }
        taus.forEach((tau, i) => {
          // x: [u0, un] holds τ 0…0.5, [un, u1] holds τ 0.5…1
          const uu = tau <= 0.5 ? lerp(s.u0, s.un, tau * 2) : lerp(s.un, s.u1, tau * 2 - 1)
          const t = lerp(s.t0, s.t1, tau)
          let hv
          if (shape) {
            const td = T[i] - tMean
            hv = level + amp * td + (valid[i] ? RESID * s.rel * ((hm[i] - mMean) - c * td) : 0)
          } else hv = nv >= 4 ? qc + qb * (tau - 0.5) + qa * (tau - 0.5) * (tau - 0.5) : level
          // softening goes down: a breathy huyền, a schwa, the mute e tail
          hv -= 0.2 * ((tpl ? tpl.soft : 0) + s.schwa * 0.5)
          let wv = 0.12 + 0.88 * clamp(0.62 * s.nE + 0.38 * (at('E', t) ?? 0) / eMax * s.nE + 0.3 * (at('B', t) ?? 0))
          if (s.mute >= 0 && uu > x.uChar[s.mute]) { const f = clamp((uu - x.uChar[s.mute]) / Math.max(1e-6, s.u1 - x.uChar[s.mute])); hv -= 0.28 * f; wv *= 1 - 0.7 * f }
          wv *= 1 - 0.35 * s.schwa
          u[m] = uu; h[m] = clamp(hv, -1, 1); wt[m] = clamp(wv); cut[m] = 0; sIdx[m] = si; m++
        })
        s.agree = shape ? c : null                                          // how far the voice went with the mark (1 = as written)
        if (nv >= 3) prevLevel = mMean
        // breaks inside the syllable: the glottal break of ngã, the cut of nặng, a tréma's hiatus
        if (tpl && tpl.glottal > 0 && tpl.glottal < 1) { const j = m - 1 - Math.round((1 - tpl.glottal) * K); if (j > 0) cut[j] = Math.max(cut[j], tpl === VI_TONE.nga ? 0.45 : 0.35) }
        // the break before the next syllable (inside the word): articulation
        if (si + 1 < x.syl.length) {
          const q = x.syl[si + 1]
          let g = Math.max(q.onset * 0.8, clamp(q.gapBefore / 0.12) * 0.9, q.trema ? 0.5 : 0, s.coda)
          if (s.art === 'staccato' || s.art === 'ricochet') g = Math.max(g, 0.55)
          if (q.gapBefore < 0.025 && !q.trema) g *= 0.35                              // voice ran on: keep it bowed
          for (const l of x.inner) if (l.uFrom <= q.u0 + 1e-6 && l.uTo >= q.u0 - 1e-6) g = 0   // elision / hyphen liaison joins
          cut[m - 1] = Math.max(cut[m - 1], g)
        }
      })
      // the break after the word (into the next): 1 = a breath, 0 = joined (liaison, enchaînement, legato)
      const ls = x.syl[x.syl.length - 1], nx = W[W.indexOf(x) + 1]
      let ga = 0
      if (nx) {
        const q = nx.syl[0], tpl = lang === 'vi' ? VI_TONE[ls.toneKey] : null
        ga = Math.max(q.onset * 0.85, clamp(x.gapAfter / 0.12), tpl ? tpl.sharp * (tpl.glottal >= 0.9 ? 1 : 0.6) : 0, ls.coda, ls.art === 'staccato' || ls.art === 'ricochet' ? 0.6 : 0)
        if (x.gapAfter < 0.03) ga *= 0.4
        if (x.link && x.link.realized >= 0.7) ga = 0
        if (x.breathAfter) ga = 1
      } else ga = 1
      x.cutAfter = ga
      // light smoothing inside joined runs (keeps tone shapes, removes the frame jitter)
      const hs = Float32Array.from(h)
      for (let j = 1; j < m - 1; j++) if (!cut[j - 1] && !cut[j]) hs[j] = 0.25 * h[j - 1] + 0.5 * h[j] + 0.25 * h[j + 1]
      x.pts = { u: u.subarray(0, m), h: hs.subarray(0, m), w: wt.subarray(0, m), cut: cut.subarray(0, m), syl: sIdx.subarray(0, m), n: m }
      // inflection nodes: under the tone-bearing / accented vowel, or the stressed syllable's nucleus
      x.nodes = []
      x.syl.forEach((s, si) => {
        let j = 0, best = 9; for (let k = 0; k < m; k++) if (sIdx[k] === si && Math.abs(u[k] - s.un) < best) { best = Math.abs(u[k] - s.un); j = k }
        const tpl = lang === 'vi' ? VI_TONE[s.toneKey] : null
        const kindN = lang === 'vi' ? s.tone : s.stressed ? 'stress' : s.accent ? s.accent : null
        if (!kindN) return
        const move = tpl ? Math.abs(tpl.pts[tpl.pts.length - 1][1] - tpl.pts[0][1]) : s.stressed ? 0.6 : 0.25
        // direction the line takes through the node: rising, falling, dipping, broken, level
        const dir = tpl ? { ngang: 'level', huyen: 'fall', sac: 'rise', hoi: 'dip', nga: 'broken-rise', nang: 'fall-cut' }[s.tone]
          : s.stressed ? ({ minor: 'rise', continuation: 'rise', question: 'rise', colon: 'rise', final: 'fall', wh: 'fall', exclamation: 'fall' }[s.stressed])
          : s.accent === 'trema' ? 'break' : 'level'
        x.nodes.push({ u: s.un, h: hs[j], i: j, kind: kindN, dir, strength: clamp(move), syl: si, stressed: !!s.stressed, accent: s.accent || null, tone: s.tone || null,
          st: s.pitch, interval: s.interval ?? null, intervalName: s.intervalName ?? null })
      })
    }

    const word = []
    for (const x of ALL) { if (x.punct) x.uChar = measure(x.text); word[x.w.flat] = x }
    const res = { lang, kind, word, phrases, syllables: S, medDur, VI_TONE, FR_EVENT,
      semitone: scale,                   // h units per semitone (h = ±1 is ±span/2 semitones around the speaker's reference)
      span, reference: gRef,
      /** the sample index range of a word revealed by the light at progress p (0…1) */
      upto(x, p) { const U = x.pts.u; let j = 0; while (j < x.pts.n && U[j] <= p) j++; return j },
      /** height/weight at fraction u of a word, interpolated */
      sample(x, uq) {
        const P = x.pts, U = P.u; if (!P.n) return { h: 0, w: 0.12 }
        if (uq <= U[0]) return { h: P.h[0], w: P.w[0] }
        for (let j = 1; j < P.n; j++) if (U[j] >= uq) { const f = (uq - U[j - 1]) / Math.max(1e-6, U[j] - U[j - 1]); return { h: lerp(P.h[j - 1], P.h[j], f), w: lerp(P.w[j - 1], P.w[j], f), cut: P.cut[j - 1] } }
        return { h: P.h[P.n - 1], w: P.w[P.n - 1] }
      },
    }
    return res
  }

  function defaultMeasure() {
    let ctx = null
    try {
      const cv = typeof OffscreenCanvas !== 'undefined' ? new OffscreenCanvas(8, 8) : document.createElement('canvas')
      ctx = cv.getContext('2d'); ctx.font = '500 100px -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif'
    } catch { ctx = null }
    return text => {
      const ch = [...text], out = new Float32Array(ch.length + 1)
      if (!ctx) { for (let i = 0; i <= ch.length; i++) out[i] = i / Math.max(1, ch.length); return out }
      const full = Math.max(1e-6, ctx.measureText(text).width)
      for (let i = 0; i <= ch.length; i++) out[i] = ctx.measureText(ch.slice(0, i).join('')).width / full
      return out
    }
  }

  const api = { analyze, viSyllable, frSyllables, frLink, frInner, frVowelStart, core, bare, VI_TONE, FR_EVENT }
  if (typeof window !== 'undefined') window.Prosody = api
  if (typeof module !== 'undefined') module.exports = api
})()
