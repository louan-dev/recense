// Reports the playing <audio>/<video> to the Recense Mac app, which transcribes the whole file
// ahead of time and highlights words against these position reports — so seeking/speed changes are instant.
(() => {
  // Gallery has its own player and shows the same transcripts (shared through keep/ by content key). Its position is
  // reported under the file's Gallery address ("gallery:files/<path>", the key Recense transcribed it under), and
  // the window's controls (play, pause, seek, speed, loop) steer it like any player. No bytes are ever fetched here:
  // pulling whole files through the page froze the tab in Firefox.
  const gallery = /(^|\.)gallery\.improvdiplomat\.workers\.dev$/.test(location.hostname);
  const srcOf = (m) => {
    const u = m && m.currentSrc;
    if (!gallery || !u) return u;
    try {
      const p = new URL(u).pathname;
      return p.startsWith("/main/f/") ? "gallery:files/" + decodeURIComponent(p.slice("/main/f/".length)) : u;
    } catch (e) { return u; }
  };
  let media = null, enabled = true, sending = false, again = false, seq = 0;
  let loop = { track: false, ab: false, a: null, b: null, dur: null };   // set from the Mac app's window
  const announced = new Map();          // url -> state from the app

  const app = (path, body) => browser.runtime.sendMessage({ cmd: "app", path, body }).catch(() => null);
  // Muted autoplay (background loops, previews, ads in a corner) has nothing to subtitle and never takes over.
  const audible = (m) => !m.muted && m.volume > 0;
  // An embedded player's page: the site it sits in, which yt-dlp can often read when the embed alone isn't enough.
  const top = window === window.top ? null : (document.referrer || null);
  // A YouTube preview (search results, a channel page, the mini-player) plays another video than the page's.
  function pageOf(m) {
    try {
      const p = m.closest(".html5-video-player");
      const v = p && p.wrappedJSObject && p.wrappedJSObject.getVideoData().video_id;
      if (v) return "https://www.youtube.com/watch?v=" + v;
    } catch (e) {}
    return location.href;
  }

  async function announce(m) {
    const url = srcOf(m);
    if (!url || announced.has(url) || adNow(m)) return;   // an ad is never transcribed (SPEC 17)
    announced.set(url, "pending");
    const r = await app("/media", { url, duration: m.duration, page: pageOf(m), top, title: document.title });   // page: for streams with no file
    if (!r) { announced.delete(url); return; }           // app not running; retry on next report
    announced.set(url, r.state);
    if (r.state !== "need-bytes" || gallery) return;
    // The app couldn't download it (cookies / blob: URL) — read it from the page's own context.
    try {
      const res = await fetch(url, { credentials: "include" });
      if (!res.ok) throw new Error(res.status);
      const buffer = await res.arrayBuffer();
      const type = res.headers.get("content-type") || "";
      const out = await browser.runtime.sendMessage({ cmd: "bytes", url, buffer, type });
      announced.set(url, out && out.state);
    } catch (e) {
      await browser.runtime.sendMessage({ cmd: "bytes", url, buffer: new ArrayBuffer(0), type: "" }).catch(() => {});
      announced.set(url, "failed");
    }
  }

  async function report() {
    if (!enabled || !media || !media.currentSrc) return;
    const src = srcOf(media);
    if (sending) { again = true; return; }   // a pause/seek mid-flight is sent right after, not 150 ms later
    sending = true;
    const r = await app("/pos", {
      url: src, t: media.currentTime, rate: media.playbackRate, dur: media.duration,
      paused: media.paused || media.seeking || media.readyState < 3, sent: Date.now(), seq, loop: isAd(media) ? loop.track && !loop.ab : media.loop,
      page: pageOf(media), vol: media.muted ? 0 : media.volume, ad: adNow(media),   // an ad: shown as one, never transcribed
      fxv: fx.v, fxNo, fxKey: !keyFailed     // the sound the window last sent, as this page has it (SPEC 54)
    });
    sending = false;
    if (again) { again = false; report(); }
    if (r && r.need === "media") { announced.delete(src); announce(media); }
    if (r && r.cmds && r.cmds.length) { r.cmds.forEach(run); report(); }
  }

  // Commands from the window's controls.
  function run(c) {
    const m = media;
    if (!m) return;
    if (c.seq > seq) seq = c.seq;          // tells the app which reports already reflect this command
    if (c.op === "play") m.play().catch(() => {});
    else if (c.op === "pause") m.pause();
    else if (c.op === "seek") m.currentTime = Math.max(0, Math.min(c.t, m.duration || c.t));
    else if (c.op === "rate") { m.preservesPitch = true; m.playbackRate = c.r; }
    else if (c.op === "skipAd") { if (adNow(m)) skipAd(m); }
    else if (c.op === "volume") { m.muted = false; m.volume = Math.max(0, Math.min(1, c.v)); }
    else if (c.op === "fx") {
      fx = { v: c.v, eq: { low: +c.eq?.low || 0, mid: +c.eq?.mid || 0, high: +c.eq?.high || 0 }, key: +c.key || 0, mix: +c.mix || 0, room: c.room || "room" };
      keyFailed = false;
      if (gallery) window.postMessage({ recenseFx: { eq: fx.eq, key: fx.key, mix: fx.mix, room: fx.room } }, location.origin);
      applyFx();
    }
    else if (c.op === "loop") {
      loop = { track: !!c.track, ab: !!c.ab, a: c.a ?? null, b: c.b ?? null, dur: c.dur ?? null };
      applyLoop(m);
    }
  }

  // ----- the sound (SPEC 54): the tray in Recense's window (EQ, Key, Reverb) reshapes this page's own audio -----
  //
  //   media → Low → Mid → High → trim ─┬─ keyDry ─────────────────┬─ mix ─┬─ spDry ──────────────── out
  //                                    └─ Key (worklet) ─ keyWet ─┘       └─ Space (convolver) ─ wet ┘
  //
  // Gallery's chain (gallery.js) with Gallery's numbers: the bands are homebar.js's EQ_BANDS, the rooms room.js's and
  // the Key processor player-key.js's (both copied in by sign.sh). Nothing is touched while the sound is flat. A
  // media element goes into Web Audio once and never comes back out, and a file from another site that doesn't allow
  // it (no CORS) would play silence through it: such a player is left alone and the window is told why (fxNo).
  const BANDS = [
    { id: "low", type: "lowshelf", f: 160, q: 0.7 },
    { id: "mid", type: "peaking", f: 1000, q: 0.7 },
    { id: "high", type: "highshelf", f: 5000, q: 0.7 },
  ];
  let fx = { v: -1, eq: { low: 0, mid: 0, high: 0 }, key: 0, mix: 0, room: "room" };   // as the window last sent it
  let fxNo = null, keyFailed = false;   // why the followed player can't take it ("cors", "gallery", "audio")
  let actx = null, keyMod = null, ctxWait = false, sleepT = 0;
  const graphs = new Map();             // media → its chain, once taken (every one follows the tray)
  const irs = {};
  const flat = () => !fx.eq.low && !fx.eq.mid && !fx.eq.high && !fx.key && !fx.mix;

  // Gallery plays through its own tray; elsewhere a file from this site, a blob: (MSE streams) or CORS can be taken.
  // Note 30: on Gallery the tray is the controller too. Gallery is told so (a flag on <html> before its player
  // starts, and the tray's values by postMessage); if gallery.js already took the element into its own chain, it is
  // driven through that chain (it marks the element data-gallery-fx and answers {recenseFxAck}), never taken twice.
  if (gallery) document.documentElement.dataset.recenseFx = "1";
  let galleryAck = false;
  if (gallery) window.addEventListener("message", (e) => { if (e.source === window && e.data && e.data.recenseFxAck) galleryAck = true; });
  function blocked(m) {
    if (gallery && m.dataset.galleryFx != null) return "gallery";   // an older gallery.js holds it and doesn't listen
    const u = m.currentSrc || "";
    if (/^(blob|data|mediastream):/.test(u) || m.crossOrigin != null) return null;
    try { if (new URL(u, location.href).origin === location.origin) return null; } catch (e) {}
    return "cors";
  }

  function applyFx() {
    for (const g of graphs.values()) setFx(g);
    const m = media;
    if (!m || graphs.has(m)) { fxNo = null; return; }
    if (flat() || (gallery && galleryAck)) { fxNo = null; return; }   // Gallery's own chain obeys the tray
    fxNo = blocked(m);
    if (fxNo) return;
    const g = takeFx(m);
    if (g) setFx(g);
  }

  function takeFx(m) {
    const AC = window.AudioContext;
    if (!AC) { fxNo = "audio"; return null; }
    try {
      if (!actx) actx = new AC();
      // Firefox: an element taken into a context that isn't running goes silent. Wait for it to run.
      if (actx.state !== "running") {
        if (!ctxWait) {
          ctxWait = true;
          actx.resume().then(() => { ctxWait = false; if (actx && actx.state === "running") applyFx(); }, () => { ctxWait = false; });
        }
        return null;
      }
      const src = actx.createMediaElementSource(m);
      const f = {};
      let prev = src;
      for (const b of BANDS) {
        const n = actx.createBiquadFilter();
        n.type = b.type; n.frequency.value = b.f; n.Q.value = b.q; n.gain.value = 0;
        prev.connect(n); prev = n; f[b.id] = n;
      }
      const g = { m, f, trim: actx.createGain(), keyDry: actx.createGain(), keyWet: actx.createGain(), mix: actx.createGain(),
                  spDry: actx.createGain(), out: actx.createGain(), key: null, keyState: "off", sp: null };
      prev.connect(g.trim);
      g.trim.connect(g.keyDry); g.keyDry.connect(g.mix); g.keyWet.connect(g.mix); g.keyWet.gain.value = 0;
      g.mix.connect(g.spDry); g.spDry.connect(g.out); g.out.connect(actx.destination);
      graphs.set(m, g);
      return g;
    } catch (e) {
      fxNo = "audio";
      return null;
    }
  }

  // the gain that takes back the EQ's highest peak, as Gallery's eqTrim: a boost never clips
  const TRIM_F = new Float32Array(96).map((_, i) => 20 * Math.pow(1000, i / 95));
  function trimGain() {
    if (!BANDS.some((b) => fx.eq[b.id] > 0)) return 1;
    const sum = new Float32Array(TRIM_F.length), mag = new Float32Array(TRIM_F.length), ph = new Float32Array(TRIM_F.length);
    const probe = actx.createBiquadFilter();
    for (const b of BANDS) {
      probe.type = b.type; probe.frequency.value = b.f; probe.Q.value = b.q; probe.gain.value = fx.eq[b.id];
      probe.getFrequencyResponse(TRIM_F, mag, ph);
      mag.forEach((x, i) => (sum[i] += 20 * Math.log10(Math.max(x, 1e-6))));
    }
    return Math.min(1, Math.pow(10, -Math.max(0, ...sum) / 20));
  }

  function setFx(g) {
    const t = actx.currentTime;
    for (const b of BANDS) g.f[b.id].gain.setTargetAtTime(fx.eq[b.id], t, 0.03);
    const tg = trimGain();
    g.trim.gain.setTargetAtTime(tg, t, tg < g.trim.gain.value ? 0.005 : 0.06);
    setKey(g);
    setSpace(g);
  }

  // Key: the phase vocoder crossfades in once it has had a frame of sound, and out to the dry path at 0.
  // The page's CSP may refuse the module from the extension's address; a blob: of the same file is tried next.
  function keyNode(g) {
    if (g.key) return Promise.resolve(g.key);
    const url = browser.runtime.getURL("player-key.js");
    if (!keyMod) {
      keyMod = actx.audioWorklet.addModule(url)
        .catch(() => fetch(url).then((r) => r.text()).then((s) => actx.audioWorklet.addModule(URL.createObjectURL(new Blob([s], { type: "text/javascript" })))))
        .catch((e) => { keyMod = null; throw e; });
    }
    return keyMod.then(() => {
      if (!g.key) {
        g.key = new AudioWorkletNode(actx, "pdc-key", { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [2],
          channelCount: 2, channelCountMode: "explicit", channelInterpretation: "speakers" });
        g.trim.connect(g.key);
        g.key.connect(g.keyWet);
      }
      return g.key;
    });
  }
  function setKey(g) {
    const t = actx.currentTime;
    if (!fx.key) {
      if (g.keyState === "off") return;
      g.keyState = "off";
      g.keyDry.gain.setTargetAtTime(1, t, 0.012);
      g.keyWet.gain.setTargetAtTime(0, t, 0.012);
      setTimeout(() => { if (g.keyState === "off" && g.key) g.key.port.postMessage({ on: false }); }, 150);
      return;
    }
    keyNode(g).then((k) => {
      if (!fx.key) return;
      k.port.postMessage({ ratio: Math.pow(2, fx.key / 12) });
      if (g.keyState !== "off") return;
      g.keyState = "warming";
      k.port.postMessage({ reset: true, on: true });
      setTimeout(() => {
        if (g.keyState !== "warming") return;
        g.keyState = "on";
        g.keyDry.gain.setTargetAtTime(0, actx.currentTime, 0.012);
        g.keyWet.gain.setTargetAtTime(1, actx.currentTime, 0.012);
      }, 90);
    }, () => { keyFailed = true; });
  }

  // Space: off, the convolver is out of the chain; a new room lets the old one's tail ring out.
  function roomIR(id, rev) {
    const k = id + (rev ? "~" : "");
    if (irs[k]) return irs[k];
    let d = GalleryRoom.irData(id, actx.sampleRate);
    if (rev) d = GalleryRoom.reverseIR(d);
    const buf = actx.createBuffer(2, d[0].length, actx.sampleRate);
    d.forEach((x, c) => buf.getChannelData(c).set(x));
    return (irs[k] = buf);
  }
  function dropRoom(r, after) {
    setTimeout(() => { try { r.conv.disconnect(); r.wet.disconnect(); } catch (e) {} }, after);
  }
  function setSpace(g) {
    const t = actx.currentTime;
    const room = GalleryRoom.ROOMS[fx.room] ? fx.room : "room";
    const amt = Math.min(1, Math.abs(fx.mix) / 100), rev = fx.mix < 0;
    if (amt > 0 && (!g.sp || g.sp.room !== room || g.sp.rev !== rev)) {
      const old = g.sp;
      const conv = actx.createConvolver(), wet = actx.createGain();
      conv.buffer = roomIR(room, rev);
      wet.gain.value = 0;
      g.mix.connect(conv); conv.connect(wet); wet.connect(g.out);
      g.sp = { conv, wet, room, rev };
      if (old) { try { g.mix.disconnect(old.conv); } catch (e) {} dropRoom(old, GalleryRoom.ROOMS[old.room].rt * 1200); }
    }
    g.spDry.gain.setTargetAtTime(GalleryRoom.spaceGain(amt).dry, t, 0.012);
    if (!g.sp) return;
    if (amt > 0) { g.sp.wet.gain.setTargetAtTime(GalleryRoom.spaceGain(amt).wet, t, 0.012); return; }
    const r = g.sp;
    g.sp = null;
    r.wet.gain.setTargetAtTime(0, t, 0.03);
    try { g.mix.disconnect(r.conv); } catch (e) {}
    dropRoom(r, 400);
  }

  // As Gallery's: the context sleeps a few seconds after the last pause (a running one keeps an output stream open,
  // which an audio routing app can leave stuck), and wakes with the next play.
  function ctxFollow(e) {
    if (!actx || !graphs.has(e.target)) return;
    clearTimeout(sleepT);
    if (e.type === "play" || e.type === "playing") { if (actx.state !== "running") actx.resume().catch(() => {}); return; }
    if (e.type !== "pause" && e.type !== "ended") return;
    sleepT = setTimeout(() => {
      if (actx && actx.state === "running" && ![...graphs.keys()].some((m) => !m.paused)) actx.suspend().catch(() => {});
    }, 4000);
  }

  // what the chain is doing, for a look from the add-on's console: browser.tabs.sendMessage(id, { cmd: "fx" })
  function fxState() {
    const g = media && graphs.get(media);
    return { v: fx.v, fx, fxNo, keyFailed, ctx: actx && actx.state, taken: !!g,
      gains: g && { ...Object.fromEntries(BANDS.map((b) => [b.id, g.f[b.id].gain.value])), trim: g.trim.gain.value,
        keyDry: g.keyDry.gain.value, keyWet: g.keyWet.gain.value, spDry: g.spDry.gain.value, spWet: g.sp ? g.sp.wet.gain.value : 0, room: g.sp && g.sp.room } };
  }

  // An ad in the same player has another length: it's never looped, and the loop comes back with the video.
  const isAd = (m) => adNow(m) ||
    (loop.dur != null && m.duration > 0 && Math.abs(m.duration - loop.dur) > 3);

  // ----- ads (SPEC 17 + 37): an ad playing is reported as one (never transcribed); the window's Skip Ad skips it -----
  // A frame served by an ad network (Genius's video ads play in such iframes), a player flagged as showing an ad,
  // or a media element inside an ad slot.
  const AD_HOSTS = /(^|\.)(doubleclick\.net|googlesyndication\.com|googleadservices\.com|imasdk\.googleapis\.com|2mdn\.net|adnxs\.com|amazon-adsystem\.com|connatix\.com|primis\.tech|aniview\.com|springserve\.com|spotxchange\.com|spotx\.tv|teads\.tv|ex\.co|vidazoo\.com|sekindo\.com|fwmrm\.net|innovid\.com|flashtalking\.com|serving-sys\.com|tremorhub\.com|unrulymedia\.com|playwire\.com|pubmatic\.com|rubiconproject\.com|criteo\.(com|net)|taboola\.com|outbrain\.com|minutemedia-prebid\.com|adsafeprotected\.com|moatads\.com|avantisvideo\.com|kargo\.com|yieldmo\.com|3lift\.com)$/i;
  const hostOf = (u) => { try { return new URL(u).hostname; } catch (e) { return ""; } };
  const adFrame = (() => {
    if (window === window.top) return false;
    if (AD_HOSTS.test(location.hostname)) return true;
    if (/google_ads|aswift_|safeframe|\bad[_-]?(frame|slot|unit)/i.test(window.name || "")) return true;
    try { for (const o of location.ancestorOrigins || []) if (AD_HOSTS.test(hostOf(o))) return true; } catch (e) {}
    return AD_HOSTS.test(hostOf(document.referrer));
  })();
  const AD_PLAYER = ".ad-showing, .ad-interrupting, .vjs-ad-playing, .vjs-ad-loading, .jw-flag-ads, .ima-ad-container, " +
    "[id^='google_ads_iframe'], [data-ad-slot], [data-google-query-id]";
  const AD_TOKEN = /(^|[\s_-])(ad|ads|advert|adverts|advertisement|preroll|midroll|adslot|adunit|ad-?container|sponsored)([\s_-]|$)/i;
  // A player that says itself when it shows an ad (AD_PLAYER) is believed: its other names say nothing about now.
  // YouTube keeps "ad-created" on its player for the whole video once an ad has loaded, and that word alone made the
  // video an ad: Skip Ad then ran the video itself to its end, and it was never transcribed (P6, 2026-11-10).
  const PLAYER = ".html5-video-player, .video-js, .jwplayer";
  function adNow(m) {
    if (adFrame) return true;
    try {
      if (m.closest(AD_PLAYER)) return true;
      if (AD_HOSTS.test(hostOf(m.currentSrc))) return true;
      if (m.closest(PLAYER)) return false;
      let el = m.parentElement;
      for (let i = 0; el && i < 6; i++, el = el.parentElement) {
        if (AD_TOKEN.test(el.id || "") || AD_TOKEN.test(typeof el.className === "string" ? el.className : "")) return true;
      }
    } catch (e) {}
    return false;
  }
  // Skip: the player's own Skip button when it shows one, and the ad run to its end either way: YouTube ignores a
  // script's click on its button (not isTrusted), so the click alone did nothing (notes 39). An ad with no end
  // (a stream) is sped through; one in its own element (not the page's player, which the video plays in next) is
  // muted so the video takes back over. Between an ad and the video the element has no source (duration NaN): there
  // is nothing to skip, and muting or speeding it then left the video that came next muted.
  const SKIP = ".ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .videoAdUiSkipButton, .vjs-ad-skip, " +
    ".jw-skip, .skip-ad, .skipAd, [class*='skip-ad' i], [class*='skipad' i], [aria-label*='skip ad' i]";
  function skipAd(m) {
    const root = m.closest(PLAYER) || m.getRootNode() || document;
    const btns = [...root.querySelectorAll(SKIP), ...[...root.querySelectorAll("button, [role=button]")].filter((b) => /^\s*skip( ad)?\b/i.test(b.textContent || ""))];
    const btn = btns.find((b) => b.offsetParent !== null || b.getClientRects().length);
    if (btn) { try { btn.click(); } catch (e) {} }
    if (Number.isFinite(m.duration) && m.duration > 0) { try { m.currentTime = Math.max(0, m.duration - 0.05); } catch (e) {} }
    else if (!m.currentSrc || Number.isNaN(m.duration)) return;
    else { try { m.muted = true; m.playbackRate = 16; } catch (e) {} }
    if (m.paused) m.play().catch(() => {});
    if (!m.closest(".html5-video-player")) m.muted = true;
  }
  function applyLoop(m) {
    const want = loop.track && !loop.ab && !isAd(m);   // A–B does its own jump at B; native loop is the whole track
    if (m.loop !== want) m.loop = want;
  }

  // A–B: jump back to A the moment B is reached (checked every 20 ms, so the jump lands on time).
  function checkAB() {
    const m = media;
    if (!m || m.paused || !loop.ab || loop.a == null || loop.b == null || isAd(m)) return;
    if (m.currentTime >= loop.b) m.currentTime = loop.a;
  }

  const EVENTS = ["play", "playing", "pause", "seeking", "seeked", "ratechange", "waiting", "loadedmetadata", "ended", "volumechange", "durationchange"];
  function onEvent(e) {
    const m = e.target;
    if (!(m instanceof HTMLMediaElement)) return;
    const starts = e.type === "play" || e.type === "playing" || (e.type === "volumechange" && !m.paused);
    // A muted player only takes over when nothing audible is playing (it's unmuted later: volumechange).
    if (starts && (m === media || audible(m) || !media || media.paused || !audible(media))) {
      const was = media;
      media = m;
      if (enabled) announce(m);
      if (m !== was && !flat()) applyFx();   // the sound follows to the player that takes over
    }
    ctxFollow(e);
    if (m === media) { if (e.type === "loadedmetadata" || e.type === "durationchange" || e.type === "playing") applyLoop(m); report(); }
  }
  for (const t of EVENTS) document.addEventListener(t, onEvent, true);

  // Media events don't bubble out of shadow roots: listen on those elements themselves.
  const watched = new WeakSet();
  function watch(m) {
    if (!(m instanceof HTMLMediaElement) || watched.has(m)) return;
    watched.add(m);
    if (m.getRootNode() !== document) for (const t of EVENTS) m.addEventListener(t, onEvent);
    if (!m.paused) onEvent({ target: m, type: "playing" });
  }

  // Media already playing when the bridge arrives (extension reloaded, tab restored) sends no play event,
  // nor does a player inside a shadow root.
  function find(root) {
    for (const x of root.querySelectorAll("video,audio")) if (!x.paused && !x.ended && audible(x)) return x;
    for (const el of root.querySelectorAll("*")) if (el.shadowRoot) { const x = find(el.shadowRoot); if (x) return x; }
    return null;
  }
  function scan() {
    if (media && !media.paused) return;
    const m = find(document);
    if (m) watch(m);
  }
  setInterval(scan, 1000);

  // A request the app holds open and answers the instant a control is pressed — no polling delay.
  (async function listen() {
    for (;;) {
      if (!enabled || !media || !media.currentSrc) { await new Promise((r) => setTimeout(r, 300)); continue; }
      const r = await app("/wait", { url: srcOf(media) });
      if (r && r.cmds && r.cmds.length) { r.cmds.forEach(run); report(); }
      else if (!r) await new Promise((res) => setTimeout(res, 1000));   // app not running
    }
  })();

  // Frequent reports keep the drift tiny and pick up the window's commands quickly, paused or playing.
  // A background tab's timers are throttled to a second or more: there the background script (never throttled)
  // sends the ticks. Only a frame with a player connects, and the page's own timers run whenever it's visible.
  let ticks = 0, port = null;
  setInterval(() => {
    if (port || !media) return;
    try {
      port = browser.runtime.connect({ name: "tick" });
      port.onMessage.addListener(() => {
        if (!document.hidden) return;
        checkAB();
        if (++ticks % 3 === 0) report();
      });
      port.onDisconnect.addListener(() => { port = null; });
    } catch (e) {}
  }, 1000);
  setInterval(() => { if (!document.hidden) checkAB(); }, 20);
  setInterval(() => { if (!document.hidden) report(); }, 150);

  browser.runtime.onMessage.addListener((msg) => {
    if (msg.cmd === "toggle") {
      enabled = !enabled;
      return Promise.resolve({ running: enabled });
    }
    if (msg.cmd === "status") return Promise.resolve({ running: enabled, hasMedia: !!media });
    if (msg.cmd === "fx") return Promise.resolve(fxState());
  });
})();
