# Recense's open ears: Meta's Omnilingual ASR (CTC 300M, Apache 2.0) on this Mac, for every language Apple's
# SpeechAnalyzer can't hear (Amharic, Zulu, Yoruba, Tibetan, Gaelic, … 1,600+). Offline once the model is here, no
# quota. Sill starts it on demand (speech.swift, OpenEars) and talks to it one JSON line at a time:
#   in   {"id": 1, "f32": "/tmp/x.f32", "script": "Ethi"?}   16 kHz mono float32 samples, raw; the script, when known
#   out  {"id": 1, "words": [{"w", "s", "e", "c", "t"}], "text": "…", "scripts": ["Ethi"]?}   times from the samples' start
# The model is language-agnostic (CTC: no language is asked for, none is told); it writes what it hears in the
# script the language is written in, and Sill tells the language from that text. It leaves after five quiet minutes.
# Setup (once): python3.10 -m venv ~/.local/share/recense/omni && …/bin/pip install omnilingual-asr torchaudio==2.8.0
#               brew install libsndfile;  the model (1.2 GB) downloads to ~/.cache/fairseq2 on first use.
import json, os, select, sys, time
import numpy as np
import torch
from torch.nn.functional import layer_norm

CARD = os.environ.get("OMNI_CARD", "omniASR_CTC_300M")
SR, HOP = 16000, 320                     # wav2vec2's feature encoder: one frame per 20 ms
PIECE = 12.0                              # the model takes at most 40 s, but hears best (and fastest) in ~12 s pieces
BATCH = 4                                 # pieces padded to one shape and heard together: MPS compiles that shape once
IDLE = 300


def out(o):
    sys.stdout.write(json.dumps(o, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def load():
    from fairseq2.models.hub import load_model
    from fairseq2.data.tokenizers.hub import load_tokenizer
    dev = torch.device("mps" if torch.backends.mps.is_available() and os.environ.get("OMNI_CPU") is None else "cpu")
    # half precision on the GPU: 0.6 GB in memory instead of 1.2 (this Mac has 8 GB, shared with Demucs and Sill)
    dtype = torch.float16 if dev.type == "mps" and os.environ.get("OMNI_FP32") is None else torch.float32
    model = load_model(CARD, device=dev, dtype=dtype).eval()
    tok = load_tokenizer(CARD)
    dec = tok.create_decoder(skip_special_tokens=True)
    n = tok.vocab_info.size
    chars = [dec(torch.tensor([i])) for i in range(n)]
    for i in (0, 1, 2, 3):                # blank (bos), pad, eos, unk
        chars[i] = ""
    # each letter's script, for hearing in one script (see `masks`)
    global SCRIPT_OF
    SCRIPT_OF = [script(c) for c in chars]
    return model, chars, dev


NAMES = {"ETHIOPIC": "Ethi", "ARABIC": "Arab", "HEBREW": "Hebr", "SYRIAC": "Syrc", "THAANA": "Thaa", "DEVANAGARI": "Deva",
         "GUJARATI": "Gujr", "BENGALI": "Beng", "GURMUKHI": "Guru", "ORIYA": "Orya", "TAMIL": "Taml", "TELUGU": "Telu",
         "KANNADA": "Knda", "MALAYALAM": "Mlym", "SINHALA": "Sinh", "THAI": "Thai", "LAO": "Laoo", "KHMER": "Khmr",
         "MYANMAR": "Mymr", "TIBETAN": "Tibt", "MONGOLIAN": "Mong", "GEORGIAN": "Geor", "ARMENIAN": "Armn", "GREEK": "Grek",
         "CYRILLIC": "Cyrl", "LATIN": "Latn", "CJK": "Hani", "HIRAGANA": "Jpan", "KATAKANA": "Jpan", "HANGUL": "Kore",
         "TIFINAGH": "Tfng", "COPTIC": "Copt", "CHEROKEE": "Cher", "CANADIAN": "Cans", "NKO": "Nkoo", "VAI": "Vaii"}
# scripts a model hearing without a language confuses with each other (Ge'ez and Arabic both write Semitic sounds)
SCRIPT_OF = []
MASKS = None


def script(c):
    import unicodedata
    if not c or not c.strip():
        return None
    try:
        n = unicodedata.name(c[0])
    except ValueError:
        return None
    for k, v in NAMES.items():
        if n.startswith(k) or n.startswith("LATIN") and v == "Latn":
            return v
    return None if unicodedata.category(c[0])[0] in "PNSZ" else "Zzzz"


def masks(dev, n):
    """For each script: the tokens it may write (its letters, plus the blank, the space and the scriptless marks)."""
    common = torch.tensor([i in (0, 4) or SCRIPT_OF[i] is None for i in range(n)])
    out = {}
    for sc in set(x for x in SCRIPT_OF if x and x != "Zzzz"):
        out[sc] = (common | torch.tensor([x == sc for x in SCRIPT_OF])).to(dev)
    return out


def cuts(x):
    """Where to cut a recording into pieces: the quietest 20 ms between 60 % and all of PIECE in."""
    n = len(x)
    if n <= PIECE * SR:
        return [0, n]
    f = HOP
    rms = np.sqrt(np.convolve(x[: n // f * f].reshape(-1, f).astype(np.float64) ** 2 @ np.ones(f) / f, np.ones(5) / 5, "same"))
    out, a = [0], 0
    while n - a > PIECE * SR:
        lo, hi = (a + int(0.6 * PIECE * SR)) // f, (a + int(PIECE * SR)) // f
        b = (lo + int(np.argmin(rms[lo:hi]))) * f
        out.append(b)
        a = b
    out.append(n)
    return out


def decode(chars, ids, conf, off):
    """Greedy CTC: a letter where the best token changes; words split at the space token. Each letter keeps its time
    (`t`), so a script written without spaces (Chinese, Thai, Khmer, Tibetan…) can be cut into words by Sill."""
    words, cur, prev = [], None, -1
    for t, i in enumerate(ids):
        if i == prev:
            if cur is not None and i not in (0, 4):
                cur["e"] = off + (t + 1) * HOP / SR; cur["_c"].append(conf[t])
            continue
        prev = i
        if i == 0 or chars[i] == "":
            continue
        if i == 4 or chars[i].strip() == "":
            if cur:
                words.append(cur); cur = None
            continue
        ts = off + t * HOP / SR
        if cur is None:
            cur = {"w": "", "s": ts, "e": ts, "_c": [], "t": []}
        cur["w"] += chars[i]; cur["e"] = ts + HOP / SR; cur["_c"].append(conf[t]); cur["t"] += [round(ts, 2)] * len(chars[i])   # one per code point
    if cur:
        words.append(cur)
    return words


@torch.no_grad()
def hear(model, chars, dev, x, hint=None):
    """`hint`: the script the recording's language is written in, when Sill knows it."""
    from fairseq2.nn.batch_layout import BatchLayout
    global MASKS
    bounds = [(a, b) for a, b in zip(cuts(x), cuts(x)[1:]) if b - a >= SR // 10]
    size = int(PIECE * SR)
    lps = []                                                   # each piece's log-probabilities, on the GPU
    for k in range(0, len(bounds), BATCH):
        group = bounds[k:k + BATCH]
        seqs = torch.zeros(len(group), size)
        for j, (a, b) in enumerate(group):
            piece = torch.from_numpy(x[a:b].copy()).float()
            seqs[j, : b - a] = layer_norm(piece, piece.shape)
        seqs = seqs.to(dev, next(model.parameters()).dtype)
        logits, _ = model(seqs, BatchLayout(seqs.shape, seq_lens=[b - a for a, b in group], device=dev))
        lp = torch.log_softmax(logits.float(), dim=-1)
        for j, (a, b) in enumerate(group):
            lps.append(lp[j, : (b - a) // HOP + 1])
    if not lps:
        return [], None
    if MASKS is None:
        MASKS = masks(dev, lps[0].shape[-1])
    # Told no language, the model may drift between scripts that write the same sounds (an Amharic song half in
    # Ge'ez, half in Arabic letters). The recording is heard in the script whose letters keep the most of what it
    # heard: each candidate (the scripts it wrote, the hint) scores the best path through its own letters only, and
    # one more script beside it (English in an Amharic song) has to earn its place.
    best_ids = [lp.argmax(-1) for lp in lps]
    seen = {}
    for ids in best_ids:
        for i in ids.tolist():
            sc = SCRIPT_OF[i]
            if sc and sc != "Zzzz":
                seen[sc] = seen.get(sc, 0) + 1
    total = sum(seen.values())
    cands = [sc for sc, n in seen.items() if n >= 0.05 * total and sc in MASKS] or [max(seen, key=seen.get)] if seen else []
    if hint in MASKS and hint not in cands:
        cands.append(hint)
    chosen = None
    if len(seen) > 1 or (hint in MASKS and set(seen) != {hint}):
        full = sum(float(lp.max(-1).values.sum()) for lp in lps)
        def score(scs):
            m = MASKS[scs[0]]
            for sc in scs[1:]:
                m = m | MASKS[sc]
            return sum(float(lp.masked_fill(~m, -1e4).max(-1).values.sum()) for lp in lps)
        margin = 0.01 * abs(full) + 1.0
        # a known script is the recording's (Sill knows its language); otherwise each script the model wrote competes.
        # Latin may sit beside another (English in an Amharic song), two scripts that write the same sounds may not.
        firsts = [hint] if hint in MASKS else cands
        options = [(score([sc]), (sc,)) for sc in firsts]
        options += [(score([sc, "Latn"]) - margin, (sc, "Latn")) for sc in firsts if sc != "Latn" and "Latn" in MASKS
                    and ("Latn" in cands)]
        chosen = max(options)[1]
        if hint not in MASKS and len(seen) == 1 and chosen == tuple(seen):
            chosen = None
    words = []
    for (a, b), lp in zip(bounds, lps):
        if chosen:
            m = MASKS[chosen[0]]
            for sc in chosen[1:]:
                m = m | MASKS[sc]
            lp = lp.masked_fill(~m, -1e4)
        top, ids = lp.max(-1)
        words += decode(chars, ids.cpu().tolist(), torch.exp(top).cpu().tolist(), a / SR)
    # a word lasts until the next begins (a CTC letter is a spike, not a span), at most half a second after its last letter
    for k, w in enumerate(words):
        nxt = words[k + 1]["s"] if k + 1 < len(words) else w["e"] + 0.5
        w["e"] = round(max(w["e"] + 0.08, min(nxt - 0.02, w["e"] + 0.5)), 3)
        w["s"] = round(w["s"], 3)
        w["c"] = round(float(np.mean(w.pop("_c"))), 3) if w.get("_c") else 0.5
    return words, (list(chosen) if chosen else None)


def main():
    t0 = time.time()
    model, chars, dev = load()
    out({"ready": True, "card": CARD, "device": str(dev), "load": round(time.time() - t0, 1)})
    while True:
        r, _, _ = select.select([sys.stdin], [], [], IDLE)
        if not r:
            return
        line = sys.stdin.readline()
        if not line:
            return
        q = {}
        try:
            q = json.loads(line)
            x = np.fromfile(q["f32"], dtype=np.float32)
            t0 = time.time()
            ws, scripts = hear(model, chars, dev, x, q.get("script"))
            out({"id": q.get("id"), "words": ws, "text": " ".join(w["w"] for w in ws), "scripts": scripts, "took": round(time.time() - t0, 2)})
        except Exception as e:
            out({"id": q.get("id"), "error": f"{type(e).__name__}: {e}"})


if __name__ == "__main__":
    main()
