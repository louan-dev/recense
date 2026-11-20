#!/usr/bin/env python3
# Derived from Spec: FEAT-01
"""audiobook.py <speech.md> <out.m4b> <title> [voice]   (BOOK_LANG=eng by default)
Offline: Kokoro-82M (ONNX) renders each heading's section; ffmpeg joins them into one
M4B with a chapter marker per heading. Needs KOKORO_DIR with kokoro-v1.0.onnx + voices-v1.0.bin."""
import os, re, sys, subprocess, tempfile, pathlib
import numpy as np, soundfile as sf
from kokoro_onnx import Kokoro

src, out, title = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
voice = sys.argv[4] if len(sys.argv) > 4 else "af_heart"
lang = os.environ.get("BOOK_LANG", "eng")  # ISO 639-2 tag for the audio stream
kd = pathlib.Path(os.environ["KOKORO_DIR"])
k = Kokoro(str(kd / "kokoro-v1.0.onnx"), str(kd / "voices-v1.0.bin"))

# Split into chapters at every heading; the heading itself is spoken first.
chapters, cur = [], None
for para in src.read_text().split("\n\n"):
    para = para.strip()
    m = re.match(r"^(#+)\s+(.*)$", para)
    if m:
        cur = {"title": m.group(2), "paras": [m.group(2) + "."]}
        chapters.append(cur)
    elif para and cur:
        cur["paras"].append(para)

# Chapter titles in written form ("1901.01 Who Can Protest") from clean.md beside speech.md; the spoken
# form stays in the audio. Used only when both files have the same number of headings.
written = src.with_name("clean.md")
if written.exists():
    heads = [m.group(1) for m in re.finditer(r"(?m)^#+\s+(.*)$", written.read_text())]
    if len(heads) == len(chapters):
        for ch, h in zip(chapters, heads):
            ch["title"] = h

def chunks(text, limit=400):
    """Sentence-sized pieces so no single call exceeds the model's input window."""
    parts, buf = [], ""
    for s in re.split(r"(?<=[.;:])\s+", text):
        if len(buf) + len(s) > limit and buf:
            parts.append(buf); buf = ""
        buf = (buf + " " + s).strip()
    return parts + ([buf] if buf else [])

tmp = pathlib.Path(tempfile.mkdtemp(prefix="book-", dir=os.environ.get("TMPDIR")))
SR = 24000
gap_para, gap_chap = np.zeros(int(SR * 0.45), np.float32), np.zeros(int(SR * 1.2), np.float32)
meta = [";FFMETADATA1", f"title={title}", "artist=Recense", "genre=Audiobook"]
t0, lst = 0, []
for i, ch in enumerate(chapters):
    audio = []
    for p in ch["paras"]:
        for c in chunks(p):
            a, sr = k.create(c, voice=voice, speed=1.0, lang="en-us")
            audio.append(a.astype(np.float32))
        audio.append(gap_para)
    audio.append(gap_chap)
    wav = np.concatenate(audio)
    f = tmp / f"{i:03d}.wav"; sf.write(f, wav, SR)
    ms = int(len(wav) / SR * 1000)
    meta += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={t0}", f"END={t0 + ms}", f"title={ch['title']}"]
    t0 += ms; lst.append(f"file '{f}'")
    print(f"{i + 1}/{len(chapters)} {ch['title'][:60]}  {ms / 1000:.0f}s", flush=True)

(tmp / "list.txt").write_text("\n".join(lst) + "\n")
(tmp / "meta.txt").write_text("\n".join(meta) + "\n")
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", tmp / "list.txt",
                "-i", tmp / "meta.txt", "-map_metadata", "1", "-map_chapters", "1",
                "-c:a", "aac", "-b:a", "64k", "-metadata:s:a:0", f"language={lang}", out], check=True)
print("wrote", out)
