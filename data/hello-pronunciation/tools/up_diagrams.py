"""Render diagram crops in memory and stream each PNG to R2 (no local files); writes one review sheet.
usage: python -I up_diagrams.py <pdf> <plan.json> <r2aws> <sheet.png> [--dry]"""
import json, subprocess, sys
import pymupdf

pdf, plan_path, r2aws, sheet = sys.argv[1:5]
dry = "--dry" in sys.argv
src = pymupdf.open(pdf)
plan = json.load(open(plan_path))
DEST = "s3://recense-tmp/hello-pronunciation/diagrams/"


def png_for(p):
    if p["kind"] == "lips" and p["xref"]:
        info = src.extract_image(p["xref"])
        pix = pymupdf.Pixmap(src, p["xref"])
        if pix.n - pix.alpha >= 4:  # CMYK -> RGB
            pix = pymupdf.Pixmap(pymupdf.csRGB, pix)
        if info.get("smask"):
            pix = pymupdf.Pixmap(pix, pymupdf.Pixmap(src, info["smask"]))
        return pix
    return src[p["page"] - 1].get_pixmap(clip=pymupdf.Rect(p["clip"]), matrix=pymupdf.Matrix(1.25, 1.25))


cols, cw, ch = 5, 300, 330
doc = pymupdf.open()
sh = doc.new_page(width=cols * cw, height=((len(plan) + cols - 1) // cols) * ch)
total = 0
for i, p in enumerate(plan):
    pix = png_for(p)
    data = pix.tobytes("png")
    total += len(data)
    p["px"] = [pix.width, pix.height]
    p["bytes"] = len(data)
    x, y = (i % cols) * cw, (i // cols) * ch
    sh.insert_image(pymupdf.Rect(x + 5, y + 5, x + cw - 5, y + ch - 35), stream=data, keep_proportion=True)
    sh.insert_text((x + 6, y + ch - 14), f"{i}:{p['name'][:-4]}", fontsize=13)
    if not dry:
        r = subprocess.run([r2aws, "s3", "cp", "-", DEST + p["name"], "--content-type", "image/png", "--only-show-errors"],
                           input=data, capture_output=True)
        if r.returncode:
            print("FAIL", p["name"], r.stderr.decode()[:200])
            sys.exit(1)
sh.get_pixmap(dpi=55).save(sheet)
json.dump(plan, open(plan_path, "w"), ensure_ascii=False, indent=1)
print(f"{len(plan)} diagrams, {total / 1e6:.1f} MB", "(dry run)" if dry else "uploaded")
