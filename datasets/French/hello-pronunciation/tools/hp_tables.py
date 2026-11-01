"""Extract WORDS|IPA|TRANSLATION|LISTEN tables from Hello Pronunciation with row-level audio links.
usage: python -I hp_tables.py <pdf> <out.json> [pages e.g. 9-58]"""
import json, re, sys
import pymupdf

HDR = ("WORDS", "IPA", "TRANSLATION", "LISTEN")
M4A = re.compile(r"730488_([0-9a-f]{32})\.m4a")


def clean(s):
    return " ".join((s or "").split())


def hlines(pg):
    ys = set()
    for dr in pg.get_drawings():
        for it in dr["items"]:
            if it[0] == "l" and abs(it[1].y - it[2].y) < 1 and abs(it[1].x - it[2].x) > 150:
                ys.add(round(it[1].y))
            elif it[0] == "re" and it[1].width > 150:
                ys.update((round(it[1].y0), round(it[1].y1)))
    return sorted(ys)


def vlines(pg, box):
    xs = set()
    for dr in pg.get_drawings():
        for it in dr["items"]:
            if it[0] == "l" and abs(it[1].x - it[2].x) < 1 and abs(it[1].y - it[2].y) > 30:
                if box.y0 - 5 <= min(it[1].y, it[2].y) and max(it[1].y, it[2].y) <= box.y1 + 5:
                    xs.add(round(it[1].x))
    return sorted(xs)


def links(pg):
    out = []
    for L in pg.get_links():
        m = M4A.search(L.get("uri", ""))
        if m:
            r = L["from"]
            kind = "badge" if r.width > 120 else ("inline" if r.width < 45 else "row")
            out.append({"hash": m.group(1), "rect": r, "kind": kind})
    return out


TILDE = "̃~˜"
_chars = {}


def page_chars(pg):
    """all glyphs on the page as (char, x0, y0, x1, y1, baseline, size), with detached nasal tildes re-attached"""
    if pg.number in _chars:
        return _chars[pg.number]
    cs = []
    for b in pg.get_text("rawdict")["blocks"]:
        for l in b.get("lines", []):
            for s in l["spans"]:
                for c in s["chars"]:
                    x0, y0, x1, y1 = c["bbox"]
                    if c["c"] == "̃" and cs and cs[-1][0].strip():
                        cs[-1][0] += "̃"  # zero-width combining tilde follows its vowel in stream order
                        continue
                    cs.append([c["c"], x0, y0, x1, y1, c["origin"][1], s["size"]])
    _chars[pg.number] = cs
    return cs


def cell_edges(pg, y0, y1):
    """x edges of filled table cells between y0 and y1"""
    xs = set()
    for dr in pg.get_drawings():
        for it in dr["items"]:
            if it[0] == "re" and y0 - 2 <= it[1].y0 <= y1 and it[1].height > 20 and it[1].width > 60:
                xs.update((round(it[1].x0), round(it[1].x1)))
    return sorted(xs)


def lines_in(pg, rect):
    """text lines [y0, y1, text] inside rect, grouped by baseline"""
    cs = [c for c in page_chars(pg) if rect.x0 <= (c[1] + c[3]) / 2 <= rect.x1 and rect.y0 <= c[5] <= rect.y1 + 2]
    cs.sort(key=lambda c: (round(c[5]), c[1]))
    lines = []
    for c in cs:
        for ln in lines:
            if abs(ln["base"] - c[5]) < c[6] * 0.35:
                ln["c"].append(c)
                break
        else:
            lines.append({"base": c[5], "c": [c]})
    out = []
    for ln in sorted(lines, key=lambda l: l["base"]):
        cc = sorted(ln["c"], key=lambda c: c[1])
        t = ""
        for prev, c in zip([None] + cc[:-1], cc):
            if prev is not None and c[1] - prev[3] > c[6] * 0.25 and not t.endswith(" ") and c[0] != " ":
                t += " "
            t += c[0]
        t = clean(t)
        if t:
            out.append([min(c[2] for c in cc), max(c[4] for c in cc), t])
    return out


def page_tables(pg, pno):
    words = pg.get_text("words")
    hdrs = [w for w in words if w[4] == "WORDS"
            and any(v[4] == "IPA" and abs((v[1] + v[3]) / 2 - (w[1] + w[3]) / 2) < 8 for v in words)]
    H = hlines(pg)
    L = links(pg)
    tables = []
    for hw in hdrs:
        hy = (hw[1] + hw[3]) / 2
        cols = {w[4]: w for w in words if w[4] in HDR and abs((w[1] + w[3]) / 2 - hy) < 8}
        if "IPA" not in cols:
            continue
        top = max([y for y in H if y <= hw[1]] or [hw[1] - 30])
        hb = min([y for y in H if y >= hw[3]] or [hw[3] + 30])
        # table body: consecutive ruling ys below header while gaps stay row-sized
        ys = [hb]
        for y in [y for y in H if y > hb]:
            if y - ys[-1] > 330:
                break
            ys.append(y)
        # stop at the next table header
        nxt = [w[1] for w in hdrs if w[1] > hw[3] + 5]
        if nxt:
            ys = [y for y in ys if y < min(nxt) - 5] or ys[:1]
        # column boundaries: midpoints between header word centres; spelling column left of WORDS
        cw = lambda w: (w[0] + w[2]) / 2
        order = sorted(cols, key=lambda k: cw(cols[k]))
        mids = {f"{a}|{b}": (cw(cols[a]) + cw(cols[b])) / 2 for a, b in zip(order, order[1:])}
        right = lambda k: mids.get(f"{k}|{order[order.index(k) + 1]}") if order.index(k) + 1 < len(order) else 1560
        b_sw = cw(cols["WORDS"]) - (right("WORDS") - cw(cols["WORDS"]))
        b_wi = right("WORDS")
        b_it = right("IPA")
        b_tl = right("TRANSLATION") if "TRANSLATION" in cols else b_it
        tx0 = 40
        E = cell_edges(pg, top, hb)
        snap = lambda x: min(E, key=lambda e: abs(e - x)) if E and min(abs(e - x) for e in E) < 120 else x
        inside = lambda k: [e for e in E if e < cw(cols[k])]  # nearest cell edge left of a header centre
        if E and all(inside(k) for k in ("WORDS", "IPA")):
            b_sw, b_wi, b_it_mid = inside("WORDS")[-1], inside("IPA")[-1], b_it
            b_it = inside("TRANSLATION")[-1] if "TRANSLATION" in cols and inside("TRANSLATION") else snap(b_it_mid)
            b_tl = inside("LISTEN")[-1] if "LISTEN" in cols and inside("LISTEN") else snap(b_tl)
            tx0 = E[0] - 5
        hdr_rect = pymupdf.Rect(tx0, top, b_sw, hb)
        sound_hdr = clean(pg.get_textbox(pymupdf.Rect(hdr_rect.x0, hdr_rect.y0 - 10, hdr_rect.x1, hdr_rect.y1)))
        rows = []
        for ya, yb in zip(ys, ys[1:]):
            if yb - ya < 25:
                continue
            band = lambda xa, xb: pymupdf.Rect(xa, ya + 1, xb, yb - 1)
            spelling = lines_in(pg, band(tx0, b_sw))
            wl = lines_in(pg, band(b_sw, b_wi))
            il = lines_in(pg, band(b_wi, b_it))
            tl = lines_in(pg, band(b_it, b_tl))
            if not (wl or il):
                full = lines_in(pg, band(tx0, b_tl))
                if full:  # sub-heading row spanning the table, e.g. "AT THE END OF WORDS ONLY:"
                    rows.append({"subheading": clean(pg.get_textbox(band(tx0, b_tl))) or " ".join(x[2] for x in full),
                                 "audio": [], "y": [ya, yb], "flags": []})
                continue
            examples = []
            for w in wl:
                near = lambda arr: [x for x in arr if abs((x[0] + x[1]) / 2 - (w[0] + w[1]) / 2) < 12]
                examples.append({"word": w[2], "ipa": " ".join(x[2] for x in near(il)) or None,
                                 "translation": " ".join(x[2] for x in near(tl)) or None, "_y": w[0]})
            used_t = {x[2] for e in examples for x in tl if e["translation"] and x[2] in e["translation"]}
            for x in tl:  # wrapped translation lines -> previous example
                if x[2] not in used_t:
                    prev = [e for e in examples if e["_y"] < x[0]]
                    if prev:
                        prev[-1]["translation"] = clean((prev[-1]["translation"] or "") + " " + x[2])
            used_i = {x[2] for e in examples for x in il if e["ipa"] and x[2] in e["ipa"]}
            orphan_ipa = [x[2] for x in il if x[2] not in used_i]
            rl = [l for l in L if l["kind"] == "row" and ya <= (l["rect"].y0 + l["rect"].y1) / 2 <= yb
                  and l["rect"].x0 >= b_tl - 40]
            for e in examples:
                e.pop("_y")
            rows.append({"spelling": " / ".join(s[2] for s in spelling) or None, "examples": examples,
                         "audio": [l["hash"] for l in rl], "y": [ya, yb],
                         "flags": (["orphan_ipa: " + "; ".join(orphan_ipa)] if orphan_ipa else [])
                         + ([] if rl else ["no_row_audio"]) + (["multi_row_audio"] if len(rl) > 1 else [])})
        last = max([i for i, r in enumerate(rows) if r["audio"]] or [-1])
        rows = rows[:last + 1]  # anything after the last audio row is notes/next section, not table
        tables.append({"page": pno, "header": sound_hdr, "y": [top, rows[-1]["y"][1] if rows else hb], "x0": round(tx0), "rows": rows})
    used = {h for t in tables for r in t["rows"] for h in r["audio"]}
    other = [{"hash": l["hash"], "kind": l["kind"], "rect": [round(v) for v in l["rect"]],
              "near_text": clean(pg.get_textbox(pymupdf.Rect(40, l["rect"].y0 - 60, 1560, l["rect"].y1 + 60)))[:160]}
             for l in L if l["hash"] not in used]
    return tables, other


def main():
    pdf, out = sys.argv[1], sys.argv[2]
    a, b = (sys.argv[3] if len(sys.argv) > 3 else "1-63").split("-")
    d = pymupdf.open(pdf)
    res = {"tables": [], "other_links": []}
    for pno in range(int(a), int(b) + 1):
        t, o = page_tables(d[pno - 1], pno)
        res["tables"] += t
        res["other_links"] += [dict(x, page=pno) for x in o]
    json.dump(res, open(out, "w"), ensure_ascii=False, indent=1)
    nrows = sum(len(t["rows"]) for t in res["tables"])
    used = {h for t in res["tables"] for r in t["rows"] for h in r["audio"]}
    print(f"tables={len(res['tables'])} rows={nrows} row_audio={len(used)} other_links={len(res['other_links'])}"
          f" flagged_rows={sum(1 for t in res['tables'] for r in t['rows'] if r['flags'])}")


if __name__ == "__main__":
    main()
