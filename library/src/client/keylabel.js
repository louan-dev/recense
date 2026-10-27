// Key slider labels: the 10-state notation cycle under the Key slider, the parser for a stored
// original key, and key detection (Krumhansl-Schmuckler on a chroma vector). Pure functions, no
// DOM: the page loads this before gallery.js, and test/keylabel.test.mjs runs it in node.
//
// A stored key is root + accidental + mode, kept canonical as e.g. "E♭m" (minor) or "D♭" (major).
// The slider value is semitones from the original, -12..+12; the sign is direction only and the
// mode never changes.
globalThis.GalleryKey = (() => {
  "use strict";

  // bottom caption of each state, and the step setKey snaps to (semitones)
  // State 0 reads C/Đô (SPEC P2: the first three are C/Đô, Ton., Tông)
  const CAPTIONS = ["C/Đô", "Ton.", "Tông", "Tonart", "調", "调", "Sa", "Maqam", "Maqam¼", "Cents"];
  const STEPS = [1, 1, 1, 1, 1, 1, 1, 1, 0.5, 0.01];
  const STATES = CAPTIONS.length;

  // States 0–7, verbatim from the spec: pc | American | French | Vietnamese | German/Nordic |
  // Japanese | Chinese | Indian. A cell is "major / minor", or one value for both.
  const TABLE = `
0  | Cmaj / Cm     | Domaj / Dom     | Đô T / Đô t   | C / c     | ハ長 / ハ短     | 1=C / 6=C   | Sa=C
1  | D♭maj / C♯m   | Ré♭maj / Do♯m   | Rê♭T / Đô♯t   | Des / cis | 変ニ長 / 嬰ハ短 | 1=D♭ / 6=C♯ | Sa=D♭ / Sa=C♯
2  | Dmaj / Dm     | Rémaj / Rém     | Rê T / Rê t   | D / d     | ニ長 / ニ短     | 1=D / 6=D   | Sa=D
3  | E♭maj / E♭m   | Mi♭maj / Mi♭m   | Mi♭T / Mi♭t   | Es / es   | 変ホ長 / 変ホ短 | 1=E♭ / 6=E♭ | Sa=E♭
4  | Emaj / Em     | Mimaj / Mim     | Mi T / Mi t   | E / e     | ホ長 / ホ短     | 1=E / 6=E   | Sa=E
5  | Fmaj / Fm     | Famaj / Fam     | Fa T / Fa t   | F / f     | ヘ長 / ヘ短     | 1=F / 6=F   | Sa=F
6  | F♯maj / F♯m   | Fa♯maj / Fa♯m   | Fa♯T / Fa♯t   | Fis / fis | 嬰ヘ長 / 嬰ヘ短 | 1=F♯ / 6=F♯ | Sa=F♯
7  | Gmaj / Gm     | Solmaj / Solm   | Sol T / Sol t | G / g     | ト長 / ト短     | 1=G / 6=G   | Sa=G
8  | A♭maj / G♯m   | La♭maj / Sol♯m  | La♭T / Sol♯t  | As / gis  | 変イ長 / 嬰ト短 | 1=A♭ / 6=G♯ | Sa=A♭ / Sa=G♯
9  | Amaj / Am     | Lamaj / Lam     | La T / La t   | A / a     | イ長 / イ短     | 1=A / 6=A   | Sa=A
10 | B♭maj / B♭m   | Si♭maj / Si♭m   | Si♭T / Si♭t   | B / b     | 変ロ長 / 変ロ短 | 1=B♭ / 6=B♭ | Sa=B♭
11 | Bmaj / Bm     | Simaj / Sim     | Si T / Si t   | H / h     | ロ長 / ロ短     | 1=B / 6=B   | Sa=B
`;

  // Maqam names (TO BE VERIFIED by the owner): edit here only.
  //   tone[pc]     State 7 line 2, and State 8 at an even quarter-tone
  //   quarter[qpc] State 8 at an odd quarter-tone (qpc = quarter-tones above C)
  const MAQAM = {
    tone: ["Rast", "Zirg.", "Dukah", "Kurd", "Busel.", "Jahar.", "Hijaz", "Nawa", "Hisar", "Husay.", "Ajam", "Mahur"],
    quarter: {
      1: "Tik Zirg.",
      3: "Kawasht",
      5: "Tik Busel.",
      7: "Sikah",
      9: "Tik Jahar.",
      11: "Tik Hijaz",
      13: "Tik Hisar",
      15: "Shuri",
      17: "Tik Husay.",
      19: "Iraq",
      21: "Awj",
      23: "Nim Rast",
    },
  };

  // State 8 line 1 at an odd quarter-tone (the same for major and minor; m / maj is appended)
  const QUARTER_AMERICAN = {
    1: "C♯/", 3: "D♭/", 5: "D♯/", 7: "E♭/", 9: "F♭/", 11: "F♯/",
    13: "G♭/", 15: "G♯/", 17: "A♭/", 19: "A♯/", 21: "B♭/", 23: "C♭/",
  };

  const COLS = ["am", "fr", "vi", "de", "ja", "zh", "in"];
  const ROWS = TABLE.trim()
    .split("\n")
    .map((line) => {
      const cells = line.split("|").map((c) => c.trim());
      const row = {};
      COLS.forEach((c, i) => {
        const [maj, min] = cells[i + 1].split(" / ");
        row[c] = [maj, min === undefined ? maj : min];
      });
      return row;
    });

  // ----- parsing a stored key -----

  const LETTER_PC = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };
  const ACC = { "#": "♯", "♯": "♯", b: "♭", "♭": "♭", "♮": "♮", "": "" };
  const ACC_SHIFT = { "♯": 1, "♭": -1, "♮": 0, "": 0 };

  // "Eb m", "E♭m", "eb minor", "C#", "F♯ major", "E♮m" -> { letter, acc, minor, pc } (null if not a key)
  const parse = (s) => {
    const m = String(s == null ? "" : s)
      .trim()
      .match(/^([A-Ga-g])\s*([#b♯♭♮]?)\s*(.*)$/);
    if (!m) return null;

    const mode = m[3].trim();
    let minor;
    if (mode === "" || mode === "M" || /^maj(or)?$/i.test(mode)) minor = false;
    else if (mode === "m" || mode === "-" || /^min(or)?$/i.test(mode)) minor = true;
    else return null;

    const letter = m[1].toUpperCase();
    const acc = ACC[m[2]];
    return { letter, acc, minor, pc: (((LETTER_PC[letter] + ACC_SHIFT[acc]) % 12) + 12) % 12 };
  };

  // what someone types, in any notation the caption cycles through: "Dm", "Rém", "Re mineur", "Rê t",
  // "d" (German/Nordic minor), "Es", "fis", "ニ短", "変ホ長調", "6=D", "Sa=D♭" … (null if not a key).
  // English comes first, so "B" is B; a bare lowercase letter is the German/Nordic minor ("b" = B♭m).
  const SOLFEGE = { do: "C", "đô": "C", re: "D", "rê": "D", mi: "E", fa: "F", sol: "G", so: "G", la: "A", si: "B", ti: "B" };
  const KANA = { "ハ": "C", "ニ": "D", "ホ": "E", "ヘ": "F", "ト": "G", "イ": "A", "ロ": "B" };
  const MAJ_WORDS = /^(|M|maj(eur|or)?|major|dur|trưởng|truong)$/i;
  const MIN_WORDS = /^(m|-|min(eur|or)?|moll|thứ|thu)$/i;
  const fromParts = (letter, acc, minor) => {
    const a = ACC[acc] === undefined ? "" : ACC[acc];
    return { letter, acc: a, minor, pc: (((LETTER_PC[letter] + ACC_SHIFT[a]) % 12) + 12) % 12 };
  };

  const parseAny = (raw) => {
    const s = String(raw == null ? "" : raw).trim().replace(/\s+/g, " ");
    if (!s) return null;

    // German / Nordic: H = B, B = B♭, -is sharp, -es / -s flat; lowercase is minor
    const de = s.match(/^([A-Ha-h])(is|es|s)?(?:\s*-?\s*(dur|moll))?$/);
    if (de) {
      const up = de[1].toUpperCase();
      const minor = de[3] ? /moll/i.test(de[3]) : de[1] !== up;
      const suf = de[2] || "";
      const okS = suf !== "s" || up === "E" || up === "A";
      const okGerman = de[1] === de[1].toLowerCase() || suf || de[3] || up === "H";
      if (okS && okGerman) {
        if (up === "H") return fromParts("B", suf === "is" ? "♯" : suf ? "♭" : "", minor);
        if (up === "B" && !suf) return fromParts("B", "♭", minor);
        return fromParts(up, suf === "is" ? "♯" : suf ? "♭" : "", minor);
      }
    }

    const en = parse(s);
    if (en) return en;

    // solfège (French, Vietnamese, Italian …): Ré♭m, Re b mineur, Mi♭T, Rê t, Đô♯ thứ
    const so = s.match(/^(đô|do|ré|re|rê|mi|fa|sol|so|la|si|ti)\s*([#b♯♭♮]?)\s*(.*)$/i);
    if (so) {
      const name = so[1].toLowerCase().replace("é", "e");
      const letter = SOLFEGE[name];
      const mode = so[3].trim();
      // Vietnamese: capital T major, small t minor
      const minor = mode === "T" ? false : mode === "t" ? true : MIN_WORDS.test(mode) ? true : MAJ_WORDS.test(mode) ? false : null;
      if (letter && minor !== null) return fromParts(letter, so[2], minor);
    }

    // Japanese: 嬰ハ短, 変ホ長調, ニ短調
    const ja = s.match(/^([嬰変本]?)\s*([ハニホヘトイロ])\s*([長短])調?$/);
    if (ja) return fromParts(KANA[ja[2]], ja[1] === "嬰" ? "♯" : ja[1] === "変" ? "♭" : "", ja[3] === "短");

    // Chinese numbered notation: 1=D major, 6=D minor
    const zh = s.match(/^([16])\s*=\s*([A-Ga-g])\s*([#b♯♭]?)$/);
    if (zh) return fromParts(zh[2].toUpperCase(), zh[3], zh[1] === "6");

    // Indian: Sa=D (major unless a mode follows)
    const sa = s.match(/^sa\s*=\s*(.+)$/i);
    if (sa) return parse(sa[1]);

    return null;
  };

  // the canonical stored form: "E♭m", "D♭", "E♮m"
  const canon = (s) => {
    const k = typeof s === "object" && s ? s : parse(s);
    return k ? k.letter + k.acc + (k.minor ? "m" : "") : "";
  };

  // ----- the stored spelling in each notation (position 0) -----

  const FR = { C: "Do", D: "Ré", E: "Mi", F: "Fa", G: "Sol", A: "La", B: "Si" };
  const VI = { C: "Đô", D: "Rê", E: "Mi", F: "Fa", G: "Sol", A: "La", B: "Si" };
  const JA = { C: "ハ", D: "ニ", E: "ホ", F: "ヘ", G: "ト", A: "イ", B: "ロ" };

  const german = (k, nat) => {
    let n;
    if (k.letter === "B") n = k.acc === "♭" ? "B" : k.acc === "♯" ? "His" : "H";
    else if (k.acc === "♯") n = k.letter + "is";
    else if (k.acc === "♭") n = k.letter === "E" || k.letter === "A" ? k.letter + "s" : k.letter + "es";
    else n = k.letter;
    if (nat) n += "♮";
    return k.minor ? n.toLowerCase() : n;
  };

  // spelled(k, col, showNatural): the stored spelling rendered in one notation column
  const spelled = (k, col, nat) => {
    const acc = k.acc === "♮" ? (nat ? "♮" : "") : k.acc;
    const note = k.letter + acc;

    switch (col) {
      case "am":
        return note + (k.minor ? "m" : "maj");
      case "fr":
        return FR[k.letter] + acc + (k.minor ? "m" : "maj");
      case "vi":
        return VI[k.letter] + (acc || " ") + (k.minor ? "t" : "T");
      case "de":
        return german(k, k.acc === "♮" && nat);
      case "ja": {
        const pre = k.acc === "♯" ? "嬰" : k.acc === "♭" ? "変" : k.acc === "♮" && nat ? "本" : "";
        return pre + JA[k.letter] + (k.minor ? "短" : "長");
      }
      case "zh":
        return (k.minor ? "6=" : "1=") + note;
      case "in":
        return "Sa=" + note;
    }
    return note;
  };

  // ----- numbers and steps -----

  const MINUS = "−"; // the same minus the other sliders show
  const NO_KEY = "Key: —";
  const signed = (n) => (n > 0 ? "+" : n < 0 ? MINUS : "") + String(Math.abs(n));
  const clampKey = (v) => Math.min(12, Math.max(-12, v));

  // the slider value snapped to a state's step (states 0–7: whole semitones, 8: halves, 9: cents)
  const quantize = (v, state) => {
    v = clampKey(Number(v) || 0);
    const st = STEPS[state] || 1;
    const q = st === 1 ? Math.round(v) : st === 0.5 ? Math.round(v * 2) / 2 : Math.round(v * 100) / 100;
    return clampKey(q) || 0; // no -0
  };

  const mod = (a, n) => ((a % n) + n) % n;

  // ----- the label -----
  //
  // label(value, state, stored, native) -> { lines: [top, bottom?], caption }
  //   value  slider value (semitones; snapped to the state's step here too)
  //   state  0..9
  //   stored the media's original key string (any form parse accepts), or "" / null
  //   native "en" | "fr" | "vi": only State 0's second line depends on it
  const label = (value, state, stored, native) => {
    state = mod(Math.round(Number(state) || 0), STATES);
    const v = quantize(value, state);
    const caption = CAPTIONS[state];
    const k = parse(stored);

    // No key known (none stored, none detected): never a made-up root. "Key: —", and the shift in
    // semitones only when there is one: "Key: —" / "(+2 st)" (owner, 2026-10-27, SPEC 62)
    if (!k) {
      const st = Math.round(v * 100) / 100;
      return { lines: st ? [NO_KEY, "(" + signed(st) + " st)"] : [NO_KEY], caption };
    }

    const mi = k.minor ? 1 : 0;

    // pc of a whole-semitone position; position 0 (and ±12) keeps the stored spelling, ♮ included
    const at = (semis, col) => {
      if (mod(semis, 12) === 0) return spelled(k, col, true);
      return ROWS[mod(k.pc + semis, 12)][col][mi];
    };
    const maqam = (semis) => MAQAM.tone[mod(k.pc + semis, 12)];

    if (state === 9) {
      const near = Math.round(v);
      const cents = Math.round((v - near) * 100);
      return { lines: [at(near, "am"), (cents < 0 ? MINUS : "+") + Math.abs(cents) + "¢"], caption };
    }

    if (state === 8) {
      const qpc = mod(k.pc * 2 + Math.round(v * 2), 24);
      if (qpc % 2 === 0) {
        const semis = Math.round(v * 2) / 2; // whole here
        return { lines: [at(semis, "am"), maqam(semis)], caption };
      }
      return { lines: [QUARTER_AMERICAN[qpc] + (k.minor ? "m" : "maj"), MAQAM.quarter[qpc]], caption };
    }

    const s = Math.round(v);
    if (state === 0) {
      const two = native === "fr" ? "fr" : native === "vi" ? "vi" : "";
      return { lines: two ? [at(s, "am"), at(s, two)] : [at(s, "am")], caption };
    }
    if (state === 7) return { lines: [at(s, "am"), maqam(s)], caption };
    return { lines: [at(s, COLS[state])], caption };
  };

  // ----- detection -----
  //
  // Krumhansl-Kessler key profiles, correlated with a 12-bin chroma vector (index 0 = C).
  const KK_MAJ = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
  const KK_MIN = [6.33, 2.68, 3.52, 5.38, 2.6, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

  const corr = (a, b) => {
    const n = a.length;
    let ma = 0;
    let mb = 0;
    for (let i = 0; i < n; i++) {
      ma += a[i];
      mb += b[i];
    }
    ma /= n;
    mb /= n;
    let num = 0;
    let da = 0;
    let db = 0;
    for (let i = 0; i < n; i++) {
      num += (a[i] - ma) * (b[i] - mb);
      da += (a[i] - ma) * (a[i] - ma);
      db += (b[i] - mb) * (b[i] - mb);
    }
    return da && db ? num / Math.sqrt(da * db) : 0;
  };

  // the best of the 24 keys for a chroma vector, spelled as the table's American column
  // ("D♭", "C♯m"); "" when there is nothing to go on
  const keyOfChroma = (chroma) => {
    if (!chroma || chroma.length !== 12 || !chroma.some((x) => x > 0)) return "";
    let best = -2;
    let out = null;

    for (let r = 0; r < 12; r++) {
      const maj = [];
      const min = [];
      for (let i = 0; i < 12; i++) {
        maj.push(KK_MAJ[mod(i - r, 12)]);
        min.push(KK_MIN[mod(i - r, 12)]);
      }
      const cM = corr(chroma, maj);
      const cm = corr(chroma, min);
      if (cM > best) {
        best = cM;
        out = { pc: r, minor: false };
      }
      if (cm > best) {
        best = cm;
        out = { pc: r, minor: true };
      }
    }

    return ROWS[out.pc].am[out.minor ? 1 : 0].replace(/maj$/, "");
  };

  // a chroma vector from mono samples: 4096-point FFT frames, magnitude folded onto pitch classes
  // between 55 Hz and 2 kHz
  const chromaOf = (samples, sr) => {
    const N = 4096;
    const chroma = new Array(12).fill(0);
    if (!samples || samples.length < N || !(sr > 0)) return chroma;

    const re = new Float64Array(N);
    const im = new Float64Array(N);
    const win = new Float64Array(N);
    for (let i = 0; i < N; i++) win[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / N);

    const lo = Math.max(1, Math.ceil((55 * N) / sr));
    const hi = Math.min(N / 2 - 1, Math.floor((2000 * N) / sr));
    const binPc = new Int8Array(N / 2);
    for (let b = lo; b <= hi; b++) binPc[b] = mod(Math.round(12 * Math.log2((b * sr) / N / 440)) + 9, 12);

    const frames = Math.floor(samples.length / N);
    for (let f = 0; f < frames; f++) {
      const o = f * N;
      for (let i = 0; i < N; i++) {
        re[i] = samples[o + i] * win[i];
        im[i] = 0;
      }
      fft(re, im);
      const frame = new Array(12).fill(0);
      let sum = 0;
      for (let b = lo; b <= hi; b++) {
        const m = Math.sqrt(re[b] * re[b] + im[b] * im[b]);
        frame[binPc[b]] += m;
        sum += m;
      }
      if (sum > 0) for (let i = 0; i < 12; i++) chroma[i] += frame[i] / sum; // each frame counts the same
    }
    return chroma;
  };

  // in-place radix-2 FFT (N a power of two)
  const fft = (re, im) => {
    const n = re.length;
    for (let i = 1, j = 0; i < n; i++) {
      let bit = n >> 1;
      for (; j & bit; bit >>= 1) j ^= bit;
      j ^= bit;
      if (i < j) {
        let t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    for (let len = 2; len <= n; len <<= 1) {
      const ang = (-2 * Math.PI) / len;
      const wr = Math.cos(ang);
      const wi = Math.sin(ang);
      for (let i = 0; i < n; i += len) {
        let cr = 1;
        let ci = 0;
        for (let k = 0; k < len / 2; k++) {
          const a = i + k;
          const b = a + len / 2;
          const tr = re[b] * cr - im[b] * ci;
          const ti = re[b] * ci + im[b] * cr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
          const nr = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = nr;
        }
      }
    }
  };


  // ----- chords (SPEC 40): the chord detector widget -----
  //
  // chordOf(chroma) -> { pc, minor } | null: the major or minor triad that best fits a short chroma
  // vector (template matching, the third weighted below root and fifth); null on silence or noise.
  const chordOf = (chroma) => {
    if (!chroma || chroma.length !== 12) return null;
    let sum = 0;
    for (let i = 0; i < 12; i++) sum += chroma[i] > 0 ? chroma[i] : 0;
    if (!(sum > 0)) return null;
    let best = 0;
    let out = null;
    for (let r = 0; r < 12; r++) {
      for (const minor of [false, true]) {
        const t = [r, mod(r + (minor ? 3 : 4), 12), mod(r + 7, 12)];
        const w = [1, 0.8, 0.9];
        let inn = 0;
        for (let j = 0; j < 3; j++) inn += w[j] * Math.max(0, chroma[t[j]]);
        const s = inn / sum - 0.05 * (minor ? 1 : 0); // a tie goes to major
        if (s > best) {
          best = s;
          out = { pc: r, minor };
        }
      }
    }
    return best >= 0.4 ? out : null; // a triad holds at least 40% of the energy
  };

  // a chroma vector from an AnalyserNode's dB spectrum (getFloatFrequencyData), 55 Hz to 2 kHz
  const chromaOfSpectrum = (db, sr) => {
    const chroma = new Array(12).fill(0);
    if (!db || !db.length || !(sr > 0)) return chroma;
    const N = db.length * 2;
    const lo = Math.max(1, Math.ceil((55 * N) / sr));
    const hi = Math.min(db.length - 1, Math.floor((2000 * N) / sr));
    for (let b = lo; b <= hi; b++) {
      if (!isFinite(db[b])) continue;
      chroma[mod(Math.round(12 * Math.log2((b * sr) / N / 440)) + 9, 12)] += Math.pow(10, db[b] / 20);
    }
    return chroma;
  };

  // the default notation for a trailing language: English C/Đô, French Ton., Vietnamese Tông
  const LANG_STATE = { en: 0, fr: 1, vi: 2 };

  // chordName(chord, state) -> "E♭m", "Mi♭m", "Mi♭ t", "es" …: a chord spelled in a notation state's
  // column (States 7–9, maqam and cents, spell it the American way). A major chord drops "maj"/"T".
  const chordName = (c, state) => {
    if (!c) return "";
    state = mod(Math.round(Number(state) || 0), STATES);
    const col = state >= 1 && state <= 6 ? COLS[state] : "am";
    const cell = ROWS[c.pc][col][c.minor ? 1 : 0];
    if (col === "am" || col === "fr") return c.minor ? cell : cell.replace(/maj$/, "");
    if (col === "vi") return c.minor ? cell.replace(/\s*t$/, " t") : cell.replace(/\s*T$/, "");
    return cell;
  };

  // the state chords are spelled in: the most recently chosen Key notation when it was chosen after
  // the trailing language (notationLast), else the language's own
  const chordState = (lang, notation, notationLast) =>
    notationLast ? mod(Math.round(Number(notation) || 0), STATES) : LANG_STATE[lang] || 0;

  return { CAPTIONS, STEPS, STATES, MAQAM, ROWS, parse, parseAny, canon, quantize, label, keyOfChroma, chromaOf, chordOf, chordName, chordState, chromaOfSpectrum };
})();
