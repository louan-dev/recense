"""Contact sheet of diagram crops: python -I sheet.py <pdf> <plan.json> <out.png> [cols]"""
import json, sys, pymupdf
src = pymupdf.open(sys.argv[1]); plan = json.load(open(sys.argv[2])); cols = int(sys.argv[4]) if len(sys.argv) > 4 else 6
cw, ch = 300, 330
rows = (len(plan) + cols - 1) // cols
doc = pymupdf.open(); pg = doc.new_page(width=cols * cw, height=rows * ch)
for i, p in enumerate(plan):
    x, y = (i % cols) * cw, (i // cols) * ch
    pg.show_pdf_page(pymupdf.Rect(x + 5, y + 5, x + cw - 5, y + ch - 35), src, p["page"] - 1, clip=pymupdf.Rect(p["clip"]))
    pg.insert_text((x + 6, y + ch - 14), f"{i}:{p['name'][:-4]}", fontsize=13)
pg.get_pixmap(dpi=55).save(sys.argv[3])
