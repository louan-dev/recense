// The rooms of Space, Gallery's reverb (and Recense's: its build.sh copies this file into
// the app bundle). Their impulse responses are synthesised (decaying, darkening noise), so nothing is
// downloaded, and with a fixed seed: the room heard live and the room baked into a download are the same.
// Pure functions, no DOM: the page loads this before gallery.js.
globalThis.GalleryRoom = (() => {
  // two rooms; a player builds each one the first time it is used
  const ROOMS = {
    room: { label: "Room", rt: 0.9, pre: 0.008, dark: 0.55 },
    hall: { label: "Hall", rt: 2.4, pre: 0.022, dark: 0.75 },
  };

  // The same noise every time (a fixed seed), so a download has exactly the room you heard.
  const irData = (id, sr) => {
    const r = ROOMS[id];
    const pre = Math.round(r.pre * sr);
    const len = pre + Math.round(r.rt * 1.1 * sr);
    const out = [];

    for (let c = 0; c < 2; c++) {
      const d = new Float32Array(len);
      let seed = 0x9e3779b9 ^ (c + 1) * 0x85ebca6b;
      let lp = 0;

      const rnd = () => {
        seed = (seed + 0x6d2b79f5) | 0;
        let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
      };

      for (let i = pre; i < len; i++) {
        const t = (i - pre) / sr;
        // the tail closes down as it decays, the way air and walls swallow the highs first
        const k = 0.12 + r.dark * Math.min(1, t / r.rt) * 0.8;
        lp += (1 - k) * (rnd() * 2 - 1 - lp);
        d[i] = lp * Math.pow(10, (-3 * t) / r.rt) * Math.min(1, t / 0.004); // -60 dB at rt
      }

      out.push(d);
    }

    return out;
  };

  // a negative Space is the room played backwards: the tail swells up instead of dying away.
  // Only the first half of the tail is turned round, so the swell arrives sooner (the whole of
  // it would peak a full second after the sound).
  const reverseIR = (d) => d.map((x) => x.slice(0, Math.round(x.length * 0.5)).reverse());

  // how much dry stays and how much room comes in, for an amount from 0 to 1. The same
  // numbers are used live and when a download is baked, so the file is what you heard.
  const spaceGain = (m) => ({ dry: 1 - 0.35 * m, wet: Math.min(1.3, 1.25 * Math.pow(m, 0.7)) });

  return { ROOMS, irData, reverseIR, spaceGain };
})();
