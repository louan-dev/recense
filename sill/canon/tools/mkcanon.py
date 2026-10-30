# Builds Recense's canon (../*.json) from the sources it was taken from, downloaded into the working directory first:
#   snp1.8.json snp2.1.json snp2.4.json  github.com/suttacentral/bilara-data  root/pli/ms/sutta/kn/snp/…_root-pli-ms.json (CC0)
#   ys1.txt … ys4.txt                    sa.wikisource.org योगसूत्रम्/पादः_१…४  (?action=raw)
#   verse.json                           github.com/gita/gita data/verse.json (The Unlicense)
#   isha.txt                             sa.wikisource.org ईशावास्‍योपनिषद् (?action=raw)
# Usage: python3 mkcanon.py <canon dir>.  More texts: any canon/*.json of the same shape, or <cache>/canon/*.json.
import json, re, sys
out = sys.argv[1]
def save(name, d):
    json.dump(d, open(f"{out}/{name}.json", "w"), ensure_ascii=False, indent=1)
    print(name, sum(len(t["lines"]) for t in d["texts"]), "lines")

# Pāli: SuttaCentral bilara-data (Mahāsaṅgīti root text, CC0)
def sutta(f, title):
    d = json.load(open(f))
    lines = [re.sub(r"[“”‘’\"]", "", v).strip() for k, v in d.items() if not re.search(r":0\.", k)]
    return {"id": f.split(".json")[0], "title": title, "lines": [l for l in lines if l]}
save("pi-paritta", {"lang": "pi", "script": "Latn", "hearAs": ["si", "th", "my", "hi"],
    "source": "SuttaCentral bilara-data, Mahāsaṅgīti root text (CC0)",
    "texts": [{"id": "homage", "title": "Namo tassa", "lines": ["Namo tassa bhagavato arahato sammāsambuddhassa"]},
              sutta("snp1.8.json", "Karaṇīya Metta Sutta"), sutta("snp2.1.json", "Ratana Sutta"), sutta("snp2.4.json", "Maṅgala Sutta")]})

# Sanskrit: Yoga Sūtras (sa.wikisource, ancient text, transcription CC BY-SA)
ys = []
for i in range(1, 5):
    for m in re.finditer(r"^\s*([^\n<{}|=']+?)\s*(?:॥|।।)\s*(?:[०-९]+\.)?[०-९]+\s*(?:॥|।।)", open(f"ys{i}.txt").read(), re.M):
        t = m.group(1).replace("'''", "").strip()
        if t: ys.append(t)
save("sa-yogasutra", {"lang": "sa", "script": "Deva", "hearAs": ["hi", "mr", "ne"],
    "source": "Patañjali, Yogasūtra; sa.wikisource.org योगसूत्रम् (CC BY-SA transcription)",
    "texts": [{"id": "yogasutra", "title": "Yoga Sūtras of Patañjali", "lines": ys}]})

# Sanskrit: Bhagavad Gītā (github.com/gita/gita, The Unlicense)
v = json.load(open("verse.json"))
gita = []
for x in sorted(v, key=lambda x: (x["chapter_number"], x["verse_number"])):
    for l in x["text"].split("\n"):
        l = re.sub(r"[।॥|]+\s*[0-9\.]*\s*[।॥|]*", "", l).strip()
        if l and not l.endswith("उवाच"): gita.append(l)
        elif l: gita.append(l)
save("sa-gita", {"lang": "sa", "script": "Deva", "hearAs": ["hi", "mr", "ne"],
    "source": "Bhagavad Gītā; github.com/gita/gita data/verse.json (The Unlicense)",
    "texts": [{"id": "gita", "title": "Bhagavad Gītā", "lines": gita}]})

# Sanskrit: Īśa Upaniṣad with its śānti mantra (sa.wikisource, CC BY-SA transcription)
raw = re.sub(r"<[^>]+>|\{[^}]*\}|'''", "", open("isha.txt").read())
isha = [re.sub(r"[।॥]+[०-९]*[।॥]*", "", l).strip() for l in raw.split("\n")]
isha = [l for l in isha if l and not l.startswith(("ईशोपनिषत्", "अथ", "इति", "[[", "=", "*")) and re.search(r"[ऀ-ॿ]", l)]
save("sa-upanishad", {"lang": "sa", "script": "Deva", "hearAs": ["hi", "mr", "ne"],
    "source": "Īśāvāsya Upaniṣad; sa.wikisource.org (CC BY-SA transcription)",
    "texts": [{"id": "isha", "title": "Īśa Upaniṣad", "lines": isha}]})
