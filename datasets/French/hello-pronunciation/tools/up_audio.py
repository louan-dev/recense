"""Stream Hello Pronunciation clips from Wix to R2 in memory (no local audio files).
usage: python -I up_audio.py <tracks.tsv> <r2aws> <manifest.json> <start> <count>
Manifest records bytes and the duration read from the m4a header (ffprobe) per hash; reruns skip done hashes."""
import json, os, struct, subprocess, sys, urllib.request

tracks_tsv, r2aws, manifest_path, start, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
hashes = [l.split("\t", 1)[0] for l in open(tracks_tsv, encoding="utf-8") if l.strip()]
man = json.load(open(manifest_path)) if os.path.exists(manifest_path) else {}
DEST = "s3://recense-tmp/hello-pronunciation/audio/"


def probe(b):
    """duration/codec from ffprobe reading the bytes on stdin (the m4a mvhd header proved unreliable)"""
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_name,sample_rate,channels",
                        "-of", "json", "-i", "pipe:0"], input=b, capture_output=True)
    try:
        j = json.loads(r.stdout)
        st = (j.get("streams") or [{}])[0]
        return {"duration_s": round(float(j["format"]["duration"]), 3), "codec": st.get("codec_name"),
                "sample_rate": int(st.get("sample_rate", 0)) or None, "channels": st.get("channels")}
    except Exception:
        return {"duration_s": None}


done = 0
for h in hashes[start:start + count]:
    if h in man:
        continue
    url = f"https://static.wixstatic.com/mp3/730488_{h}.m4a"
    data = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"}), timeout=60).read()
    r = subprocess.run([r2aws, "s3", "cp", "-", f"{DEST}{h}.m4a", "--content-type", "audio/mp4", "--only-show-errors"],
                       input=data, capture_output=True)
    if r.returncode:
        print("FAIL", h, r.stderr.decode()[:200])
        break
    man[h] = {"bytes": len(data), **probe(data)}
    done += 1
    json.dump(man, open(manifest_path, "w"), indent=0)
print(f"batch {start}-{start + count}: uploaded {done}, manifest {len(man)}/{len(hashes)}, "
      f"{sum(v['bytes'] for v in man.values()) / 1e6:.1f} MB total")
