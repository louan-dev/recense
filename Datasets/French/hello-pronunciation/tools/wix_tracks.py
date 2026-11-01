"""Fetch the Wix audio-collection page and list its MusicPlayer tracks: hash, site duration, title (TSV on stdout)."""
import re, sys, urllib.request
html = urllib.request.urlopen(urllib.request.Request(sys.argv[1], headers={"User-Agent": "Mozilla/5.0"}), timeout=30).read().decode("utf-8", "replace")
html = html.replace('\\"', '"')
re_t = re.compile(r'"trackName":"([^"]*)"[^{}]*?"url":"https://(?:static|music)\.wixstatic\.com/mp3/730488_([0-9a-f]{32})(?:\.m4a|-320\.mp3)"\}\],"duration":(\d+)')
seen = {}
for m in re_t.finditer(html):
    seen.setdefault(m.group(2), (m.group(3), m.group(1)))
for h, (d, t) in seen.items():
    print(f"{h}\t{d}\t{t}")
print(len(seen), file=sys.stderr)
