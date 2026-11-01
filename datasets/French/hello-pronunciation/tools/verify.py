"""Cross-check index.json against the PDF text layer; print problems."""
import json, re, sys, unicodedata
import pymupdf
d = pymupdf.open(sys.argv[1]); x = json.load(open(sys.argv[2]))
norm = lambda s: re.sub(r"\s+", "", unicodedata.normalize("NFC", s or ""))
pagetxt = {}
def ptxt(n):
    if n not in pagetxt:
        pg = d[n - 1]
        pagetxt[n] = norm(pg.get_text())
    return pagetxt[n]
probs = []
for s in x["sounds"]:
    for e in s["examples"]:
        t = ptxt(e["pdf_page"])
        if norm(e["word"]) not in t:
            probs.append((s["id"], "word not in page text", e["word"]))
        ipa = e["ipa"] or ""
        if not ipa:
            probs.append((s["id"], "no ipa", e["word"]))
        elif ipa.count("[") != ipa.count("]") or not ipa.startswith("["):
            probs.append((s["id"], "ipa brackets", e["word"], ipa))
        elif "̃" in ipa and re.search(r"(^|[\s\[])̃", ipa):
            probs.append((s["id"], "floating tilde", e["word"], ipa))
        if not e["translation"]:
            probs.append((s["id"], "no translation", e["word"]))
        if not e["audio"]:
            probs.append((s["id"], "no audio", e["word"], e.get("flags")))
    for f in s["flags"]:
        probs.append((s["id"], "FLAG", f))
    for n in s["notes"]:
        for f in n.get("flags", []):
            probs.append((s["id"], "NOTE FLAG", f))
    for k in ("how_to",):
        if not s[k] and s["kind"] != "letter_rule":
            probs.append((s["id"], f"missing {k}"))
for p in probs:
    print(*p, sep=" | ")
print(len(probs), "problems")
