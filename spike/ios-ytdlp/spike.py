# Spike: yt-dlp inside an iOS app. No subprocess, no ffmpeg. Throwaway.
import json, os, platform, sys, time, traceback

DOCS = os.path.join(os.environ["HOME"], "Documents")
DL = os.path.join(DOCS, "dl")
CACHE = os.path.join(os.environ["HOME"], "Library", "Caches", "yt-dlp")
os.makedirs(DL, exist_ok=True)
URL = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"  # Big Buck Bunny, Blender Foundation, CC BY 3.0
LOG = os.path.join(DOCS, "spike.log")
res = {"python": sys.version, "platform": platform.platform(), "sys.platform": sys.platform}


def log(*a):
    s = " ".join(str(x) for x in a)
    print("SPIKE", s, flush=True)
    with open(LOG, "a") as f:
        f.write(s + "\n")


class L:  # yt-dlp logger -> our log
    def debug(self, m):
        if not m.startswith("[download]  ") and "% of" not in m:
            log("  ytdlp:", m)
    info = debug
    def warning(self, m): log("  ytdlp WARNING:", m)
    def error(self, m): log("  ytdlp ERROR:", m)


def run(label, fmt, outname, extra=None):
    import yt_dlp
    opts = {"format": fmt, "outtmpl": os.path.join(DL, outname), "cachedir": CACHE, "logger": L(),
            "noprogress": True, "nopart": True, "overwrites": True,
            "socket_timeout": 20, "retries": 2}
    opts.update(extra or {})
    t = time.time()
    try:
        with yt_dlp.YoutubeDL(opts) as y:
            rc = y.download([URL])
        r = {"ok": rc == 0, "rc": rc}
    except Exception as e:
        r = {"ok": False, "error": f"{type(e).__name__}: {e}"[:400]}
    r["seconds"] = round(time.time() - t, 2)
    files = {f: os.path.getsize(os.path.join(DL, f)) for f in os.listdir(DL)}
    r["files_after"] = files
    res[label] = r
    log(label, json.dumps(r))


def main():
    log("python", sys.version.split()[0], sys.platform, platform.platform())
    t = time.time()
    import yt_dlp, ssl
    res["import_s"] = round(time.time() - t, 2)
    res["yt_dlp"] = yt_dlp.version.__version__
    res["ssl"] = ssl.OPENSSL_VERSION
    try:
        import certifi
        res["certifi"] = certifi.where()
    except Exception as e:
        res["certifi"] = repr(e)
    log("import yt_dlp", res["import_s"], "s", res["yt_dlp"], res["ssl"])
    try:
        import subprocess
        subprocess.run(["/bin/echo", "hi"], capture_output=True)
        res["subprocess"] = "RAN (unexpected)"
    except Exception as e:
        res["subprocess"] = f"{type(e).__name__}: {e}"
    log("subprocess:", res["subprocess"])
    from yt_dlp.postprocessor.ffmpeg import FFmpegPostProcessor
    try:
        res["ffmpeg_available"] = FFmpegPostProcessor(None).available
    except Exception as e:
        res["ffmpeg_available"] = repr(e)
    log("ffmpeg available:", res["ffmpeg_available"])

    # Step 2: audio-only m4a, then separate video (360p h264) for the AVFoundation join
    run("audio_m4a", "140", "audio.m4a")
    run("video_mp4", "134", "video.mp4")
    # ffmpeg-dependent features, expected to fail or degrade. Off by default: the merge run stalled
    # at "Downloading webpage" on 2026-11-14 and blocked the AVFoundation join. SPIKE_FFMPEG=1 turns them on.
    if os.environ.get("SPIKE_FFMPEG") != "1":
        res["ffmpeg_runs"] = "skipped"
    else:
      run("merge_requested", "160+140", "merge.%(ext)s")
      run("extract_audio_mp3", "140", "x.%(ext)s",
        {"postprocessors": [{"key": "FFmpegExtractAudio", "preferredcodec": "mp3"}]})
    with open(os.path.join(DOCS, "spike.json"), "w") as f:
        json.dump(res, f, indent=1)
    log("python part done")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        log("CRASH", traceback.format_exc())
        sys.exit(1)
