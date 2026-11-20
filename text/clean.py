#!/usr/bin/env python3
# Derived from Spec: FEAT-01
"""clean.py <profile> <input.txt> <outdir>
Runs plain text through a rules profile (rules/<profile>.toml + what it extends).
Writes <outdir>/clean.md (reading copy) and <outdir>/speech.md (voice copy).
Standard library only."""
import re, sys, tomllib, pathlib

RULES = pathlib.Path(__file__).parent / "rules"

def load(name):
    d = tomllib.loads((RULES / f"{name}.toml").read_text())
    meta, rules = d.get("meta", {}), d.get("rule", [])
    if meta.get("extends"):
        pmeta, prules = load(meta["extends"])
        meta, rules = {**pmeta, **meta}, prules + rules
    return meta, rules

def stage(rules, name):
    return [(r, re.compile(r["match"])) for r in rules if r["stage"] == name]

ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()

def two(n):  # 0-99 in words
    return ONES[n] if n < 20 else TENS[n // 10] + ("-" + ONES[n % 10] if n % 10 else "")

def digits(d):  # "07" -> "oh seven"
    return " ".join("oh" if c == "0" else ONES[int(c)] for c in d)

def pairs(d):  # "1901" -> "nineteen oh-one", "609" -> "six oh-nine", "2100" -> "twenty-one hundred"
    if len(d) <= 2:
        return two(int(d))
    hi, lo = d[:-2], d[-2:]
    if lo == "00":
        return two(int(hi)) + " hundred"
    return two(int(hi)) + " " + ("oh-" + ONES[int(lo[1])] if lo[0] == "0" else two(int(lo)))

def say(m, how):
    whole, dec, sub = m.group("int"), m.group("dec"), m.group("sub")
    out = pairs(whole) if how == "section" else (two(int(whole)) if len(whole) <= 2 else whole)
    for part in (dec or "").split(".")[1:]:
        out += " point " + digits(part)
    for letter in re.findall(r"\(([a-z0-9]+)\)", sub or ""):
        out += " " + letter
    return out

def apply(text, rules):
    for r, rx in rules:
        if r["action"] == "replace":
            text = rx.sub(r.get("with", ""), text)
        elif r["action"] == "say":
            text = rx.sub(lambda m: say(m, r["how"]), text)
    return text

def pdf_text(path, meta):
    """Reading order for multi-column pages: top band, then each column top to bottom."""
    import subprocess
    info = subprocess.run(["pdfinfo", path], capture_output=True, text=True).stdout
    pages = int(re.search(r"Pages:\s+(\d+)", info).group(1))
    w, h = map(float, re.search(r"Page size:\s+([\d.]+) x ([\d.]+)", info).groups())
    cols, band = int(meta.get("columns", 1)), float(meta.get("top_band_pt", 0))
    def crop(p, x, y, cw, ch):
        return subprocess.run(["pdftotext", "-f", str(p), "-l", str(p), "-x", str(int(x)), "-y", str(int(y)),
                               "-W", str(int(cw)), "-H", str(int(ch)), path, "-"],
                              capture_output=True, text=True).stdout
    out = []
    for p in range(1, pages + 1):
        if band:
            out.append(crop(p, 0, 0, w, band))
        for c in range(cols):
            out.append(crop(p, c * w / cols, band, w / cols, h - band))
    return "\n".join(out)

def run(profile, src, path=None):
    meta, rules = load(profile)
    if path and str(path).endswith(".pdf"):
        src = pdf_text(str(path), meta)
    lines = src.splitlines()

    # page: drop or edit one line at a time
    out = []
    for ln in lines:
        s = ln.strip()
        dropped = False
        for r, rx in stage(rules, "page"):
            if r["action"] == "drop" and rx.search(s):
                dropped = True; break
        if not dropped:
            out.append(s)
    lines = out

    # heading: mark chapters/sections; join wrapped titles up to the `until` marker
    heads = stage(rules, "heading")
    blocks, i, seen_section = [], 0, False
    while i < len(lines):
        s, hit = lines[i], None
        for r, rx in heads:
            m = rx.match(s)
            if not m:
                continue
            title, j = s, i
            if r.get("until"):
                end = re.compile(r["until"])
                while not end.search(title) and j < i + 3 and j + 1 < len(lines):
                    j += 1; title += " " + lines[j]
                if not end.search(title):
                    continue
            if r.get("titles") and not m.group(m.re.groups).strip() and m.group(1) in r["titles"]:
                title += " " + r["titles"][m.group(1)]  # title printed apart from its "Chapter N" line
            if r.get("join_next"):
                nxt = re.compile(r["join_next"])
                while j < i + 2 and j + 1 < len(lines) and lines[j + 1] and nxt.match(lines[j + 1]):
                    j += 1; title += " " + lines[j]
            hit = (r["with"], title, j); break
        if hit:
            level, title, j = hit
            if level != "#":
                seen_section = True
            blocks.append(("H", level, title)); i = j + 1; continue
        if meta.get("skip_leading_toc") and blocks and not seen_section:
            i += 1; continue  # inside the chapter's own table of contents
        blocks.append(("T", None, s)); i += 1

    # page replace rules run after headings are joined, so a heading's `until` marker is still there
    reps = [(r, rx) for r, rx in stage(rules, "page") if r["action"] == "replace"]
    def rep(t):
        for r, rx in reps:
            t = rx.sub(r.get("with", ""), t)
        return t.strip()
    blocks = [(k, lv, rep(t)) for k, lv, t in blocks]

    # reflow: blank line ends a paragraph; join hyphenated breaks and wrapped lines
    md, para = [], []
    def flush():
        if para:
            t = " ".join(para)
            md.append(re.sub(r"(\w)- (\w)", r"\1\2", t)); para.clear()
    for kind, level, s in blocks:
        if kind == "H":
            flush(); md.append(f"{level} {s}")
        elif not s:
            flush()
        elif re.match(r"^\(?([a-z]|[ivx]+|\d+|[A-Z])\)\s", s) and para:
            flush(); para.append(s)  # list item like "(b)" or "(iii)" starts a paragraph
        else:
            para.append(s)
    flush()

    text_rules = stage(rules, "text")
    clean = [apply(p, text_rules).strip() for p in md]
    clean = [p for p in clean if p]
    speech_rules = stage(rules, "speech")
    speech = [apply(p, speech_rules) for p in clean]
    return "\n\n".join(clean) + "\n", "\n\n".join(speech) + "\n"

if __name__ == "__main__":
    profile, src, outdir = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
    outdir.mkdir(parents=True, exist_ok=True)
    text = "" if src.suffix.lower() == ".pdf" else src.read_text()
    clean, speech = run(profile, text, path=src)
    (outdir / "clean.md").write_text(clean)
    (outdir / "speech.md").write_text(speech)
