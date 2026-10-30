// Runs inside the AudioWorklet, never in this Worker. A phase vocoder: each 2048-sample frame is
// taken to the frequency domain, every partial is moved up or down by the ratio with its phase
// kept continuous (phase-locked, see frame()), and the frame is put back together by overlap-add
// (8 frames overlap). The length of the sound never changes, so the key moves while
// the tempo, and the media element's own playback speed, stay exactly as they are.
// Latency is one whole frame, N = 2048 samples (46 ms at 44.1 kHz), measured by noise cross-correlation:
// the output rover starts a hop behind the frame (LAT), and each frame's first hop is the oldest audio in it.
(function keyProcessor() {
  const N = 2048;
  const OS = 8;
  const HOP = N / OS;
  const HALF = N / 2;
  const LAT = N - HOP;
  // the true delays, in frames, for the page (live dry paths, bake's skip): measured, see above
  const KEY_DELAY = N;
  // the deck's resampler (see DeckProcessor.lowpass())
  const TAPS = 64;
  const PH = 512;
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
  const re2 = new Float64Array(N);
  const im2 = new Float64Array(N);
  const mag2 = new Float64Array(HALF + 1);
  const pha2 = new Float64Array(HALF + 1);
  const mm = new Float64Array(HALF + 1);
  const mph = new Float64Array(HALF + 1);
  const oRe2 = new Float64Array(HALF + 1);
  const oIm2 = new Float64Array(HALF + 1);
  const peaks = new Int32Array(HALF);

  const channel = () => ({
    inF: new Float32Array(N),
    outF: new Float32Array(N),
    acc: new Float64Array(2 * N),
    lastPh: new Float64Array(HALF + 1),
    pkPh: new Float64Array(HALF + 1),
    rover: LAT,
  });

  // ha: how far the input moved since the last frame. Key's is always HOP. The deck's is the speed
  // times HOP while its output still moves HOP a frame (SPEC 58): that changes the tempo and leaves
  // the pitch, with every frequency the file has (reading the file faster instead would have to
  // cut its top off first). own: the frame moves its own input along (Key); the deck refills it.
  //
  // Both channels go through one frame together (stereo phase lock): the partials are found on the
  // sum of the two, each one's new phase is worked out once, from the sum (the mid), and every bin of
  // either channel keeps its own phase relative to that peak. What the channels differ by, the
  // stereo image, comes out as it went in. At ratio 1 with the input moving a hop (nothing to change)
  // the phases are the analysis phases themselves, so the sound comes back exact, noise included.
  const frame = (A, B, ratio, ha = HOP, own = true) => {
    const ex = (TAU * ha) / N;
    const same = Math.abs(ratio - 1) < 1e-6 && ha === HOP;

    for (let k = 0; k < N; k++) {
      re[k] = A.inF[k] * win[k];
      im[k] = 0;
      re2[k] = B.inF[k] * win[k];
      im2[k] = 0;
    }

    fft(re, im, false);
    fft(re2, im2, false);

    // analysis: magnitude and phase of each channel, and the true frequency of each bin (in bins),
    // from how far the mid's phase moved since the last frame
    let top = 0;

    for (let k = 0; k <= HALF; k++) {
      const sr = re[k] + re2[k];
      const si = im[k] + im2[k];
      const ph = Math.atan2(si, sr);
      let d = ph - A.lastPh[k] - k * ex;
      A.lastPh[k] = ph;

      let q = Math.trunc(d / Math.PI);
      q += q >= 0 ? q & 1 : -(q & 1);
      d -= Math.PI * q;

      mag[k] = 2 * Math.sqrt(re[k] * re[k] + im[k] * im[k]);
      pha[k] = Math.atan2(im[k], re[k]);
      mag2[k] = 2 * Math.sqrt(re2[k] * re2[k] + im2[k] * im2[k]);
      pha2[k] = Math.atan2(im2[k], re2[k]);
      mm[k] = Math.sqrt(sr * sr + si * si);
      mph[k] = ph;
      frq[k] = k + (N * d) / (TAU * ha);
      if (mm[k] > top) top = mm[k];
    }

    oRe.fill(0);
    oIm.fill(0);
    oRe2.fill(0);
    oIm2.fill(0);

    if (same) {
      for (let k = 0; k <= HALF; k++) {
        oRe[k] = re[k];
        oIm[k] = im[k];
        oRe2[k] = re2[k];
        oIm2[k] = im2[k];
        A.pkPh[k] = mph[k];
      }
    } else {
      // the partials: local maxima of the mid's spectrum (quieter than -90 dB of the loudest is noise)
      const floor = top * 3e-5;
      let np = 0;

      for (let k = 2; k < HALF - 1; k++) {
        const m = mm[k];
        if (m > floor && m > mm[k - 1] && m >= mm[k + 1] && m > mm[k - 2] && m >= mm[k + 2]) peaks[np++] = k;
      }

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

        const ph = (A.pkPh[q] + w * EXPECT) % TAU;
        const rot = ph - mph[p];

        for (let k = lo; k <= hi; k++) {
          const t = k + shift;
          if (t < 0 || t > HALF) continue;

          const a = rot + pha[k];
          const b = rot + pha2[k];
          oRe[t] += mag[k] * Math.cos(a);
          oIm[t] += mag[k] * Math.sin(a);
          oRe2[t] += mag2[k] * Math.cos(b);
          oIm2[t] += mag2[k] * Math.sin(b);
          nextPk[t] = ph;
        }
      }

      A.pkPh.set(nextPk);
      // (the full-scale halves were doubled into mag above; the identity path takes the bins as they are)
      for (let k = 0; k <= HALF; k++) {
        oRe[k] *= 0.5;
        oIm[k] *= 0.5;
        oRe2[k] *= 0.5;
        oIm2[k] *= 0.5;
      }
    }

    synth(A, oRe, oIm, own);
    synth(B, oRe2, oIm2, own);
  };

  // one channel's bins back to sound, overlap-added into its output
  const synth = (c, oR, oI, own) => {
    for (let k = 0; k <= HALF; k++) {
      re[k] = oR[k];
      im[k] = oI[k];
    }

    // the other half mirrors this one (real sound), so the inverse comes out real
    for (let k = HALF + 1; k < N; k++) {
      re[k] = re[N - k];
      im[k] = -im[N - k];
    }

    fft(re, im, true);

    // (Hann in, Hann out, 8 overlapping: the windows sum to 3, hence the 3)
    for (let k = 0; k < N; k++) c.acc[k] += (4 * win[k] * re[k]) / (3 * HALF * OS);
    for (let k = 0; k < HOP; k++) c.outF[k] = c.acc[k];

    c.acc.copyWithin(0, HOP, HOP + N);
    if (own) c.inF.copyWithin(0, HOP, N);
  };

  // The deck's vocoder input: the newest file frames read so far, a few hops more than one frame.
  const RING = 8192;
  const vchan = () => Object.assign(channel(), { ring: new Float32Array(RING), rw: 0 });

  // a radix-2 FFT of any power of two, with its own tables (the extractor's 4096), unscaled both ways
  const makeFFT = (n) => {
    const bits = Math.log2(n);
    const rv = new Uint32Array(n);
    for (let i = 0; i < n; i++) {
      let r = 0;
      for (let b = 0; b < bits; b++) r |= ((i >> b) & 1) << (bits - 1 - b);
      rv[i] = r;
    }
    const cs = new Float64Array(n / 2);
    const sn = new Float64Array(n / 2);
    for (let i = 0; i < n / 2; i++) {
      cs[i] = Math.cos((TAU * i) / n);
      sn[i] = Math.sin((TAU * i) / n);
    }

    return (re, im, inverse) => {
      for (let i = 0; i < n; i++) {
        const j = rv[i];
        if (j > i) {
          let t = re[i];
          re[i] = re[j];
          re[j] = t;
          t = im[i];
          im[i] = im[j];
          im[j] = t;
        }
      }

      for (let size = 2; size <= n; size <<= 1) {
        const h = size >> 1;
        const step = n / size;

        for (let s = 0; s < n; s += size) {
          for (let k = 0; k < h; k++) {
            const wr = cs[k * step];
            const wi = inverse ? sn[k * step] : -sn[k * step];
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
      const A = this.ch[0];
      const B = this.ch[1];
      const xa = inp[0];
      const xb = inp[1] || inp[0];
      const ya = out[0];
      const yb = out[1] || null;

      // both channels together, so one frame works out both (see frame())
      for (let i = 0; i < ya.length; i++) {
        A.inF[A.rover] = xa ? xa[i] : 0;
        B.inF[A.rover] = xb ? xb[i] : 0;
        ya[i] = A.outF[A.rover - LAT];
        if (yb) yb[i] = B.outF[A.rover - LAT];

        if (++A.rover >= N) {
          A.rover = LAT;
          frame(A, B, this.ratio);
        }
      }

      return true;
    }
  }

  // ----- the extractor (SPEC 30): a stereo recording's centre, where the voice almost always is, taken out or kept alone -----
  //
  // Each 4096-sample frame of both channels goes to the frequency domain (one complex FFT carries the two), and in
  // every bin the part the channels share is estimated: the centre (Center Cut: their sum, scaled down by how much
  // they differ there). Below 0 the centre comes out of both channels, so the band stays in stereo and the voice goes:
  // an instrumental. The lowest notes (bass, kick drum), which a mix also puts in the centre, are left in. Above 0 the
  // centre is kept alone: the voice without the band, and without those lows. Hann in and out, 4 overlapping, so at 0
  // the sound comes back exactly as it went in, VN = 4096 frames later (85 ms at 48 kHz; measured, not VLAT = VN - VHOP). A mono recording has nothing but
  // a centre: that is said once ({ mono: true }), and its instrumental would be silence.
  const VN = 4096;
  const VOS = 4;
  const VHOP = VN / VOS;
  const VHALF = VN / 2;
  const VLAT = VN - VHOP;
  const vfft = makeFFT(VN);
  const vwin = new Float64Array(VN);
  for (let i = 0; i < VN; i++) vwin[i] = 0.5 - 0.5 * Math.cos((TAU * i) / VN);
  const VSCALE = 1 / (1.5 * VN); // the inverse FFT gives N times the frame; Hann² 4 times over sums to 1.5
  const vre = new Float64Array(VN);
  const vim = new Float64Array(VN);
  const vout = new Float64Array(4 * (VHALF + 1)); // each bin's left (re, im) and right (re, im) once changed

  // a raised-cosine step from 0 at f0 to 1 at f1
  const ramp = (f, f0, f1) => (f <= f0 ? 0 : f >= f1 ? 1 : 0.5 - 0.5 * Math.cos((Math.PI * (f - f0)) / (f1 - f0)));

  // @ts-ignore -- available in AudioWorkletGlobalScope at runtime.
  class VoxProcessor extends AudioWorkletProcessor {
    constructor(o) {
      super();
      // an export renders offline, where a message could arrive after the first frame: it passes the amount in here
      const p = (o && o.processorOptions) || {};
      this.amount = typeof p.amount === "number" ? Math.max(-1, Math.min(1, p.amount)) : 0;
      this.done = false;
      this.keepLow = new Float64Array(VHALF + 1); // how much of the centre comes out: none below 90 Hz, all above 180
      this.voice = new Float64Array(VHALF + 1); // how much of the centre the voice alone keeps: none below 60 Hz
      for (let k = 0; k <= VHALF; k++) {
        // @ts-ignore -- sampleRate is provided by AudioWorkletGlobalScope at runtime.
        const f = (k * sampleRate) / VN;
        this.keepLow[k] = ramp(f, 90, 180);
        this.voice[k] = ramp(f, 60, 120);
      }
      this.reset();

      // @ts-ignore -- port is provided by AudioWorkletProcessor at runtime.
      this.port.onmessage = (e) => {
        const m = e.data || {};
        if (typeof m.amount === "number" && m.amount >= -1 && m.amount <= 1) this.amount = m.amount;
        if (m.reset) this.reset();
        if (m.end) this.done = true;
      };
    }

    reset() {
      this.inL = new Float64Array(VN);
      this.inR = new Float64Array(VN);
      this.acL = new Float64Array(VN);
      this.acR = new Float64Array(VN);
      this.oL = new Float64Array(VHOP);
      this.oR = new Float64Array(VHOP);
      this.rover = VLAT;
      this.dS = 0;
      this.sS = 0;
      this.nF = 0;
      this.mono = false;
    }

    frame() {
      const a = this.amount;

      for (let n = 0; n < VN; n++) {
        vre[n] = this.inL[n] * vwin[n];
        vim[n] = this.inR[n] * vwin[n];
      }

      vfft(vre, vim, false);

      for (let k = 0; k <= VHALF; k++) {
        // the two channels out of the one transform: L = (Z[k] + Z*[N-k]) / 2, R = (Z[k] - Z*[N-k]) / 2i
        const j = (VN - k) & (VN - 1);
        const zr = vre[k];
        const zi = vim[k];
        const cr = vre[j];
        const ci = -vim[j];
        const Lr = 0.5 * (zr + cr);
        const Li = 0.5 * (zi + ci);
        const Rr = 0.5 * (zi - ci);
        const Ri = 0.5 * (cr - zr);
        const Sr = Lr + Rr;
        const Si = Li + Ri;
        const Dr = Lr - Rr;
        const Di = Li - Ri;
        const s2 = Sr * Sr + Si * Si;
        const d2 = Dr * Dr + Di * Di;

        this.dS += d2;
        this.sS += s2;

        let al = s2 > 1e-30 ? 0.5 - 0.5 * Math.sqrt(d2 / s2) : 0;
        if (al < 0) al = 0;

        const Cr = al * Sr;
        const Ci = al * Si;
        const o = 4 * k;

        if (a <= 0) {
          const m = -a * this.keepLow[k];
          vout[o] = Lr - m * Cr;
          vout[o + 1] = Li - m * Ci;
          vout[o + 2] = Rr - m * Cr;
          vout[o + 3] = Ri - m * Ci;
        } else {
          const u = 1 - a;
          const w = a * this.voice[k];
          vout[o] = u * Lr + w * Cr;
          vout[o + 1] = u * Li + w * Ci;
          vout[o + 2] = u * Rr + w * Cr;
          vout[o + 3] = u * Ri + w * Ci;
        }
      }

      // both channels back into one spectrum, Z = L + iR, over both halves
      for (let k = 0; k <= VHALF; k++) {
        const o = 4 * k;
        const lr = vout[o];
        const li = vout[o + 1];
        const rr = vout[o + 2];
        const ri = vout[o + 3];

        vre[k] = lr - ri;
        vim[k] = li + rr;

        if (k > 0 && k < VHALF) {
          vre[VN - k] = lr + ri;
          vim[VN - k] = rr - li;
        }
      }

      vfft(vre, vim, true);

      for (let n = 0; n < VN; n++) {
        this.acL[n] += vwin[n] * vre[n] * VSCALE;
        this.acR[n] += vwin[n] * vim[n] * VSCALE;
      }

      for (let n = 0; n < VHOP; n++) {
        this.oL[n] = this.acL[n];
        this.oR[n] = this.acR[n];
      }

      this.acL.copyWithin(0, VHOP);
      this.acR.copyWithin(0, VHOP);
      this.acL.fill(0, VN - VHOP);
      this.acR.fill(0, VN - VHOP);
      this.inL.copyWithin(0, VHOP);
      this.inR.copyWithin(0, VHOP);

      // about every half second: is there anything but a centre? (silence says nothing)
      if (++this.nF >= 24) {
        if (this.sS > 1e-6) {
          const mono = this.dS < 1e-7 * this.sS;
          if (mono !== this.mono) {
            this.mono = mono;
            // @ts-ignore -- port is provided by AudioWorkletProcessor at runtime.
            this.port.postMessage({ mono });
          }
        }
        this.nF = 0;
        this.dS = 0;
        this.sS = 0;
      }
    }

    process(inputs, outputs) {
      if (this.done) return false;

      const inp = inputs[0] || [];
      const xl = inp[0] || null;
      const xr = inp[1] || xl;
      const out = outputs[0];
      const yl = out[0];
      const yr = out[1] || null;

      for (let i = 0; i < yl.length; i++) {
        this.inL[this.rover] = xl ? xl[i] : 0;
        this.inR[this.rover] = xr ? xr[i] : 0;

        const j = this.rover - VLAT;
        yl[i] = this.oL[j];
        if (yr) yr[i] = this.oR[j];

        if (++this.rover >= VN) {
          this.rover = VLAT;
          this.frame();
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
  // Speed is how fast the vocoder walks through the file: its input moves speed × HOP a frame while
  // its output moves HOP, so the tempo changes and the pitch doesn't, with every frequency the file
  // has (SPEC 58: reading the file faster and taking the key back down after would first have had to
  // cut off its top, a fifth of it at 1.25x, half at 2x). Key moves the partials as it does for the
  // Key processor. Tempo and key stay independent. At 1x and Key 0 the vocoder is out of the way.
  // @ts-ignore -- available in AudioWorkletGlobalScope at runtime.
  class DeckProcessor extends AudioWorkletProcessor {
    constructor(o) {
      super();

      const p = (o && o.processorOptions) || {};

      this.cs = p.chunk; // frames per chunk
      this.fi = -Infinity; // the next file frame to pass through the filter
      this.h = [new Float64Array(TAPS), new Float64Array(TAPS)]; // the last TAPS that did
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
      this.ch = [vchan(), vchan()];
      this.vr = 0; // where the vocoder's output is within its hop
      this.since = 0; // file frames into the vocoder since its last frame
      this.hf = 0; // the part of a frame the speed's hop is owed
      this.gIn = 0; // the fade as the vocoder last read the file
      this.stale = false; // the plain sound fell behind while the vocoder read at another speed
      this.sync = 0; // frames since it is being fed again
      this.dly = [new Float32Array(KEY_DELAY), new Float32Array(KEY_DELAY)]; // the plain sound, lined up with the vocoder's (a whole frame)
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

    // A file at another rate than the context's is resampled through a windowed sinc (TAPS taps, Kaiser,
    // cut off at 0.45 of the lower of the two rates), from a table of PH phases with a straight line
    // between neighbouring phases. Catmull-Rom before it let 15 kHz through with images at -20 dB.
    // At the context's own rate the frames go through untouched.
    lowpass(step) {
      this.lstep = step;
      this.lk = null;
      if (Math.abs(step - 1) < 1e-9) return;

      const fc = 0.45 / Math.max(1, step); // in file frames
      const I0 = (v) => {
        let s = 1;
        let t = 1;
        for (let k = 1; k < 40; k++) {
          t *= (v / (2 * k)) * (v / (2 * k));
          s += t;
        }
        return s;
      };
      const beta = 9;
      const ib = I0(beta);
      const tab = new Float64Array((PH + 1) * TAPS);

      for (let p = 0; p <= PH; p++) {
        const t = p / PH;
        let sum = 0;

        for (let j = 0; j < TAPS; j++) {
          const u = j - (TAPS / 2 - 1) - t; // tap j is frame i + j - (TAPS/2 - 1); x = i + t
          const r = u / (TAPS / 2);
          const kw = Math.abs(r) >= 1 ? 0 : I0(beta * Math.sqrt(1 - r * r)) / ib;
          const sx = u === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * u) / (Math.PI * u);
          tab[p * TAPS + j] = sx * kw;
          sum += sx * kw;
        }

        for (let j = 0; j < TAPS; j++) tab[p * TAPS + j] /= sum;
      }

      this.lk = tab;
    }

    push() {
      for (let c = 0; c < 2; c++) {
        const h = this.h[c];
        h.copyWithin(0, 1);
        h[TAPS - 1] = this.at(c, this.fi);
      }

      this.fi++;
    }

    // The sound at x, into ra and rb. The file is read in order, so each frame is fetched once.
    read(x) {
      const i = Math.floor(x);
      const want = i + TAPS / 2 + 1; // the next frame to fetch once the newest tap is in

      if (this.fi > want || want - this.fi > 2 * TAPS) {
        this.fi = want - TAPS;
        this.h.forEach((h) => h.fill(0));
      }

      while (this.fi < want) this.push();

      const t = x - i;
      const C = TAPS / 2 - 1; // h[C] is frame i

      if (!this.lk) {
        // the context's rate: the frames themselves (positions are whole frames here)
        this.ra = this.h[0][C];
        this.rb = this.h[1][C];
        return;
      }

      const f = t * PH;
      const p = Math.min(PH - 1, Math.floor(f));
      const g = f - p;
      const k = this.lk;
      const o0 = p * TAPS;
      const o1 = o0 + TAPS;
      const A = this.h[0];
      const B = this.h[1];
      let a = 0;
      let b = 0;

      for (let j = 0; j < TAPS; j++) {
        const w = k[o0 + j] + g * (k[o1 + j] - k[o0 + j]);
        a += A[j] * w;
        b += B[j] * w;
      }

      this.ra = a;
      this.rb = b;
    }

    // one frame of the file at 1x into the vocoder (both channels)
    feed(a, b) {
      const A = this.ch[0];
      const B = this.ch[1];

      A.ring[A.rw & (RING - 1)] = a;
      B.ring[B.rw & (RING - 1)] = b;
      A.rw++;
      B.rw++;
      this.since++;
    }

    // the vocoder's next frame out, into pa and pb. At the end of a hop it works out the next one, from
    // the newest N frames in: reading a hop of the file at the speed first when it walks on its own (burst)
    voc(ratio, burst) {
      const A = this.ch[0];
      const B = this.ch[1];

      this.pa = A.outF[this.vr];
      this.pb = B.outF[this.vr];

      if (++this.vr < HOP) return;
      this.vr = 0;

      if (burst) {
        this.hf += this.speed * HOP;
        const n = Math.floor(this.hf);
        this.hf -= n;

        // the fade, eased across the hop as the output had it
        for (let j = 0; j < n; j++) {
          const g = this.gIn + ((this.g - this.gIn) * (j + 1)) / n;
          let a = 0;
          let b = 0;

          if (g > 0) {
            this.read(this.pos);
            a = this.ra * g;
            b = this.rb * g;
            this.pos += this.rate;
            this.quiet = 0;
          } else {
            this.quiet++;
          }

          this.feed(a, b);
        }
      }

      this.gIn = this.g;

      const ha = this.since;
      this.since = 0;

      [A, B].forEach((st) => {
        for (let k = 0; k < N; k++) st.inF[k] = st.ring[(st.rw - N + k) & (RING - 1)];
      });

      if (ha > 0) frame(A, B, ratio, ha, false);
      else {
        A.outF.fill(0);
        B.outF.fill(0);
      }
    }

    process(inputs, outputs) {
      if (this.done) return false;

      const out = outputs[0];
      const L = out[0];
      const R = out[1] || null;
      const ratio = Math.pow(2, this.key / 12);
      const at1x = Math.abs(this.speed - 1) < 1e-4;
      const shifting = Math.abs(ratio - 1) > 1e-4 || !at1x;
      const FADE = 1 / 240;

      // the file is read at the context's own rate; the speed is the vocoder's (a file at another rate
      // than the context's is resampled here, through the low-pass when it has more top than fits)
      if (this.rate !== this.lstep) this.lowpass(this.rate);
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

      // The vocoder starts from clean, in step with the plain sound (a frame of the file in for each one out),
      // and is heard only once it has a whole frame to work with. It walks the file at the speed on its own
      // (burst) only once it is all that is heard; going back, it is in step again for a whole frame before
      // the plain sound takes over, so the two always cross over lined up.
      if (shifting && !this.pv) {
        this.ch = [vchan(), vchan()];
        this.pv = true;
        this.warm = N;
        this.vr = 0;
        this.since = 0;
        this.hf = 0;
        this.gIn = this.g;
        this.stale = false;
        this.sync = 0;
      }

      for (let i = 0; i < L.length; i++) {
        if (this.seekTo >= 0 && this.g === 0) {
          this.pos = this.seekTo;
          this.seekTo = -1;
        }

        const want = this.play && this.seekTo < 0 && this.pos < this.total ? 1 : 0;

        if (this.g < want) this.g = Math.min(1, this.g + FADE);
        else if (this.g > want) this.g = Math.max(0, this.g - FADE);

        const burst = this.pv && this.w >= 1 && shifting && !at1x;
        let ya = 0;
        let yb = 0;

        if (!burst) {
          let a = 0;
          let b = 0;

          if (this.g > 0) {
            this.read(this.pos);
            a = this.ra * this.g;
            b = this.rb * this.g;
            this.pos += this.rate;
            this.quiet = 0;
          } else {
            this.quiet++;
          }

          ya = this.dly[0][this.di];
          yb = this.dly[1][this.di];
          this.dly[0][this.di] = a;
          this.dly[1][this.di] = b;
          if (++this.di >= KEY_DELAY) this.di = 0;

          if (this.pv) {
            this.feed(a, b);
            if (this.stale && ++this.sync >= N) this.stale = false;
          }
        }

        if (this.pv) {
          this.voc(ratio, burst);

          if (this.warm > 0) this.warm--;
          else if (shifting) this.w = Math.min(1, this.w + XF);
          else if (!this.stale) this.w = Math.max(0, this.w - XF);

          if (burst) {
            ya = this.pa;
            yb = this.pb;
            // the plain sound stands still meanwhile
            this.stale = true;
            this.sync = 0;
          } else {
            ya += (this.pa - ya) * this.w;
            yb += (this.pb - yb) * this.w;
          }

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
      // (ctx: the context time this block's end will be played at, so the page can match it to what the speakers play)
      // @ts-ignore -- currentTime and sampleRate are AudioWorkletGlobalScope's
      this.port.postMessage({ at: this.pos / this.sr, ctx: currentTime + 128 / sampleRate, miss: this.miss, playing: this.g > 0 });
      this.miss = -1;
    }
  }

  // the delays, for the page that loads this file as text (bake) or for anyone who asks
  try {
    globalThis.PDC_DELAY = { key: KEY_DELAY, deck: KEY_DELAY, vox: VN };
  } catch (e) {
    /* a scope without globalThis */
  }

  // @ts-ignore -- registerProcessor is provided by AudioWorkletGlobalScope at runtime.
  registerProcessor("pdc-key", KeyProcessor);
  // @ts-ignore -- registerProcessor is provided by AudioWorkletGlobalScope at runtime.
  registerProcessor("pdc-deck", DeckProcessor);
  // @ts-ignore -- registerProcessor is provided by AudioWorkletGlobalScope at runtime.
  registerProcessor("pdc-vox", VoxProcessor);
})();
