# Derived from Spec: FEAT-01 (pronunciation cases, `python3 -I text/test_rules.py`)
import sys, pathlib; sys.path.insert(0, str(pathlib.Path(__file__).parent))
import clean, re
meta, rules = clean.load("mpep"); sp = clean.stage(rules, "speech")
cases = {
 "See MPEP § 1901.07(a).": "See M.P.E.P. section nineteen oh-one point oh seven a.",
 "under 37 CFR 1.291(d) applies": "under 37 C.F.R. one point two nine one d applies",
 "35 U.S.C. 122(c)": "35 U.S. Code one twenty-two c",
 "§ 609.04": "section six oh-nine point oh four",
 "§ 2100": "section twenty-one hundred",
}
bad = 0
for i, want in cases.items():
    got = clean.apply(i, sp)
    if got != want: bad += 1; print("FAIL", repr(i), "->", repr(got), "want", repr(want))
print("ok" if not bad else f"{bad} failed")

# Regression (2026-11-20): the CLI must send a .pdf path to pdf_text, never read it as UTF-8.
import subprocess, tempfile
def tiny_pdf(words):
    stream = f"BT /F1 12 Tf 72 700 Td ({words}) Tj ET".encode()
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    out, offs = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"), []
    for i, o in enumerate(objs, 1):
        offs.append(len(out)); out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    x = len(out); out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offs)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
    return bytes(out)
with tempfile.TemporaryDirectory() as d:
    pdf = pathlib.Path(d, "t.pdf"); pdf.write_bytes(tiny_pdf("Patent term adjustment"))
    r = subprocess.run([sys.executable, "-I", str(pathlib.Path(__file__).parent / "clean.py"), "mpep", str(pdf), d],
                       capture_output=True, text=True)
    ok = r.returncode == 0 and "Patent" in pathlib.Path(d, "clean.md").read_text()
    print("pdf cli ok" if ok else "FAIL pdf cli: " + r.stderr[-300:])

# Regression (2026-11-20): a section title wrapped onto a second line is joined up to its [R-…] stamp.
c, _ = clean.run("mpep", "1901.02 Information Which Can Be Relied\non in Protest [R-10.2019]\nAny information may be relied on.\n")
want = "## 1901.02 Information Which Can Be Relied on in Protest"
print("wrapped heading ok" if c.splitlines()[0] == want else "FAIL wrapped heading: " + repr(c[:120]))

# Regression (2026-11-20): a chapter title wrapped onto the next line is joined (join_next); a number line is not.
c, _ = clean.run("mpep", "Chapter 100 Secrecy, Access, National Security, and Foreign\nFiling\n101\n")
want = "# Chapter 100 Secrecy, Access, National Security, and Foreign Filing"
print("chapter title ok" if c.splitlines()[0] == want else "FAIL chapter title: " + repr(c[:120]))

# Regression (2026-11-20): a bare "Chapter 2100" line takes its title from the profile's titles table.
c, _ = clean.run("mpep", "Chapter 2100\n2101\n")
print("bare chapter ok" if c.splitlines()[0] == "# Chapter 2100 Patentability" else "FAIL bare chapter: " + repr(c[:80]))

# Regression (2026-11-20): M4B chapter titles use the written form; the audio stream is tagged eng.
# Runs only where the voice is installed (KOKORO_DIR and VOICE_PY set); otherwise prints "skip".
import os, json
kd, vpy = os.environ.get("KOKORO_DIR"), os.environ.get("VOICE_PY")
if kd and vpy:
    with tempfile.TemporaryDirectory() as d:
        # "______" (a form blank) has nothing to say: it must be skipped, not crash the render (2026-11-20, ch.1300)
        pathlib.Path(d, "speech.md").write_text("## nineteen oh-one Protest\n\nA short line.\n\n______________________\n\n## nineteen oh-two Who\n\nAnother.\n")
        pathlib.Path(d, "clean.md").write_text("## 1901 Protest\n\nA short line.\n\n## 1902 Who\n\nAnother.\n")
        out = pathlib.Path(d, "t.m4b")
        subprocess.run([vpy, "-I", str(pathlib.Path(__file__).parent / "audiobook.py"), str(pathlib.Path(d, "speech.md")), str(out), "T"],
                       check=True, capture_output=True, env={**os.environ, "TMPDIR": d})
        j = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_chapters", "-show_streams", "-of", "json", str(out)],
                                      capture_output=True, text=True).stdout)
        titles = [c["tags"]["title"] for c in j["chapters"]]
        lang = j["streams"][0].get("tags", {}).get("language")
        print("m4b titles ok" if titles == ["1901 Protest", "1902 Who"] and lang == "eng" else f"FAIL m4b: {titles} {lang}")
        left = list(pathlib.Path(d).glob("book-*"))
        print("m4b temp cleaned ok" if not left else f"FAIL m4b temp left: {left}")
else:
    print("m4b titles skip (no KOKORO_DIR/VOICE_PY)")
