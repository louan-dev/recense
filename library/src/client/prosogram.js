// Prosogram: a vocal-performance and shadowing score (notes 20261029 item 20, the ribbon redesign).
// Every prosodic signal is one continuous ribbon running directly under the target-language line, read like a modern
// vocal score, so a learner gets the four things a singer or a shadower needs to mimic a native speaker:
//   anticipation  the whole line's ribbon is preloaded as a ghost (35 %, cool slate) the moment the line is on screen
//   duration      a warm gold fill sweeps along it at the voice's own speed (the host's progress: a held vowel takes
//                 as long to fill as it is held), together with the letters above it
//   pitch         the ribbon's height: the melody of a song, the intonation of a sentence, the contour of a tone
//   stress        the ribbon's thickness: it swells on a stressed or belted syllable and tapers on a murmured one
//   linking       across a word gap the ribbon stays unbroken where the voice runs on; a liaison / enchaînement /
//                 elision dips like a slur (‿) and is turquoise, its sound in small italics under it; where the voice
//                 pauses or breathes the ribbon breaks cleanly
// The glyphs are never moved, spaced, sized or weighted; the ribbon lives in a lane under them. No staff, ticks,
// brackets, rests or separate arcs: one shape per breath group.
const cl = (v, a = 0, b = 1) => v < a ? a : v > b ? b : v
const lerp = (a, b, f) => a + (b - a) * f
const ease = v => { v = cl(v); return v * v * (3 - 2 * v) }

// all lengths × font size; the lane centre (the speaker's reference pitch) sits LANE below the row's top
const LANE = 0.62
const AMP = 0.3                    // h = ±1 → ±AMP, softly limited so the ribbon stays in its lane
const RISE = 0.24, FALL = 0.24, KNEE = 0.05
const THIN = 0.05, THICK = 0.16    // ribbon thickness range (≈ 2 px → 6 px at a 36 px line)
const BREAK = 0.12                 // a pause this long (s) or more after a word breaks the ribbon
const DETACH = 0.85                // …and so does a word the voice clearly stops on
const LIAISON = 'rgb(64,224,208)'  // turquoise: links only
const GHOST = 'rgb(160,172,190)', GOLD = 'rgb(255,206,64)', SUNG = 'rgb(236,226,200)'

const offY = (h, s) => {
  let up = h * AMP * s
  if (up > RISE * s) up = RISE * s + KNEE * s * Math.tanh((up - RISE * s) / (KNEE * s))
  else if (up < -FALL * s) up = -FALL * s - KNEE * s * Math.tanh((-up - FALL * s) / (KNEE * s))
  return -up
}

/** A word's samples as ribbon points: x, y (centre), r (half thickness), in the canvas's frame. */
function wordPoints(x, c, s) {
  const P = x.pts, out = [], y0 = c.y + LANE * s
  const stress = new Set(x.syl.map((sy, i) => sy.stressed ? i : -1).filter(i => i >= 0))
  let lastX = -Infinity
  for (let j = 0; j < P.n; j++) {
    const px = c.x + P.u[j] * c.width
    if (px - lastX < 1.5 && j < P.n - 1) continue
    lastX = px
    const w = cl(P.w[j]) * (stress.has(P.syl[j]) ? 1 : 0.82)
    out.push({ x: px, y: y0 + offY(P.h[j], s), r: s * lerp(THIN, THICK, Math.pow(w, 1.2)) / 2 })
  }
  return out
}

/** The points of the ribbon across a word gap: a slur's dip for a link, an easy glide otherwise. */
function bridge(a, b, s, link) {
  const out = [], n = Math.max(4, Math.round((b.x - a.x) / 3))
  const sag = link ? Math.max(0.14 * s, 0.25 * (b.x - a.x)) : 0
  const r = Math.min(a.r, b.r) * (link ? 0.85 : 0.7)
  for (let i = 1; i < n; i++) {
    const u = i / n, e = ease(u)
    out.push({ x: lerp(a.x, b.x, u), y: lerp(a.y, b.y, e) + sag * 4 * u * (1 - u), r: lerp(a.r, b.r, u) * 0.4 + r * 0.6 * (1 - Math.abs(2 * u - 1) * 0.3) })
  }
  return out
}

/** A filled outline through the points (centre ± r), smooth: no overlapping strokes, so the ghost's opacity is even. */
function outline(pts) {
  const p = new Path2D()
  if (pts.length < 2) { if (pts[0]) { const q = pts[0]; p.ellipse(q.x, q.y, Math.max(q.r, 1.5), q.r, 0, 0, Math.PI * 2) } return p }
  const up = pts.map(q => [q.x, q.y - q.r]), dn = pts.map(q => [q.x, q.y + q.r]).reverse()
  const through = (arr, first) => {
    if (first) p.moveTo(arr[0][0], arr[0][1]); else p.lineTo(arr[0][0], arr[0][1])
    for (let i = 1; i < arr.length - 1; i++) { const mx = (arr[i][0] + arr[i + 1][0]) / 2, my = (arr[i][1] + arr[i + 1][1]) / 2; p.quadraticCurveTo(arr[i][0], arr[i][1], mx, my) }
    const l = arr[arr.length - 1]; p.lineTo(l[0], l[1])
  }
  const a = pts[0], b = pts[pts.length - 1]
  through(up, true)
  p.arc(b.x, b.y, b.r, -Math.PI / 2, Math.PI / 2)        // round ends
  through(dn, false)
  p.arc(a.x, a.y, a.r, Math.PI / 2, Math.PI * 1.5)
  p.closePath()
  return p
}

/** The line's ribbon: breath groups (runs) per row, each with its linked stretches. */
function layout(pro, cells, s) {
  const idx = []
  for (let i = 0; i < cells.length; i++) { const x = pro.word[cells[i].w.flat]; if (x && !x.punct && x.pts && x.pts.n) idx.push(i) }
  const runs = []
  let run = null
  for (let k = 0; k < idx.length; k++) {
    const c = cells[idx[k]], x = pro.word[c.w.flat], pts = wordPoints(x, c, s)
    if (!pts.length) continue
    if (!run || run.row !== c.row) { run = { row: c.row, pts: [], links: [], words: [] }; runs.push(run) }
    run.pts.push(...pts)
    run.words.push({ c, x0: pts[0].x, x1: pts[pts.length - 1].x })
    for (const l of x.inner || []) {                       // an elision / hyphen liaison inside the word
      const a = c.x + l.uFrom * c.width, b = c.x + l.uTo * c.width
      run.links.push({ x0: a, x1: b, sound: l.sound, made: true, inner: true })
    }
    const nc = k + 1 < idx.length ? cells[idx[k + 1]] : null
    const pause = x.breathAfter >= BREAK || x.cutAfter >= DETACH || !nc || nc.row !== c.row
    if (pause) { run = null; continue }
    const nx = pro.word[nc.w.flat], npts = wordPoints(nx, nc, s)
    if (!npts.length) { run = null; continue }
    const link = !!x.link && x.link.next === nc.w.flat && x.link.realized >= 0.7 ? x.link : null
    const a = pts[pts.length - 1], b = npts[0]
    run.pts.push(...bridge(a, b, s, !!link))
    if (link) { const m = (a.x + b.x) / 2, hw = Math.max(0.32 * s, (b.x - a.x) / 2 + 0.12 * s); run.links.push({ x0: m - hw, x1: m + hw, sound: link.sound, made: true, ya: a.y, yb: b.y, gap: b.x - a.x }) }
  }
  return runs
}

/** How far the voice has carried the light on each row, in canvas x: through a word at its progress, and across a
 *  gap from the end of one word to the start of the next over the time between them (so a link fills as it's sung). */
function lights(pro, cells, t, progress) {
  const by = new Map(), seen = cells.filter(c => { const x = pro.word[c.w.flat]; return x && !x.punct })
  for (let i = 0; i < seen.length; i++) {
    const c = seen[i], w = c.w, nx = seen[i + 1]
    let lx = -Infinity
    if (t >= w.s && t < w.e) lx = c.x + c.width * progress(w, t)
    else if (t >= w.e) {
      lx = c.x + c.width
      if (nx && nx.row === c.row) { if (t < nx.w.s) lx = lerp(c.x + c.width, nx.x, nx.w.s > w.e + 0.01 ? cl((t - w.e) / (nx.w.s - w.e)) : 1) }
      else lx = Infinity
    }
    by.set(c.row, Math.max(by.get(c.row) ?? -Infinity, lx))
  }
  return by
}

/** Chord and note names above the ribbon, under the words (item 20): each syllable's sung note, spelled by the host
 *  (f.noteName(midi)), and the chord progression heard so far (f.chords: [{t, text}]) where each chord began. Ghosted
 *  ahead of the light, full once it is reached; a name that would collide with the one before it is left out. */
function labelsAbove(ctx, f, ln, light) {
  const s = ln.size, cells = ln.cells, pro = f.pro, t = f.t, fs = Math.max(9, Math.round(s * 0.3))
  ctx.save(); ctx.textBaseline = 'alphabetic'; ctx.textAlign = 'center'
  ctx.font = `600 ${fs}px -apple-system, "SF Pro Text", sans-serif`
  const placed = new Map()                                  // row → [x0, x1] taken
  const put = (row, x, text, y, color, lit) => {
    const w = ctx.measureText(text).width, x0 = x - w / 2 - 3, x1 = x + w / 2 + 3, taken = placed.get(row) || []
    if (taken.some(([a, b]) => x0 < b && x1 > a)) return
    taken.push([x0, x1]); placed.set(row, taken)
    ctx.globalAlpha = ln.alpha * (lit ? 0.95 : 0.4); ctx.fillStyle = color; ctx.fillText(text, x, y)
  }
  const rowTop = c => c.top + fs * 1.05
  if (f.chords && f.chords.length && cells.length) {         // the progression: blue, on the upper line
    const t0 = cells[0].w.s, t1 = cells[cells.length - 1].w.e
    for (const ch of f.chords) {
      if (ch.t < t0 - 0.3 || ch.t > t1) continue
      let c = cells[0]; for (const q of cells) if (q.w.s <= ch.t) c = q
      const x = c.x + c.width * f.progress(c.w, ch.t)
      put('c' + c.row, x, ch.text, rowTop(c), 'rgb(143,196,255)', ch.t <= t)
    }
  }
  if (f.noteName) {                                          // the melody: a note per syllable, under the chords
    for (const c of cells) {
      const x = pro.word[c.w.flat]; if (!x || x.punct || !x.syl) continue
      for (const sy of x.syl) {
        if (!Number.isFinite(sy.pitch) || !(sy.rel >= 0.4) || sy.un == null) continue
        const px = c.x + sy.un * c.width
        put('n' + c.row, px, f.noteName(sy.pitch), rowTop(c) + (f.chords ? fs * 1.15 : 0), 'rgb(236,226,200)', (light.get(c.row) ?? -Infinity) >= px)
      }
    }
  }
  ctx.restore()
}

// ---------- Host contract ----------
// A host registers the plugin with `Prosogram.mount(host)` and calls plugin.draw(ctx, f) each frame with:
//   f.t                  the time being heard (seconds)
//   f.pro                Prosody.analyze()'s result (prosody.js)
//   f.page               laid-out blocks: [{ size, alpha, cells: [{ w: {text, flat, s, e}, x, y, top, width, row }], font, lineHeight }]
//   f.progress(w, t)     0…1 of how far the light has crossed word w at time t (the host's cadence)
//   f.glyphs             false when the host draws the words itself (Gallery's DOM spans, Recense's native Ink)
//   f.colors             { ahead, pale } for the words, when this module draws them
const plugin = {
  name: 'prosogram', lineGap: 1.9, slotGap: 0.9,
  legend: [
    ['〰 height', 'pitch: melody, intonation, tone'],
    ['〰 thickness', 'stress and loudness'],
    ['‿ turquoise', 'liaison / enchaînement / elision: keep the air flowing'],
    ['gap', 'a pause or a breath'],
    ['ghost → gold', 'what is coming → where the voice is'],
  ],
  draw(ctx, f) {
    const t = f.t, pro = f.pro, C = f.colors || { ahead: 'rgba(255,255,255,0.35)', pale: SUNG }
    for (const ln of f.page) {
      const s = ln.size, cells = ln.cells, a0 = ln.alpha
      const runs = f.ribbon === false ? [] : layout(pro, cells, s), light = lights(pro, cells, t, f.progress)
      ctx.save()
      if (f.noteName || f.chords) labelsAbove(ctx, f, ln, light)
      for (const r of runs) {
        const shape = outline(r.pts), lx = light.get(r.row) ?? -Infinity
        // the ghost: the whole breath group, preloaded
        ctx.globalAlpha = a0 * 0.35; ctx.fillStyle = GHOST; ctx.fill(shape)
        for (const l of r.links) { ctx.save(); ctx.beginPath(); ctx.rect(l.x0, -1e4, l.x1 - l.x0, 2e4); ctx.clip(); ctx.fillStyle = LIAISON; ctx.fill(shape); ctx.restore() }
        // the sweep: gold at the voice, settling to a warm white behind it
        if (lx > r.pts[0].x - r.pts[0].r) {
          ctx.save(); ctx.beginPath(); ctx.rect(-1e4, -1e4, (lx === Infinity ? 2e4 : lx) + 1e4, 2e4); ctx.clip()
          const head = lx === Infinity ? r.pts[r.pts.length - 1].x + 1 : lx
          const g = ctx.createLinearGradient(head - 2.5 * s, 0, head, 0)
          g.addColorStop(0, SUNG); g.addColorStop(1, lx === Infinity ? SUNG : GOLD)
          ctx.globalAlpha = a0; ctx.fillStyle = g; ctx.fill(shape)
          for (const l of r.links) { ctx.save(); ctx.beginPath(); ctx.rect(l.x0, -1e4, l.x1 - l.x0, 2e4); ctx.clip(); ctx.fillStyle = LIAISON; ctx.fill(shape); ctx.restore() }
          ctx.restore()
        }
        // a link's sound, small, under its slur: ghosted ahead, full once the voice is on it
        ctx.textAlign = 'center'; ctx.textBaseline = 'top'; ctx.fillStyle = LIAISON
        ctx.font = `italic ${Math.max(9, Math.round(s * 0.3))}px "Times New Roman", Times, serif`
        for (const l of r.links) {
          if (!l.sound) continue
          const mx = (l.x0 + l.x1) / 2, near = r.pts.reduce((b, q) => Math.abs(q.x - mx) < Math.abs(b.x - mx) ? q : b, r.pts[0])
          ctx.globalAlpha = a0 * (lx >= mx ? 0.95 : 0.4)
          ctx.fillText(l.sound, mx, near.y + near.r + 0.06 * s)
        }
      }
      // the words, only for a host that doesn't draw them itself: ghost ahead, gold under the light, warm white after
      if (f.glyphs !== false) {
        ctx.globalAlpha = a0; ctx.font = ln.font; ctx.textBaseline = 'alphabetic'; ctx.textAlign = 'left'
        for (const c of cells) {
          const w = c.w
          if (t >= w.e) { ctx.fillStyle = C.pale; ctx.fillText(w.text, c.x, c.y); continue }
          if (t < w.s) { ctx.fillStyle = C.ahead; ctx.fillText(w.text, c.x, c.y); continue }
          const edge = c.x + c.width * f.progress(w, t)
          ctx.save(); ctx.beginPath(); ctx.rect(edge, c.top - 20, c.width + 40, ln.lineHeight + 40); ctx.clip()
          ctx.fillStyle = C.ahead; ctx.fillText(w.text, c.x, c.y); ctx.restore()
          ctx.save(); ctx.beginPath(); ctx.rect(c.x - 20, c.top - 20, edge - c.x + 20, ln.lineHeight + 40); ctx.clip()
          ctx.fillStyle = GOLD; ctx.fillText(w.text, c.x, c.y); ctx.restore()
        }
      }
      ctx.restore()
    }
  },
  // for tests and other hosts: the ribbon's breath groups for a laid-out block
  layout,
}

globalThis.Prosogram = {
  plugin,
  /** Register with a host. `host.start(plugin)` is the harness/player hook that drives draw(). */
  mount(host) { host.start(plugin) },
}
