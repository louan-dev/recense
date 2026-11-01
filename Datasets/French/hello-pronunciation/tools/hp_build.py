"""Build Datasets/French/hello-pronunciation/index.json from the Hello Pronunciation PDF + Wix track list.
usage: python -I hp_build.py <pdf> <tracks.tsv> <out index.json> <out diagrams-plan.json>
Media are referenced as r2://recense-tmp/hello-pronunciation/...; uploading is done by separate scripts."""
import json, re, sys, unicodedata
from collections import defaultdict

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import pymupdf
import hp_tables as T

R2 = "r2://recense-tmp/hello-pronunciation"
SOUND_PAGES = range(29, 45)
# visually reviewed 2026-10-27 (contact sheet): decorative illustrations, not mouths -> (page, image y0)
DECOR = {(37, 1950), (40, 2083), (44, 719), (44, 834)}
SLUG = {"a": "a", "e": "e-closed", "ɛ": "e-open", "o": "o-closed", "ɔ": "o-open", "i": "i", "ø": "eu-closed",
        "œ": "eu-open", "ə": "schwa", "y": "u", "ɑ̃": "an", "œ̃": "un", "ɛ̃": "in", "ɔ̃": "on", "j": "yod",
        "ɥ": "hu", "w": "w", "f": "f", "ɲ": "gn", "ʀ": "r", "C": "letter-c", "G": "letter-g", "S": "letter-s"}
nfc = lambda s: unicodedata.normalize("NFC", s) if s else s
clean = lambda s: " ".join((s or "").split())


def ipa_of(s):
    m = re.search(r"\[([^\]]+)\]", s or "")
    return nfc(m.group(1)) if m else None


def analogy_of(text):
    """English analogy as printed: 'the a in “large”' -> letters a, english_word large. Never guessed."""
    if not text:
        return None
    sent = next((s.strip() for s in re.split(r"(?<=[.!?])\s+", text)
                 if re.search(r"[“\"][^”\"]+[”\"]", s) and re.search(r"(?i)\b(like|similar|same as|pronounce the|say)\b", s)), None)
    if not sent:
        return {"english_word": None, "letters": None, "text": None}
    m = re.search(r"(?:\bthe\s+(?:letter\s+)?[“\"]?([A-Za-z]{1,3})[”\"]?|[“\"]([A-Za-z]{1,3})[”\"])\s+in\s+(?:English\s+)?(?:like\s+in\s+)?(?:the\s+words?\s+)?[“\"]([^”\"]+)[”\"]", sent)
    if m:
        return {"english_word": m.group(3).strip(" .,"), "letters": m.group(1) or m.group(2), "text": sent}
    return {"english_word": None, "letters": None, "text": sent}


def main():
    pdf, tracks_tsv, out_index, out_plan = sys.argv[1:5]
    manifest = json.load(open(sys.argv[5])) if len(sys.argv) > 5 else {}
    d = pymupdf.open(pdf)
    tracks = {}
    for line in open(tracks_tsv, encoding="utf-8"):
        h, dur, title = line.rstrip("\n").split("\t", 2)
        tracks[h] = {"title": clean(title), "site_duration_s": int(dur)}
    audio = lambda h: f"{R2}/audio/{h}.m4a"

    # ---- tables + all links per page
    tables, link_pages, links_by_page = [], defaultdict(set), {}
    for pno in range(1, len(d) + 1):
        pg = d[pno - 1]
        t, _ = T.page_tables(pg, pno)
        tables += t
        links_by_page[pno] = T.links(pg)
        for l in links_by_page[pno]:
            link_pages[l["hash"]].add(pno)

    # ---- reading-order anchors on the sound pages
    sounds, order, general = {}, [], []
    events = []  # (page, y, kind, payload)
    for t in tables:
        if t["page"] in SOUND_PAGES:
            events.append((t["page"], t["y"][0], "table", t))
    for pno in SOUND_PAGES:
        pg = d[pno - 1]
        for b in pg.get_text("blocks"):
            x0, y0, x1, y1, txt = b[:5]
            txt = clean(txt)
            if not txt or y0 > 2440:
                continue
            if re.match(r"HOW TO PRONOUNCE", txt):
                events.append((pno, y0, "howto", txt))
            elif txt.startswith("Attention !"):
                events.append((pno, y0, "attention", txt))
            elif 50 <= x0 <= 70 and re.match(r"(THE (NASAL )?SOUNDS?|CLOSED|OPEN|THE LETTER|WORDS FOR|SENTENCE FOR|The Pronunciation of R|Les (Voyelles|Semi-Voyelles|Consonnes))", txt):
                events.append((pno, y0, "group", txt))
            elif 115 <= x0 <= 135 and txt.isupper() and len(txt) > 3:
                events.append((pno, y0, "step", txt))
            else:
                events.append((pno, y0, "text", (x0, txt)))
    events.sort(key=lambda e: (e[0], e[1], e[2] != "group"))

    def get(key, name=None):
        if key not in sounds:
            sid = SLUG.get(key, key)
            sounds[key] = {"id": sid, "ipa": key if key not in ("C", "G", "S") else None,
                           "kind": "letter_rule" if key in ("C", "G", "S") else ("consonant" if key in ("f", "ɲ", "ʀ") else "vowel" if key not in ("j", "ɥ", "w") else "semi_vowel"),
                           "name": name, "spellings": [], "analogy": None, "how_to": None, "intro": None, "mouth_steps": [],
                           "audio": None, "examples": [], "notes": [], "diagrams": [], "source": {"pdf_pages": []}, "flags": [],
                           "_y": []}
            order.append(key)
        if name and not sounds[key]["name"]:
            sounds[key]["name"] = name
        return sounds[key]

    cur, mode, buf, att = None, None, [], None
    bounds = []
    general_cur = None
    plan = []

    def flush():
        nonlocal buf, mode, att
        if cur is None or not buf:
            buf = []
            return
        s = sounds[cur]
        text = clean(" ".join(buf))
        if mode == "howto" and not s["how_to"]:
            s["how_to"] = text
        elif mode == "intro":
            s["intro"] = clean(((s["intro"] or "") + " " + text))
        elif mode == "attention" and att is not None:
            att["text"] = clean(att["text"] + " " + text)
        buf = []

    for pno, y, kind, p in events:
        if cur:
            sp = sounds[cur]["source"]["pdf_pages"]
            if pno not in sp:
                sp.append(pno)
        if kind == "group":
            flush()
            key = ipa_of(p)
            letter = re.match(r"THE LETTER ([A-Z])", p)
            if letter:
                key = letter.group(1)
            if p.startswith("The Pronunciation of R"):
                key = "ʀ"
            if key and (key in SLUG) and not p.startswith("THE SOUNDS"):
                cur = key
                get(key, p)
                sounds[key]["_y"].append((pno, y))
                mode = "intro"
            elif p.startswith(("WORDS FOR", "SENTENCE FOR")):
                mode = "practice"
            else:
                general_cur = {"page": pno, "heading": p, "text": "", "_y": [(pno, y)], "diagrams": []}
                general.append(general_cur)
                bounds.append((pno, y))
                mode = "general"
            continue
        if kind == "howto":
            flush()
            key = ipa_of(p)
            if key in SLUG:
                cur = key
                get(key)["_y"].append((pno, y))
                mode = "howto"
            else:  # e.g. HOW TO PRONOUNCE NASAL VOWELS?
                general_cur = {"page": pno, "heading": p, "text": "", "mouth_steps": [], "_y": [(pno, y)], "diagrams": []}
                general.append(general_cur)
                bounds.append((pno, y))
                mode = "general"
            continue
        if kind == "table":
            if mode == "howto" and p.get("x0", 0) > 400:  # table set to the right of the how-to prose (e.g. [ɥ] p38)
                sounds[cur]["_tables"] = sounds[cur].get("_tables", []) + [p]
                continue
            flush()
            key = ipa_of(p["header"]) or clean(p["header"])
            key = nfc(key)
            if key in SLUG:
                cur = key
                s = get(key)
                if len(p["header"]) > 4 and re.search(r"[A-Z]{3}", p["header"]):
                    s["name"] = p["header"]
                s["_tables"] = s.get("_tables", []) + [p]
                if pno not in s["source"]["pdf_pages"]:
                    s["source"]["pdf_pages"].append(pno)
            mode = "table"
            continue
        if kind == "attention":
            flush()
            if mode == "general" and general_cur is not None:
                pass
            att = {"text": "", "audio": [], "pdf_page": pno, "_y": y}
            if cur:
                sounds[cur]["notes"].append(att)
            mode = "attention"
            continue
        if kind == "step":
            flush()
            tgt = general_cur["mouth_steps"] if mode == "general" and general_cur else (sounds[cur]["mouth_steps"] if cur else None)
            if tgt is not None and p not in tgt:
                tgt.append(p)
            continue
        if kind == "text":
            x0, txt = p
            if re.fullmatch(r"[1-4]|→|VS\.|TRANSL\.", txt):
                continue
            if mode == "general" and general_cur is not None:
                general_cur["text"] = clean(general_cur["text"] + " " + txt)
            elif mode in ("howto", "intro") and x0 < 110:
                buf.append(txt)
            elif mode == "attention" and 95 <= x0 <= 300:
                buf.append(txt)
            elif mode == "practice" and cur:
                sounds[cur].setdefault("practice", []).append(txt)
    flush()

    # ---- tables -> spellings + examples
    used = set()
    for key in order:
        s = sounds[key]
        sub = None
        for t in s.pop("_tables", []):
            for r in t["rows"]:
                if "subheading" in r or (not r["audio"] and r["examples"] and all(not e["ipa"] and not e["translation"] for e in r["examples"])):
                    sub = clean(d[t["page"] - 1].get_textbox(pymupdf.Rect(40, r["y"][0] + 1, 1560, r["y"][1] - 1))) or \
                        clean(r.get("subheading") or ((r["spelling"] or "") + " " + " ".join(e["word"] for e in r["examples"])))
                    continue
                parts = [x.strip() for x in (r["spelling"] or "").split(" / ")]
                letters, cond = parts[0] if parts else None, clean(" ".join(parts[1:])).strip("()") or None
                q = re.search(r"[“\"]([^”\"]{1,4})[”\"]", r["spelling"] or "")
                if letters and " " in letters and q:  # 'In the conjunction “et”' -> letters et
                    letters, cond = q.group(1), clean((r["spelling"] or "").replace(" / ", " "))
                if sub:
                    cond = clean(f"{sub} {cond or ''}")
                sp = {"letters": letters, "condition": cond}
                if key in ("C", "G", "S"):
                    sp["sound"] = ipa_of(letters)
                    sp["letters"] = key.lower()
                s["spellings"].append(sp)
                for h in r["audio"]:
                    used.add(h)
                for e in r["examples"]:
                    ex = {"word": nfc(e["word"]), "ipa": nfc(e["ipa"]), "translation": e["translation"],
                          "spelling": sp["letters"], "audio": audio(r["audio"][0]) if r["audio"] else None,
                          "audio_scope": "row" if len(r["examples"]) > 1 else "word", "pdf_page": t["page"]}
                    if sp.get("sound"):
                        ex["sound"] = sp["sound"]
                    fl = []
                    if "ã" in (ex["ipa"] or ""):
                        fl.append("book prints ã (U+00E3) here but ɑ̃ elsewhere; kept as printed (checked visually)")
                    if re.search(r"\[[^\]]*c", ex["ipa"] or ""):
                        fl.append("book prints c inside the IPA; [k] expected; kept as printed")
                    if not r["audio"]:
                        fl.append("no audio link on this row")
                    if fl:
                        ex["flags"] = fl
                    if len(r["audio"]) > 1:
                        ex.setdefault("flags", []).append("row has %d audio links" % len(r["audio"]))
                    s["examples"].append(ex)

    # ---- sound-level clip ("T7 - The Sound [x]") and note clips, matched by site title
    by_title = {v["title"]: h for h, v in tracks.items()}
    for key in order:
        s = sounds[key]
        nm = {"C": "T8 - The Sound C", "G": "T8 - The Sound G", "S": "T8 - The Sound S", "ʀ": "T8 - How to pronounce [ʀ]",
              "ɲ": "T8 - The Sound ɲ"}.get(key, f"T7 - The Sound [{key}]")
        h = by_title.get(nm)
        if h:
            s["audio"] = audio(h)
            used.add(h)
        elif key not in ("C", "G", "S", "f"):
            s["flags"].append("no sound-level clip title found")
        for n in s["notes"]:
            n.pop("_y", None)
        # note clips: titles '<prefix> - Attention - <word>' -> note containing that word
        pref = {"C": "T8 - The Sound C", "G": "T8 - The Sound G", "S": "T8 - The Sound S"}.get(key, f"T7 - The Sound [{key}]")
        for h, v in tracks.items():
            t = v["title"]
            if t.startswith(pref + " - Attention"):
                tail = clean(t.split("Attention", 1)[1].strip(" -")).lower()
                tail = re.sub(r"^\d+\s*-\s*", "", tail)
                words = [w for w in re.findall(r"\w+", tail) if len(w) > 2]
                elsewhere = [(k2, n) for k2 in order for n in sounds[k2]["notes"] if words and all(w in n["text"].lower() for w in words)]
                own = [n for n in s["notes"] if words and all(w in n["text"].lower() for w in words)]
                if not own and elsewhere and elsewhere[0][0] != key:
                    elsewhere[0][1]["audio"].append({"audio": audio(h), "title": t})
                    elsewhere[0][1].setdefault("flags", []).append(f"clip '{t}' is filed under another sound on the site; attached here by its words")
                    used.add(h)
                    continue
                hit = [n for n in s["notes"] if tail and tail.split(" ")[0] in n["text"].lower()] or \
                      ([s["notes"][int(tail) - 1]] if tail.isdigit() and int(tail) <= len(s["notes"]) else []) or \
                      (s["notes"][-1:] if s["notes"] else [])
                if hit:
                    hit[0]["audio"].append({"audio": audio(h), "title": t})
                    used.add(h)
                    if not tail or tail.isdigit() or tail.split(" ")[0] not in hit[0]["text"].lower():
                        hit[0].setdefault("flags", []).append(f"clip '{t}' attached by position, check")

    # ---- row order vs site numbering ("T7 - The Sound [a] - 3" should be row 3)
    for key in order:
        s = sounds[key]
        rows = []
        for e in s["examples"]:
            if e["audio"] and e["audio"] not in rows:
                rows.append(e["audio"])
        for i, a in enumerate(rows, 1):
            t = tracks.get(a.rsplit("/", 1)[1][:-4], {}).get("title", "")
            m = re.search(r" - (\d+)$", t)
            if m and int(m.group(1)) != i:
                s["flags"].append(f"row {i} clip is titled '{t}' (site numbering differs)")
            e_t = [e for e in s["examples"] if e["audio"] == a]
            for e in e_t:
                e["audio_title"] = t

    # ---- diagrams: lips photos + mouth cross-section panels in each sound's section range
    sections = [(sounds[k]["_y"][0], sounds[k], sounds[k]["id"]) for k in order if sounds[k]["_y"]] + \
               [(g["_y"][0], g, "general-p%d" % g["page"]) for g in general]
    sections.sort(key=lambda x: x[0])
    for i, ((p0, y0), s, sid) in enumerate(sections):
        nxt = sections[i + 1][0] if i + 1 < len(sections) else (45, 0)
        for pno in range(p0, min(nxt[0], 44) + 1):
            pg = d[pno - 1]
            lo = y0 - 120 if pno == p0 else 0
            hi = nxt[1] - 60 if pno == nxt[0] else 2500
            draws = [it[1] for dr in pg.get_drawings() if dr.get("fill") for it in dr["items"] if it[0] == "re"]
            seen = set()
            for im in pg.get_image_info(xrefs=True):
                b = pymupdf.Rect(im["bbox"])
                if b.width < 150 or not (lo <= b.y0 < hi) or (round(b.x0), round(b.y0)) in seen:
                    continue
                seen.add((round(b.x0), round(b.y0)))
                ar = im["width"] / im["height"]
                if (pno, round(b.y0)) in DECOR:
                    continue
                if abs(im["width"] - 604) < 6 and abs(im["height"] - 747) < 6:
                    panel = [r for r in draws if r.contains(b) and r.width < 1000] or [pymupdf.Rect(b.x0 - 190, b.y0 - 150, b.x1 + 90, b.y1 + 60)]
                    clip, kindn = max(panel, key=lambda r: r.get_area()), "cross_section"
                elif ar >= 1.3:
                    clip, kindn = pymupdf.Rect(b.x0 - 10, b.y0 - 10, b.x1 + 10, b.y1 + 10), "lips"
                else:
                    continue
                name = f"{sid}_{kindn}_p{pno}.png"
                if any(p["name"] == name for p in plan):
                    name = name.replace(".png", f"_{round(b.y0)}.png")
                plan.append({"name": name, "page": pno, "clip": [round(v) for v in clip], "sound": sid, "kind": kindn,
                             "xref": im["xref"] if kindn == "lips" else None, "y0": round(b.y0),
                             "aspect": round(ar, 2)})
                s["diagrams"].append({"kind": kindn, "r2": f"{R2}/diagrams/{name}", "pdf_page": pno,
                                      **({"flags": ["lips/decoration aspect borderline, check"]} if kindn == "lips" and ar < 1.45 else {})})

    for g in general:
        g.pop("_y", None)
    for key in order:
        s = sounds[key]
        s.pop("_y", None)
        s["analogy"] = analogy_of(s["how_to"])
        if s["analogy"] and not s["analogy"]["english_word"]:
            s["flags"].append("analogy: only a descriptive sentence, no 'the X in <word>'" if s["analogy"]["text"]
                              else "no English analogy printed for this sound")
        if not s["name"]:
            g = next((g["heading"] for g in general if s["ipa"] and f"[{s['ipa']}]" in nfc(g["heading"])), None)
            s["name"] = g
        if any(e["ipa"] and "ʀ" in e["ipa"] for e in s["examples"]):
            s["ipa_r_note"] = "IPA keeps the book's ʀ (U+0280) for every French R; see source p43"
        s["source"]["pdf_pages"].sort()

    # ---- remaining clips: lessons (themes 1-6, 8 intro/R, 9, 10) with the text printed beside the link
    clips = []
    for h, v in tracks.items():
        if h in used:
            continue
        near = []
        for pno in sorted(link_pages[h]):
            pg = d[pno - 1]
            for l in links_by_page[pno]:
                if l["hash"] == h:
                    r = l["rect"]
                    band = pymupdf.Rect(40, r.y0 - 30, r.x0 - 5 if r.x0 > 500 else 1560, r.y1 + 30)
                    txt = clean(" ".join(x[2] for x in T.lines_in(pg, band)))
                    near.append({"pdf_page": pno, "link_kind": l["kind"], "text_beside_link": txt[:400]})
        theme = re.match(r"(?:T|Thème )(\d+)", v["title"])
        clips.append({"title": v["title"], "theme": int(theme.group(1)) if theme else 1, "audio": audio(h), "pdf": near,
                      **({"flags": ["not linked from the PDF"]} if not near else {})})
    clips.sort(key=lambda c: (c["theme"], min([n["pdf_page"] for n in c["pdf"]] or [99])))
    for key in order:
        s_ = sounds[key]
        rel = [c["title"] for c in clips if s_["ipa"] and f"[{s_['ipa']}]" in nfc(c["title"])]
        if rel:
            s_["related_lessons"] = rel

    index = {
        "title": "Hello Pronunciation reference set",
        "source": {"book": "Hello Pronunciation: Mastering the Sounds of Spoken French", "authors": ["Cécilia Jourdan", "Marie-Lola Sendra"],
                   "publisher": "Hello French NYC", "pdf": f"{R2}/source/hello-pronunciation.pdf",
                   "audio_page": "https://hellofrenchnyc.wixsite.com/hellofrench/hello-pronunciation-audio-collection",
                   "permission": "Owner confirmed Cécilia Jourdan's consent on 2026-10-27; private R2 bucket only."},
        "conventions": {
            "ipa": "As printed. French R is written ʀ (U+0280) throughout, as the book does (p43). Nasal vowels use combining U+0303, NFC.",
            "audio_scope": "row = one clip reads every example on that table row (usually 2 words); word = one example on its row",
            "audio": "r2:// paths are objects in the private recense-tmp bucket; original Wix m4a uploads (key = Wix file hash)",
            "clips": "keyed by Wix file hash; duration/format measured with ffprobe on the uploaded bytes (Wix player durations were wrong, not kept)",
            "diagrams": "lips = the book's photo (PNG with alpha); cross_section = the drawn panel rendered with its numbered markers. Marker 1 (lips) often sits on the lips photo, so some panels show only 2-4. Decorative illustrations (cheese, bicycle, 'Bonjour') were excluded after visual review.",
            "names": "name = the book's heading for the sound or its table",
            "flags": "anything the extractor could not settle; owner spot-check"},
        "sounds": [sounds[k] for k in order],
        "general": general,
        "lessons": clips,
        "clips": {h: {"title": v["title"], "r2": audio(h), "pdf_pages": sorted(link_pages.get(h, [])),
                      **{k: manifest.get(h, {}).get(k) for k in ("duration_s", "bytes", "codec", "sample_rate", "channels")}}
                  for h, v in tracks.items()},
    }
    json.dump(index, open(out_index, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    json.dump(plan, open(out_plan, "w"), ensure_ascii=False, indent=1)
    allh = {e["audio"] for s in index["sounds"] for e in s["examples"] if e["audio"]} | \
           {s["audio"] for s in index["sounds"] if s["audio"]} | \
           {a["audio"] for s in index["sounds"] for n in s["notes"] for a in n["audio"]} | {c["audio"] for c in clips}
    print(f"sounds={len(order)} examples={sum(len(s['examples']) for s in index['sounds'])} notes={sum(len(s['notes']) for s in index['sounds'])} "
          f"diagrams={len(plan)} lessons={len(clips)} audio_refs={len(allh)}/253 flags={sum(len(s['flags']) for s in index['sounds'])}")


if __name__ == "__main__":
    main()
