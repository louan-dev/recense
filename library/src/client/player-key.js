// Runs inside the AudioWorklet, never in this Worker. A phase vocoder: each 2048-sample frame is
// taken to the frequency domain, every partial is moved up or down by the ratio with its phase
// kept continuous (phase-locked, see frame()), and the frame is put back together by overlap-add
// (8 frames overlap). The length of the sound never changes, so the key moves while
// the tempo, and the media element's own playback speed, stay exactly as they are.
// Latency is one frame less one hop (about 41 ms at 44.1 kHz).
(function keyProcessor() {
  const N = 2048;
  const OS = 8;
  const HOP = N / OS;
  const HALF = N / 2;
  const LAT = N - HOP;
  const TAU = 2 * Math.PI;
  const EXPECT = (TAU * HOP) / N;

  const win = new Float64Array(N);
  for (let i = 0; i < N; i++) win[i] = 0.5 - 0.5 * Math.cos((TAU * i) / N);

  const BITS = Math.log2(N);
  const rev = new Uint32Array(N);
  for (let i = 0; i < N; i++) {
    let r = 0;
    for (let b = 0; b < BITS; b++) r |= ((i >> b) & 1) << (BITS - 1 - b);
    rev[i] = r;
  }

  const cosT = new Float64Array(HALF);
  const sinT = new Float64Array(HALF);
  for (let i = 0; i < HALF; i++) {
    cosT[i] = Math.cos((TAU * i) / N);
    sinT[i] = Math.sin((TAU * i) / N);
  }

  // in-place radix-2 FFT, unscaled both ways
  const fft = (re, im, inverse) => {
    for (let i = 0; i < N; i++) {
      const j = rev[i];
      if (j > i) {
        let t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }

    for (let size = 2; size <= N; size <<= 1) {
      const h = size >> 1;
      const step = N / size;

      for (let s = 0; s < N; s += size) {
        for (let k = 0; k < h; k++) {
          const wr = cosT[k * step];
          const wi = inverse ? sinT[k * step] : -sinT[k * step];
          const a = s + k;
          const b = a + h;
          const tr = re[b] * wr - im[b] * wi;
          const ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
  };

  const re = new Float64Array(N);
  const im = new Float64Array(N);
  const mag = new Float64Array(HALF + 1);
  const pha = new Float64Array(HALF + 1);
  const frq = new Float64Array(HALF + 1);
  const oRe = new Float64Array(HALF + 1);
  const oIm = new Float64Array(HALF + 1);
  const nextPk = new Float64Array(HALF + 1);
  const peaks = new Int32Array(HALF);

  const channel = () => ({
    inF: new Float32Array(N),
    outF: new Float32Array(N),
    acc: new Float64Array(2 * N),
    lastPh: new Float64Array(HALF + 1),
    pkPh: new Float64Array(HALF + 1),
    rover: LAT,
  });

  const frame = (c, ratio) => {
    for (let k = 0; k < N; k++) {
      re[k] = c.inF[k] * win[k];
      im[k] = 0;
    }

    fft(re, im, false);

    // analysis: magnitude, phase, and the true frequency of each bin (in bins), from how far
    // its phase moved since the last frame
    let top = 0;

    for (let k = 0; k <= HALF; k++) {
      const ph = Math.atan2(im[k], re[k]);
      let d = ph - c.lastPh[k] - k * EXPECT;
      c.lastPh[k] = ph;

      let q = Math.trunc(d / Math.PI);
      q += q >= 0 ? q & 1 : -(q & 1);
      d -= Math.PI * q;

      mag[k] = 2 * Math.sqrt(re[k] * re[k] + im[k] * im[k]);
      pha[k] = ph;
      frq[k] = k + (OS * d) / TAU;
      if (mag[k] > top) top = mag[k];
    }

    // the partials: local maxima of the spectrum (quieter than -90 dB of the loudest is noise)
    const floor = top * 3e-5;
    let np = 0;

    for (let k = 2; k < HALF - 1; k++) {
      const m = mag[k];
      if (m > floor && m > mag[k - 1] && m >= mag[k + 1] && m > mag[k - 2] && m >= mag[k + 2]) peaks[np++] = k;
    }

    oRe.fill(0);
    oIm.fill(0);
    nextPk.fill(0);

    // Each partial moves with the bins around it as one piece (Laroche and Dolson's
    // phase-locked pitch shift): the piece moves by a whole number of bins, its peak's phase
    // carries on at the new frequency, and every other bin keeps its phase relative to the peak.
    // A partial is never smeared across bins that fight each other, so its level holds.
    for (let i = 0; i < np; i++) {
      const p = peaks[i];
      const lo = i === 0 ? 0 : ((peaks[i - 1] + p) >> 1) + 1;
      const hi = i === np - 1 ? HALF : (p + peaks[i + 1]) >> 1;
      const w = frq[p] * ratio;
      const shift = Math.round(frq[p] * (ratio - 1));
      const q = p + shift;

      if (q < 0 || q > HALF) continue;

      const ph = (c.pkPh[q] + w * EXPECT) % TAU;

      for (let k = lo; k <= hi; k++) {
        const t = k + shift;
        if (t < 0 || t > HALF) continue;

        const a = ph + pha[k] - pha[p];
        oRe[t] += mag[k] * Math.cos(a);
        oIm[t] += mag[k] * Math.sin(a);
        nextPk[t] = ph;
      }
    }

    c.pkPh.set(nextPk);

    for (let k = 0; k <= HALF; k++) {
      re[k] = oRe[k];
      im[k] = oIm[k];
    }

    for (let k = HALF + 1; k < N; k++) {
      re[k] = 0;
      im[k] = 0;
    }

    fft(re, im, true);

    // (Hann in, Hann out, 8 overlapping: the windows sum to 3, hence the 3)
    for (let k = 0; k < N; k++) c.acc[k] += (4 * win[k] * re[k]) / (3 * HALF * OS);
    for (let k = 0; k < HOP; k++) c.outF[k] = c.acc[k];

    c.acc.copyWithin(0, HOP, HOP + N);
    c.inF.copyWithin(0, HOP, N);
  };

  // @ts-ignore -- available in AudioWorkletGlobalScope at runtime.
  class KeyProcessor extends AudioWorkletProcessor {
    constructor(o) {
      super();
      // an export renders offline, where a message could arrive after the first frame: it
      // passes the setting in at construction instead
      const p = (o && o.processorOptions) || {};
      this.ratio = typeof p.ratio === "number" ? p.ratio : 1;
      this.on = !!p.on;
      this.done = false;
      this.ch = [channel(), channel()];

      // @ts-ignore -- port is provided by AudioWorkletProcessor at runtime.
      this.port.onmessage = (e) => {
        const m = e.data || {};

        if (m.reset) this.ch = [channel(), channel()];
        if (typeof m.ratio === "number" && m.ratio >= 0.25 && m.ratio <= 4) this.ratio = m.ratio;
        if (typeof m.on === "boolean") this.on = m.on;
        if (m.end) this.done = true;
      };
    }

    process(inputs, outputs) {
      if (this.done) return false;

      // bypassed: silent and nearly free (the player has already crossfaded to the dry path)
      if (!this.on) return true;

      const inp = inputs[0] || [];
      const out = outputs[0];

      for (let c = 0; c < out.length; c++) {
        const x = inp[c] || inp[0];
        const st = this.ch[c] || (this.ch[c] = channel());
        const y = out[c];

        for (let i = 0; i < y.length; i++) {
          st.inF[st.rover] = x ? x[i] : 0;
          y[i] = st.outF[st.rover - LAT];

          if (++st.rover >= N) {
            st.rover = LAT;
            frame(st, this.ratio);
          }
        }
      }

      return true;
    }
  }

  // The deck: Safari's way to play with Sound on. Safari hands a media element to Web Audio at
  // the file's own 1x pace whatever its playback speed, so above 1x the sound is cut up and
  // skips, and the excess is still being let out after a pause. So on Safari the element plays
  // muted, as the clock and the picture, and this plays the file itself from chunks of decoded
  // sound the page sends in, kept in step with the element by the page.
  //
  // Speed is how fast the file is read (which on its own would also raise the key); the same
  // phase vocoder as Key then takes that key change back out, together with whatever Key asks
  // for. Tempo and key stay independent. At 1x and Key 0 the vocoder is out of the way entirely.
  // @ts-ignore -- available in AudioWorkletGlobalScope at runtime.
  class DeckProcessor extends AudioWorkletProcessor {
    constructor(o) {
      super();

      const p = (o && o.processorOptions) || {};

      this.cs = p.chunk; // frames per chunk
      this.fi = -Infinity; // the next file frame to pass through the filter
      this.h = [new Float64Array(4), new Float64Array(4)]; // the last four that did
      this.lz = [new Float64Array(8), new Float64Array(8)];
      this.lk = null;
      this.lstep = 0;
      this.total = p.total; // frames in the file
      this.sr = p.sr; // the file's sample rate
      // @ts-ignore -- sampleRate is provided by AudioWorkletGlobalScope at runtime.
      this.rate = p.sr / sampleRate; // file frames per output frame, at 1x
      this.chunks = new Map();
      this.ci = -1;
      this.cd = null;
      this.pos = 0;
      this.speed = 1;
      this.key = 0;
      this.play = false;
      this.seekTo = -1;
      this.g = 0; // fade in and out, so a start, stop or jump never clicks
      this.w = 0; // how much of the vocoder is heard, crossfaded against the plain sound
      this.pv = false;
      this.warm = 0;
      this.ch = [channel(), channel()];
      this.dly = [new Float32Array(LAT), new Float32Array(LAT)]; // the plain sound, lined up with the vocoder's
      this.di = 0;
      this.miss = -1;
      this.tick = 0;
      this.quiet = 0;
      this.done = false;

      // @ts-ignore -- port is provided by AudioWorkletProcessor at runtime.
      this.port.onmessage = (e) => {
        const m = e.data || {};

        if (m.chunk != null) {
          this.chunks.set(m.chunk, m.data);
          this.ci = -1;
        }

        if (m.drop) {
          m.drop.forEach((i) => this.chunks.delete(i));
          this.ci = -1;
        }

        if (typeof m.speed === "number" && m.speed > 0) this.speed = m.speed;
        if (typeof m.key === "number") this.key = m.key;
        if (typeof m.seek === "number") this.seekTo = Math.max(0, m.seek * this.sr);
        if (typeof m.play === "boolean") this.play = m.play;
        if (m.end) this.done = true;
      };
    }

    at(c, f) {
      if (f < 0 || f >= this.total) return 0;

      const i = Math.floor(f / this.cs);

      if (i !== this.ci) {
        this.ci = i;
        this.cd = this.chunks.get(i) || null;
      }

      if (!this.cd) {
        this.miss = i;
        return 0;
      }

      const d = this.cd[c] || this.cd[0];
      return d[f - i * this.cs];
    }

    // Reading faster than 1x would fold the top of the sound back down as noise, so above 1x the
    // file passes through a low-pass (4th-order Butterworth, just under the new top) first.
    lowpass(step) {
      this.lstep = step;
      this.lk = null;
      if (step <= 1.0001) return;

      const w = (2 * Math.PI * 0.45) / step;
      const cs = Math.cos(w);

      this.lk = [0.5412, 1.3066].map((q) => {
        const al = Math.sin(w) / (2 * q);
        const a0 = 1 + al;
        return [(1 - cs) / 2 / a0, (1 - cs) / a0, (1 - cs) / 2 / a0, (-2 * cs) / a0, (1 - al) / a0];
      });
    }

    push() {
      for (let c = 0; c < 2; c++) {
        let v = this.at(c, this.fi);
        const h = this.h[c];

        if (this.lk) {
          const z = this.lz[c];

          for (let s = 0; s < 2; s++) {
            const k = this.lk[s];
            const o = 4 * s;
            const y = k[0] * v + k[1] * z[o] + k[2] * z[o + 1] - k[3] * z[o + 2] - k[4] * z[o + 3];
            z[o + 1] = z[o];
            z[o] = v;
            z[o + 3] = z[o + 2];
            z[o + 2] = y;
            v = y;
          }
        }

        h[0] = h[1];
        h[1] = h[2];
        h[2] = h[3];
        h[3] = v;
      }

      this.fi++;
    }

    // The sound at x: a cubic (Catmull-Rom) through the four frames around it, into ra and rb.
    // The file is read in order, so each frame is fetched and filtered once.
    read(x) {
      const i = Math.floor(x);

      if (this.fi > i + 3 || i + 3 - this.fi > 64) {
        this.fi = i - 1;
        this.h.forEach((h) => h.fill(0));
        this.lz.forEach((z) => z.fill(0));
      }

      while (this.fi < i + 3) this.push();

      const t = x - i;
      const r = (h) => h[1] + 0.5 * t * (h[2] - h[0] + t * (2 * h[0] - 5 * h[1] + 4 * h[2] - h[3] + t * (3 * (h[1] - h[2]) + h[3] - h[0])));

      this.ra = r(this.h[0]);
      this.rb = r(this.h[1]);
    }

    shift(c, x, ratio) {
      const st = this.ch[c];
      st.inF[st.rover] = x;
      const y = st.outF[st.rover - LAT];

      if (++st.rover >= N) {
        st.rover = LAT;
        frame(st, ratio);
      }

      return y;
    }

    process(inputs, outputs) {
      if (this.done) return false;

      const out = outputs[0];
      const L = out[0];
      const R = out[1] || null;
      const ratio = Math.pow(2, this.key / 12) / this.speed;
      const shifting = Math.abs(ratio - 1) > 1e-4;
      const step = this.rate * this.speed;
      const FADE = 1 / 240;

      if (step !== this.lstep) this.lowpass(step);
      const XF = 1 / 1024;

      // paused, and every tail long since out: nothing to work out until it plays again
      if (!this.play && this.g === 0 && this.quiet > 2 * N) {
        if (this.seekTo >= 0) {
          this.pos = this.seekTo;
          this.seekTo = -1;
        }

        L.fill(0);
        if (R) R.fill(0);
        this.report();
        return true;
      }

      // the vocoder starts from clean, and is heard only once it has a whole frame to work with
      if (shifting && !this.pv) {
        this.ch = [channel(), channel()];
        this.pv = true;
        this.warm = N;
      }

      for (let i = 0; i < L.length; i++) {
        if (this.seekTo >= 0 && this.g === 0) {
          this.pos = this.seekTo;
          this.seekTo = -1;
        }

        const want = this.play && this.seekTo < 0 && this.pos < this.total ? 1 : 0;

        if (this.g < want) this.g = Math.min(1, this.g + FADE);
        else if (this.g > want) this.g = Math.max(0, this.g - FADE);

        let a = 0;
        let b = 0;

        if (this.g > 0) {
          this.read(this.pos);
          a = this.ra * this.g;
          b = this.rb * this.g;
          this.pos += step;
          this.quiet = 0;
        } else {
          this.quiet++;
        }

        const da = this.dly[0][this.di];
        const db = this.dly[1][this.di];

        this.dly[0][this.di] = a;
        this.dly[1][this.di] = b;
        if (++this.di >= LAT) this.di = 0;

        let ya = da;
        let yb = db;

        if (this.pv) {
          const pa = this.shift(0, a, ratio);
          const pb = this.shift(1, b, ratio);

          if (this.warm > 0) this.warm--;
          else if (shifting) this.w = Math.min(1, this.w + XF);
          else this.w = Math.max(0, this.w - XF);

          ya = da + (pa - da) * this.w;
          yb = db + (pb - db) * this.w;

          if (!shifting && this.w === 0) this.pv = false;
        }

        L[i] = ya;
        if (R) R[i] = yb;
      }

      this.report();
      return true;
    }

    // where it is, about ten times a second, so the page can keep it in step and fed
    report() {
      if (++this.tick < 32) return;

      this.tick = 0;
      // @ts-ignore -- port is provided by AudioWorkletProcessor at runtime.
      this.port.postMessage({ at: this.pos / this.sr, miss: this.miss, playing: this.g > 0 });
      this.miss = -1;
    }
  }

  // @ts-ignore -- registerProcessor is provided by AudioWorkletGlobalScope at runtime.
  registerProcessor("pdc-key", KeyProcessor);
  // @ts-ignore -- registerProcessor is provided by AudioWorkletGlobalScope at runtime.
  registerProcessor("pdc-deck", DeckProcessor);
})();
