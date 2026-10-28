// Prosogram: Lane's prosogram with Score's notation (dynamics pp … ff where the level changes, hairpins < >, and
// staccato · tenuto – portato –· accent > ricochet ⁘ under the nucleus). Otherwise as Lane: a live prosogram for research and learners, after Mertens' Prosogram / Praat pitch stylisation.
// The glyphs are never moved, spaced, sized or weighted (Pataca et al. 2023); the figure lives in a lane under them.
//   staff    = three faint hairlines under each row: the speaker's reference pitch and ±4 semitones (h = st · semitone),
//              so every height is read in semitones and intervals keep their size across the clip.
//   segment  = each syllable stylised as one tonal segment over its nucleus: level, or a straight glissando from its start
//              to its end height, gently curved when the voice turns inside it (hỏi's dip); a glottal break splits it.
//              Its thickness is loudness, its length the syllable's span.
//   glide    = a thin dotted glide joins syllables the voice runs through (legato, linked); a detached syllable stands alone.
//   nodes    = a dot at the nucleus. Vietnamese: the tone in Chao numbers under it (33 21 35 313 3ʔ5 21ʔ). French: ˈ on the
//              stressed syllable of each rhythmic group, ↗ / ↘ for the phrase-final event. Salient intervals (|Δ| ≥ 3 st)
//              labelled (↘m3).
//   liaison  = a tie from the latent consonant (uFrom) to the vowel (uTo), its sound in IPA brackets; elision: a small tie.
//   breath   = ’ in the gap, // for a long pause.
// Monochrome; one hue (gold) for the live syllable. Per-word geometry is built once (cache by word, width, size, expr
// bucket, neighbours); the sung word is the same geometry clipped at the light.
const cl = (v, a = 0, b = 1) => v < a ? a : v > b ? b : v
const lerp = (a, b, f) => a + (b - a) * f
const ease = v => { v = cl(v); return v * v * (3 - 2 * v) }

// all lengths × font size; the lane centre (the reference pitch) sits LANE below the baseline
const LANE = 0.68
const AMP = 0.3                   // inflection: h = ±1 → ±AMP at expr 1
const RISE = 0.2, FALL = 0.32, KNEE = 0.04    // soft limits: the figure stays inside its lane
const STAFF = 4                   // the staff's outer lines, semitones above / below the reference
const GLISS = 1.5                 // a syllable moving less than this (semitones) is drawn level
const JOIN = 0.45                 // cutAfter below this (and no breath): a glide joins the words
const MARK = 0.1                  // articulation marks: this far under a segment's lower edge
const PIN = 0.8                   // dynamics / hairpin band under the lane centre
const DYN = ['pp', 'p', 'mp', 'mf', 'f', 'ff']
const LOW = 0.62                   // lowest label baseline below the lane centre (clear of the next row)
const TIE = 0.27 - LANE           // inner ties (apostrophe / hyphen) sit just under the glyphs
const LIAISON = 'rgb(93,202,165)'      // reserved for liaisons only (teal; gold is the live position)
const INK = 'rgb(228,224,214)', GREY = 'rgb(150,148,140)', GOLD = 'rgb(255,214,51)'
const CHAO = { ngang: '33', huyen: '21', sac: '35', sacK: '45', hoi: '313', nga: '3ʔ5', nang: '21ʔ', nangK: '21' }

const cache = new Map(), phraseDyn = new Map()
function dynOf(pro, ph) {
  let v = phraseDyn.get(ph.w0); if (v !== undefined) return v
  let sum = 0, cnt = 0
  for (let fl = ph.w0; fl <= ph.w1; fl++) { const x = pro.word[fl]; if (x && x.syl) for (const sy of x.syl) { sum += sy.nE; cnt++ } }
  const e = cnt ? sum / cnt : 0.5
  v = e < 0.22 ? 0 : e < 0.36 ? 1 : e < 0.5 ? 2 : e < 0.64 ? 3 : e < 0.78 ? 4 : 5
  phraseDyn.set(ph.w0, v); return v
}

/** the y of a segment at local x */
function segY(sg, x) {
  const u = cl((x - sg.xa) / Math.max(1e-6, sg.xb - sg.xa))
  if (sg.cy == null) return lerp(sg.ya, sg.yb, u)
  const v = 1 - u; return v * v * sg.ya + 2 * u * v * sg.cy + u * u * sg.yb   // quadratic through the turning point
}

/** the prosogram stylisation of a word: per syllable (or per piece of it, across a glottal break) one segment */
function stylize(x, Wd, s, E, pro, offY) {
  const P = x.pts, n = P.n, e1 = Math.min(1, E), thr = E > 0.01 ? 0.14 / E : Infinity, gl = GLISS * pro.semitone, segs = []
  x.syl.forEach((sy, si) => {
    let j0 = -1, j1 = -1
    for (let j = 0; j < n; j++) if (P.syl[j] === si) { if (j0 < 0) j0 = j; j1 = j }
    if (j0 < 0) return
    const pieces = []; let a = j0
    for (let j = j0; j < j1; j++) if (P.cut[j] > thr && P.cut[j] >= 0.3) { pieces.push([a, j]); a = j + 1 }
    pieces.push([a, j1])
    const span = (sy.u1 - sy.u0) * Wd, inset = Math.min(0.08 * s, span * 0.14)
    pieces.forEach(([ja, jb], pi) => {
      const k = jb - ja + 1, q = Math.max(1, Math.round(k * 0.2))
      let hA = 0, hB = 0, w = 0
      for (let j = ja; j < ja + q; j++) hA += P.h[j]; hA /= q
      for (let j = jb - q + 1; j <= jb; j++) hB += P.h[j]; hB /= q
      for (let j = ja; j <= jb; j++) w += P.w[j]; w /= k
      // a turn inside the syllable: the sample farthest from the chord
      let dev = 0, jm = -1
      for (let j = ja; j <= jb; j++) { const f = k > 1 ? (j - ja) / (k - 1) : 0, d = P.h[j] - lerp(hA, hB, f); if (Math.abs(d) > Math.abs(dev)) { dev = d; jm = j } }
      let xa = P.u[ja] * Wd + (pi === 0 ? inset : 0.02 * s), xb = P.u[jb] * Wd - (pi === pieces.length - 1 ? inset : 0.02 * s)
      if (xb - xa < 3) { const m = (P.u[ja] + P.u[jb]) / 2 * Wd; xa = m - 1.5; xb = m + 1.5 }
      let ya, yb, cy = null
      if (Math.abs(hB - hA) < gl && Math.abs(dev) < gl) { const hm = (hA + hB) / 2; ya = yb = offY(hm) }    // level
      else {
        ya = offY(hA); yb = offY(hB)
        if (Math.abs(dev) >= gl && jm > ja && jm < jb) {                                                   // a turn: through it
          const u = cl((P.u[jm] * Wd - xa) / Math.max(1e-6, xb - xa), 0.2, 0.8), ym = offY(P.h[jm])
          cy = (ym - (1 - u) * (1 - u) * ya - u * u * yb) / (2 * u * (1 - u))
        }
      }
      const lw = Math.max(1, s * lerp(0.026, 0.018 + 0.062 * cl(0.35 + (w - 0.35) * E), e1))
      segs.push({ si, xa, xb, ya, yb, cy, lw, last: pi === pieces.length - 1, first: pi === 0 })
    })
  })
  return segs
}

// ---- geometry of one word, in its own frame (origin: the word's left edge at the lane centre) ------------------
function build(f, x, c, s, E, nb) {
  const pro = f.pro, Wd = c.width, e1 = Math.min(1, E), A = AMP * s * E, thr = E > 0.01 ? 0.14 / E : Infinity
  const offY = h => {
    let up = h * A
    if (up > RISE * s) up = RISE * s + KNEE * s * Math.tanh((up - RISE * s) / (KNEE * s))
    else if (up < -FALL * s) up = -FALL * s - KNEE * s * Math.tanh((-up - FALL * s) / (KNEE * s))
    return -up
  }
  const segs = stylize(x, Wd, s, E, pro, offY)
  const g = { Wd, segs, labels: [], marks: [], glides: new Path2D(), xglide: new Path2D(), ticks: new Path2D(), fdots: new Path2D(), ties: new Path2D(), anchors: new Path2D(), dotted: new Path2D(), inner: null, breath: null, nodes: [], cross: null }
  const segOf = si => segs.filter(q => q.si === si)
  // glides inside the word: from one syllable's segment to the next one's, where the voice ran on
  for (let i = 0; i + 1 < segs.length; i++) {
    const a = segs[i], b = segs[i + 1]
    if (a.si === b.si) continue                                   // a glottal break: no glide
    const P = x.pts; let cut = 0
    for (let j = 0; j < P.n; j++) if (P.syl[j] === a.si) cut = P.cut[j]          // the break after the syllable's last sample
    if (cut > thr) continue
    g.glides.moveTo(a.xb, a.yb); g.glides.lineTo(b.xa, b.ya)
  }
  // nodes at the nucleus; tone numbers (vi), stress marks (fr), phrase-final arrows, salient intervals
  if (E > 0.02) for (const nd of x.nodes) {
    const sg = segOf(nd.syl).find(q => nd.u * Wd >= q.xa - 2 && nd.u * Wd <= q.xb + 2) || segOf(nd.syl)[0]
    if (!sg) continue
    const bx = cl(nd.u * Wd, sg.xa, sg.xb), by = segY(sg, bx), r = Math.max(1.4, sg.lw * 0.45 + 0.6)
    g.nodes.push({ x: bx, y: by, r })
    let ly = by + sg.lw / 2 + 0.36 * s
    if (f.lang === 'vi' && nd.tone) { const sy = x.syl[nd.syl]; g.labels.push({ text: CHAO[sy.toneKey] || CHAO[nd.tone] || '', x: bx, y: Math.min(LOW * s, ly), size: 0.17, a: 0.75, prio: 1, kind: 'tone' }); ly += 0.18 * s }
    { const sy = x.syl[nd.syl]
      if (x.breathAfter >= 0.18 && nd.syl === x.syl.length - 1 && sy.lengthen > 0.4) {   // held before the pause: a fermata
        const fx = (sg.xa + sg.xb) / 2, fy = Math.min(sg.ya, sg.yb) - sg.lw / 2 - 0.07 * s, fr = 0.07 * s
        g.ticks.moveTo(fx - fr, fy); g.ticks.arc(fx, fy, fr, Math.PI, 0); g.fdots.moveTo(fx + 0.018 * s, fy - 0.02 * s); g.fdots.arc(fx, fy - 0.02 * s, 0.018 * s, 0, Math.PI * 2)
      } }
    if (f.lang === 'fr' && nd.stressed) { const y = sg.ya - sg.lw / 2 - 0.04 * s; g.ticks.moveTo(sg.xa, y); g.ticks.lineTo(sg.xa - 0.025 * s, y - 0.1 * s) }   // ˈ before the stressed syllable
    if (nd.interval != null && Math.abs(nd.interval) >= 3) {         // the leap drawn to scale: an arrow as long as the interval
      const len = Math.min(0.4 * s, Math.abs(nd.interval) * pro.semitone * A), ax = bx + 0.09 * s, up = nd.interval > 0
      const y0 = up ? by + len / 2 : by - len / 2, y1 = up ? by - len / 2 : by + len / 2, hd = 0.035 * s
      g.ticks.moveTo(ax, y0); g.ticks.lineTo(ax, y1); g.ticks.moveTo(ax - hd, y1 + (up ? hd : -hd)); g.ticks.lineTo(ax, y1); g.ticks.lineTo(ax + hd, y1 + (up ? hd : -hd))
    }
  }
  g.dots = new Path2D(); g.lines = new Path2D()
  const prevBreath = nb.prevBreath
  if (e1 > 0.02) for (const sy of x.syl) {
    const sg = segOf(x.syl.indexOf(sy))[0]; if (!sg) continue
    const xc = cl(sy.un * Wd, sg.xa, sg.xb), y = segY(sg, xc) + sg.lw / 2 + MARK * s, r = Math.max(1.1, 0.026 * s), d = 0.06 * s
    if (sy.art === 'staccato') { g.dots.moveTo(xc + r, y); g.dots.arc(xc, y, r, 0, Math.PI * 2) }
    else if (sy.art === 'tenuto') { g.lines.moveTo(xc - d, y); g.lines.lineTo(xc + d, y) }
    else if (sy.art === 'portato') { g.lines.moveTo(xc - d, y - 0.02 * s); g.lines.lineTo(xc + d, y - 0.02 * s); g.dots.moveTo(xc + r * 0.9, y + 0.05 * s); g.dots.arc(xc, y + 0.05 * s, r * 0.9, 0, Math.PI * 2) }
    else if (sy.art === 'marcato' && !(sy === x.syl[0] && prevBreath)) { g.lines.moveTo(xc - d, y - 0.04 * s); g.lines.lineTo(xc + d, y); g.lines.lineTo(xc - d, y + 0.04 * s) }
    else if (sy.art === 'ricochet') { const x0 = sg.xa + 0.1 * (sg.xb - sg.xa), x1 = sg.xb - 0.1 * (sg.xb - sg.xa); for (let i = 0; i <= 5; i++) { const tau = i / 5, xx = lerp(x0, x1, tau), yy = y + 0.02 * s - 0.06 * s * Math.sin(Math.PI * tau), rr = r * 0.6; g.dots.moveTo(xx + rr, yy); g.dots.arc(xx, yy, rr, 0, Math.PI * 2) } }
  }
  if (f.lang === 'fr' && x.phraseEnd && segs.length && E > 0.02) {   // the phrase-final event
    const sg = segs[segs.length - 1], nd = x.nodes.find(q => q.stressed)
    const up = nd ? /rise/.test(nd.dir) : /question|continuation|colon/.test(x.phraseEnd)
    g.marks.push({ text: up ? '↗' : '↘', x: sg.xb + 0.13 * s, y: sg.yb + 0.08 * s, size: 0.24 })
  }
  // across the gap: a dotted glide (legato) or a tie from the latent consonant to the vowel (liaison)
  if (nb.out || nb.tie) {
    const o = nb.out || nb.tie, L = nb.out ? nb.out.link : x.link, nsegs = stylize(o.x, o.w, s, E, pro, offY)
    const last = segs[segs.length - 1], first = nsegs[0]
    if (last && first) {
      if (L) {                                                    // the tie: under the two letters' segments
        // the liaison is a slur in the line: from the last segment's end straight into the next word's first segment
        const xa = last.xb, xb = o.dx + first.xa, ya = last.yb, yb = first.ya
        const path = nb.out ? g.ties : g.dotted, sag = Math.min(0.16 * s, 0.05 * s + 0.25 * (xb - xa))
        if (nb.out) {                                             // an engraved tie: a crescent, thick in the middle, pointed ends
          const th = Math.max(1.6, 0.06 * s)
          path.moveTo(xa, ya); path.bezierCurveTo(lerp(xa, xb, 0.3), ya + sag, lerp(xa, xb, 0.7), yb + sag, xb, yb)
          path.bezierCurveTo(lerp(xa, xb, 0.7), yb + sag - th, lerp(xa, xb, 0.3), ya + sag - th, xa, ya); path.closePath()
          const r = Math.max(1.5, 0.045 * s)                    // anchors on the exact two letters
          g.anchors.moveTo(xa + r, ya); g.anchors.arc(xa, ya, r, 0, Math.PI * 2); g.anchors.moveTo(xb + r, yb); g.anchors.arc(xb, yb, r, 0, Math.PI * 2)
        } else { path.moveTo(xa, ya); path.bezierCurveTo(lerp(xa, xb, 0.3), ya + sag, lerp(xa, xb, 0.7), yb + sag, xb, yb) }
        const ob = L.status === 'obligatory', en = L.kind === 'enchainement'
        g.labels.push({ text: nb.out ? `[${L.sound}]` : `([${L.sound}])`, x: (xa + xb) / 2, y: Math.min(LOW * s, Math.max(ya, yb) + sag + 0.3 * s), size: 0.28, a: !nb.out ? 0.5 : ob ? 1 : en ? 0.7 : 0.85, prio: 0, kind: 'link', color: LIAISON })
      } else { g.xglide.moveTo(last.xb, last.yb); g.xglide.lineTo(o.dx + first.xa, first.ya) }
      if (nb.out) g.cross = { x0: last.xb, x1: o.dx + first.xa, ts: nb.out.ts }
    }
  }
  if (x.inner && x.inner.length) {                                // inside the word: elision (half-weight tie) or hyphen liaison (full)
    g.inner = new Path2D()
    const yOn = xx => { let best = null, d = 1e9; for (const q of segs) { const dd = xx < q.xa ? q.xa - xx : xx > q.xb ? xx - q.xb : 0; if (dd < d) { d = dd; best = q } } return best ? segY(best, cl(xx, best.xa, best.xb)) : 0 }
    for (const l of x.inner) {
      const full = l.kind === 'liaison', x0 = l.uFrom * Wd, x1 = l.uTo * Wd
      const drop = full ? 0 : Math.max(...segs.map(q => q.lw)) / 2 + 0.035 * s       // an elision usually sits inside one syllable: hang it just below
      const y0 = yOn(x0) + drop, y1 = yOn(x1) + drop
      const sag = (full ? 0.14 : 0.09) * s, th = Math.max(full ? 1.6 : 1, (full ? 0.06 : 0.03) * s)
      g.inner.moveTo(x0, y0); g.inner.bezierCurveTo(lerp(x0, x1, 0.3), y0 + sag, lerp(x0, x1, 0.7), y1 + sag, x1, y1)
      g.inner.bezierCurveTo(lerp(x0, x1, 0.7), y1 + sag - th, lerp(x0, x1, 0.3), y0 + sag - th, x0, y0); g.inner.closePath()
      if (full) { const r = Math.max(1.5, 0.045 * s); g.inner.moveTo(x0 + r, y0); g.inner.arc(x0, y0, r, 0, Math.PI * 2); g.inner.moveTo(x1 + r, y1); g.inner.arc(x1, y1, r, 0, Math.PI * 2) }
      if (full) g.labels.push({ text: `[${l.sound}]`, x: (x0 + x1) / 2, y: Math.min(LOW * s, Math.max(y0, y1) + sag + 0.3 * s), size: 0.28, a: 0.9, prio: 0, kind: 'link', color: LIAISON })
    }
  }
  if (x.breathAfter >= 0.18) {                                    // ’ in the gap, // for a long pause
    const bx = Wd + (nb.nextGap != null ? nb.nextGap / 2 : 0.2 * s), by = -0.14 * s, p = new Path2D()
    if (x.breathAfter >= 0.6) { for (const o of [-0.045, 0.045]) { p.moveTo(bx + o * s - 0.05 * s, by + 0.13 * s); p.lineTo(bx + o * s + 0.04 * s, by - 0.15 * s) } g.breath = { path: p, stroke: true } }
    else {
      const r = 0.036 * s, hy = by - 0.07 * s
      p.moveTo(bx + r, hy); p.arc(bx, hy, r, 0, Math.PI * 2)
      p.moveTo(bx + r * 0.95, hy + r * 0.2); p.quadraticCurveTo(bx + r * 1.05, hy + r * 2.4, bx - r * 1.3, hy + r * 3.6)
      p.quadraticCurveTo(bx + r * 0.15, hy + r * 2.1, bx - r * 0.1, hy + r * 0.9); p.closePath()
      g.breath = { path: p, stroke: false }
    }
  }
  // the segments as paths (the live syllable's is drawn in gold)
  for (const sg of segs) {
    const p = new Path2D(); p.moveTo(sg.xa, sg.ya)
    if (sg.cy == null) p.lineTo(sg.xb, sg.yb); else p.quadraticCurveTo((sg.xa + sg.xb) / 2, sg.cy, sg.xb, sg.yb)
    sg.path = p
  }
  return g
}

function context(pro, cells, k, idx) {
  const c = cells[idx[k]], x = pro.word[c.w.flat], pc = k > 0 ? cells[idx[k - 1]] : null, nc = k + 1 < idx.length ? cells[idx[k + 1]] : null
  const px = pc && pro.word[pc.w.flat], nx = nc && pro.word[nc.w.flat]
  const linked = (a, bc) => !!a.link && a.link.next === bc.w.flat
  const joins = (a, ac, bc) => {
    if (!bc || ac.row !== bc.row || a.breathAfter) return false
    if (linked(a, bc)) return a.link.realized >= 0.7
    return ac.w.flat + 1 === bc.w.flat && a.cutAfter < JOIN
  }
  const nJoin = !!nc && joins(x, c, nc)
  const out = nJoin ? { dx: nc.x - c.x, w: nc.width, x: nx, link: linked(x, nc) ? x.link : null, ts: nc.w.s } : null
  const tie = !nJoin && nc && nc.row === c.row && linked(x, nc) ? { dx: nc.x - c.x, w: nc.width, x: nx } : null
  const rowEnd = !nc || nc.row !== c.row
  const nb = { out, tie, nextGap: rowEnd ? null : nc.x - c.x - c.width, prevBreath: !pc || pc.row !== c.row || px.breathAfter >= 0.18 }
  nb.key = `${+nb.prevBreath}|${c.w.flat}|${c.width.toFixed(1)}|${out ? (out.dx | 0) + (out.link ? 'L' : '') : '-'}|${tie ? tie.dx | 0 : '-'}|${nb.nextGap != null ? nb.nextGap | 0 : '-'}`
  return nb
}

function drawWord(ctx, f, g, c, cy, s, a0, t, w, p, live, settle, labels) {
  const head = p * g.Wd, k = a0 * lerp(0.95, 0.72, settle)
  ctx.save(); ctx.translate(c.x, cy)
  if (live) { ctx.save(); ctx.beginPath(); ctx.rect(-s, -2 * s, head + s, 4 * s); ctx.clip() }
  ctx.lineCap = 'butt'
  const gl = Math.max(0.8, s * 0.02)
  ctx.strokeStyle = INK; ctx.lineWidth = gl; ctx.setLineDash([gl, gl * 2.5]); ctx.globalAlpha = k * 0.7; ctx.stroke(g.glides); ctx.setLineDash([])
  // the live syllable: the one under the light
  let cur = -1
  if (live) { const x = f.pro.word[w.flat]; for (let i = 0; i < x.syl.length; i++) if (p >= x.syl[i].u0 && p <= x.syl[i].u1) cur = i }
  for (const sg of g.segs) { ctx.strokeStyle = sg.si === cur ? GOLD : INK; ctx.globalAlpha = sg.si === cur ? a0 : k; ctx.lineWidth = sg.lw; ctx.stroke(sg.path) }
  ctx.fillStyle = 'rgb(255,252,244)'
  for (const nd of g.nodes) { ctx.globalAlpha = a0 * lerp(1, 0.8, settle); ctx.beginPath(); ctx.arc(nd.x, nd.y, nd.r, 0, Math.PI * 2); ctx.fill() }
  ctx.textAlign = 'center'; ctx.textBaseline = 'alphabetic'; ctx.fillStyle = INK
  for (const m of g.marks) { ctx.font = `${Math.round(s * m.size)}px "Times New Roman", Times, serif`; ctx.globalAlpha = k * 0.9; ctx.fillText(m.text, m.x, m.y) }
  ctx.strokeStyle = INK; ctx.lineWidth = Math.max(0.9, s * 0.024); ctx.lineCap = 'round'; ctx.lineJoin = 'round'; ctx.globalAlpha = k * 0.9; ctx.stroke(g.ticks); ctx.stroke(g.lines); ctx.fillStyle = INK; ctx.fill(g.fdots)
  ctx.fillStyle = INK; ctx.fill(g.dots)
  if (g.inner) { ctx.fillStyle = LIAISON; ctx.globalAlpha = a0; ctx.fill(g.inner) }
  if (live) { ctx.restore(); ctx.restore(); return }
  if (g.cross) {                                                   // the glide / tie across the gap, as the voice crosses it
    const b = g.cross, rv = b.ts > w.e + 0.01 ? cl((t - w.e) / (b.ts - w.e)) : 1
    ctx.save(); ctx.beginPath(); ctx.rect(-s, -2 * s, b.x0 + (b.x1 - b.x0) * rv + s, 4 * s); ctx.clip()
  } else ctx.save()
  ctx.fillStyle = LIAISON; ctx.globalAlpha = a0; ctx.fill(g.ties); ctx.fill(g.anchors)
  ctx.lineCap = 'butt'; ctx.lineWidth = gl; ctx.setLineDash([gl, gl * 2.5]); ctx.globalAlpha = k * 0.7; ctx.stroke(g.xglide); ctx.setLineDash([])
  ctx.restore()
  ctx.strokeStyle = GREY; ctx.lineWidth = Math.max(0.9, s * 0.024); ctx.setLineDash([0.1, Math.max(3, s * 0.08)]); ctx.globalAlpha = a0 * 0.6; ctx.stroke(g.dotted); ctx.setLineDash([])
  for (const l of g.labels) labels.push({ ...l, x: c.x + l.x, y: cy + l.y, a: a0 * l.a, floor: cy + (LOW + 0.05) * s })
  if (g.breath) {
    ctx.globalAlpha = a0 * 0.8
    if (g.breath.stroke) { ctx.strokeStyle = GREY; ctx.lineWidth = Math.max(1, s * 0.028); ctx.lineCap = 'round'; ctx.stroke(g.breath.path) }
    else { ctx.fillStyle = GREY; ctx.fill(g.breath.path) }
  }
  ctx.restore()
}

// ---------- Host contract ----------
// This module knows nothing about the app hosting it: no host is named anywhere in this file. A host registers the
// plugin with `Prosogram.mount(host)` and then drives it, supplying per frame:
//   f.t, f.dt            time now, and since the last frame (seconds)
//   f.W, f.H, f.dpr      canvas size and backing scale
//   f.pro                the result of Prosody.analyze() — prosody.js (word[], phrases, syllables, semitone, …)
//   f.words              [{ text, flat, s, e }] in order; `flat` indexes into f.pro.word
//   f.lines              laid-out rows: [{ lineHeight, words: [{ x, y, top, width, w }] }]
//   f.at(signal, t)      signal sampler at time t, 0…1, or **null** where the host has no source for that signal —
//                        so draw nothing for it rather than a flat zero. 'E' = loudness over the voice's floor against
//                        its own 95th percentile; 'B' = belt (loud, clear and high in the voice's own range). The
//                        prototype also carries A, S, P, V, Vp, F and C.
//   f.signals            { E: true, B: false, … } which signals this host actually has, so a consumer can hide what
//                        it cannot draw without probing at() first
//   f.glyphs             false when the host draws the words itself (Gallery's DOM spans, Recense's native Ink):
//                        only the figure is drawn, never the text
//   f.progress(w, t)     0…1 of how far the light has crossed word w at time t
//   f.expr               expression amount, 0…1.5 (how far the figure is drawn from the lane centre)
//   f.colors             palette; this module uses `ahead` and `pale` only
//   f.playing            whether the source is playing
// The host calls plugin.draw(ctx, f) each frame and may read `name`, `lineGap`, `slotGap` and `legend` for layout.
// Hosts: the prototype harness (harness.js), Gallery's /main player, Recense's home bar in Sill.
const plugin = {
  name: 'prosogram', lineGap: 2.65, slotGap: 0.9,
  legend: [
    ['≡ staff', 'reference pitch and ±4 semitones'],
    ['▬ / ╱', 'syllable: level or glissando; thickness = loudness'],
    ['┈', 'glide: the voice runs on · gap: detached'],
    ['• 35  ˈ', 'nucleus · Vietnamese tone (Chao) · French stress'],
    ['↗ ↘  ↕', 'phrase-final rise / fall · a leap, drawn to scale'],
    ['𝄐', 'held before a pause'],
    ['▁▂▃▅  < >', 'loudness level (filled bars) · getting louder / softer'],
    ['· – > ⁘', 'staccato · tenuto · accent · ricochet'],
    ['‿ z', 'liaison (teal tie) and its sound; dotted = not made'],
    ['’  //', 'breath · long pause'],
  ],
  draw(ctx, f) {
    const t = f.t, pro = f.pro, C = f.colors, E = cl(f.expr, 0, 1.5), eb = Math.round(E * 20) / 20
    for (const ln of f.page) {
      const s = ln.size, cells = ln.cells, a0 = ln.alpha
      ctx.save()
      // the staff: reference and ±4 semitones under each row, very faint, labelled at the left
      if (E > 0.02) {
        const rows = new Map()
        for (const c of cells) { const r = rows.get(c.row) || { x0: Infinity, x1: -Infinity, y: c.y }; r.x0 = Math.min(r.x0, c.x); r.x1 = Math.max(r.x1, c.x + c.width); rows.set(c.row, r) }
        const A = AMP * s * E, lim = v => { const up = v * A; return -(up > RISE * s ? RISE * s + KNEE * s * Math.tanh((up - RISE * s) / (KNEE * s)) : up < -FALL * s ? -FALL * s - KNEE * s * Math.tanh((-up - FALL * s) / (KNEE * s)) : up) }
        const lines = [[STAFF, '+4'], [0, '0'], [-STAFF, '−4']]
        ctx.lineWidth = Math.max(0.6, s * 0.012); ctx.strokeStyle = INK; ctx.fillStyle = GREY
        ctx.font = `${Math.max(8, Math.round(s * 0.15))}px -apple-system, sans-serif`; ctx.textAlign = 'right'; ctx.textBaseline = 'middle'
        for (const r of rows.values()) for (const [st, lab] of lines) {
          const y = r.y + LANE * s + lim(st * pro.semitone)
          ctx.globalAlpha = a0 * (st === 0 ? 0.2 : 0.11); if (st) ctx.setLineDash([2, 5])
          ctx.beginPath(); ctx.moveTo(r.x0 - 0.1 * s, y); ctx.lineTo(r.x1 + 0.1 * s, y); ctx.stroke(); ctx.setLineDash([])
          ctx.globalAlpha = a0 * 0.4; ctx.fillText(lab, r.x0 - 0.18 * s, y)
        }
      }
      const idx = []
      for (let i = 0; i < cells.length; i++) { const x = pro.word[cells[i].w.flat]; if (x && !x.punct && x.pts.n) idx.push(i) }
      const labels = []
      for (let k = 0; k < idx.length; k++) {
        const c = cells[idx[k]], w = c.w
        if (t < w.s) continue
        const live = t < w.e, p = live ? f.progress(w, t) : 1
        if (p <= 0) continue
        const nb = context(pro, cells, k, idx), key = nb.key + '|' + s + '|' + eb
        let g = cache.get(key)
        if (!g) { g = build(f, pro.word[w.flat], c, s, eb, nb); cache.set(key, g); if (cache.size > 900) { let d = 300; for (const kk of cache.keys()) { cache.delete(kk); if (--d <= 0) break } } }
        drawWord(ctx, f, g, c, c.y + LANE * s, s, a0, t, w, p, live, live ? 0 : ease((t - w.e) / 0.5), labels)
      }
      const lightRow = new Map()
      for (const k of idx) { const c = cells[k], w = c.w, cur = lightRow.get(c.row) ?? -Infinity
        if (t >= w.e) lightRow.set(c.row, Math.max(cur, c.x + c.width + 0.5 * s)); else if (t >= w.s) lightRow.set(c.row, Math.max(cur, c.x + c.width * f.progress(w, t))) }
      if (E > 0.02) for (let pi = 0; pi < pro.phrases.length; pi++) {
        const ph = pro.phrases[pi], first = ln.line.words[0].flat, last = ln.line.words[ln.line.words.length - 1].flat
        if (ph.w1 < first || ph.w0 > last) continue
        const on = []; for (const k of idx) { const c = cells[k]; if (c.w.flat >= ph.w0 && c.w.flat <= ph.w1) on.push(c) }
        if (!on.length) continue
        const dyn = dynOf(pro, ph), showDyn = on[0].w.flat === ph.w0 && (pi === 0 || dynOf(pro, pro.phrases[pi - 1]) !== dyn)
        for (let r0 = 0; r0 < on.length;) {
          let r1 = r0; while (r1 + 1 < on.length && on[r1 + 1].row === on[r0].row) r1++
          const c0 = on[r0], c1 = on[r1], lx = lightRow.get(c0.row) ?? -Infinity, by = c0.y + (LANE + PIN) * s
          if (lx > c0.x) {
            ctx.save(); ctx.beginPath(); ctx.rect(c0.x - s, by - s, lx - c0.x + s, 2 * s); ctx.clip()
            let x0 = c0.x
            if (showDyn && r0 === 0) {                           // the level as a rising stack of six bars, filled up to it
              const bw = 0.045 * s, gap = 0.03 * s
              ctx.fillStyle = INK; ctx.strokeStyle = INK; ctx.lineWidth = Math.max(0.6, s * 0.012)
              for (let q = 0; q < 6; q++) { const h = 0.06 * s + q * 0.04 * s, bx = x0 + q * (bw + gap)
                ctx.globalAlpha = a0 * (q <= dyn ? 0.85 : 0.25); if (q <= dyn) ctx.fillRect(bx, by + 0.13 * s - h, bw, h); else ctx.strokeRect(bx, by + 0.13 * s - h, bw, h) }
              x0 += 6 * (bw + gap) + 0.15 * s
            }
            const x1 = c1.x + c1.width, xm = Math.max(x0, x1 - Math.min(1.8 * s, (x1 - x0) / 2))
            if (ph.hairpin && x1 - xm > 0.6 * s) { const o = 0.15 * s, cr = ph.hairpin === 'cresc', ax = cr ? xm : x1, bx = cr ? x1 : xm
              ctx.strokeStyle = INK; ctx.lineWidth = Math.max(0.8, s * 0.02); ctx.globalAlpha = a0 * 0.6; ctx.lineCap = 'round'; ctx.beginPath(); ctx.moveTo(bx, by - o); ctx.lineTo(ax, by); ctx.lineTo(bx, by + o); ctx.stroke() }
            ctx.restore()
          }
          r0 = r1 + 1
        }
      }
      // labels: liaison sounds first, then tones, then intervals; a crowded one steps down once or yields
      labels.sort((a, b) => a.prio - b.prio || a.x - b.x)
      const placed = []
      ctx.textAlign = 'center'; ctx.textBaseline = 'alphabetic'; ctx.fillStyle = GREY
      for (const l of labels) {
        const fs = Math.max(8, Math.round(s * l.size)); ctx.font = `${fs}px "Times New Roman", Times, serif`
        const hw = ctx.measureText(l.text).width / 2 + 2
        let y = l.y
        const hit = yy => placed.some(q => Math.abs(q.x - l.x) < q.hw + hw && Math.abs(q.y - yy) < fs)
        if (hit(y)) { y += fs * 1.05; if (hit(y) || y > l.floor) continue }
        placed.push({ x: l.x, y, hw }); ctx.globalAlpha = l.a; ctx.fillStyle = l.color || GREY; ctx.font = `${l.color ? 'italic ' : ''}${fs}px "Times New Roman", Times, serif`; ctx.fillText(l.text.replace(/[\[\]]/g, l.color ? '' : '$&'), l.x, y)
      }
      // text on top: plain's dim-ahead / white-after, the sung word wiped pale up to the light.
      // A host that already draws the words itself (Gallery's DOM spans, Recense's native Ink) passes
      // `glyphs: false` and keeps only the figure, so the two never double up.
      ctx.globalAlpha = a0; ctx.font = ln.font; ctx.textBaseline = 'alphabetic'; ctx.textAlign = 'left'
      for (const c of (f.glyphs === false ? [] : cells)) {
        const w = c.w
        if (t >= w.e) { const k = cl((t - w.e) / 0.2); ctx.fillStyle = `rgb(255,${Math.round(lerp(243, 255, k))},${Math.round(lerp(194, 255, k))})`; ctx.fillText(w.text, c.x, c.y); continue }
        if (t < w.s) { ctx.fillStyle = `rgba(255,255,255,${lerp(0.42, 0.6, cl(1 - (w.s - t) / 0.2)).toFixed(3)})`; ctx.fillText(w.text, c.x, c.y); continue }
        const edge = c.x + c.width * f.progress(w, t)
        ctx.save(); ctx.beginPath(); ctx.rect(edge, c.top - 20, c.width + 40, ln.lineHeight + 40); ctx.clip()
        ctx.fillStyle = C.ahead; ctx.fillText(w.text, c.x, c.y); ctx.restore()
        ctx.save(); ctx.beginPath(); ctx.rect(c.x - 20, c.top - 20, edge - c.x + 20, ln.lineHeight + 40); ctx.clip()
        ctx.fillStyle = C.pale; ctx.fillText(w.text, c.x, c.y); ctx.restore()
      }
      ctx.restore()
    }
  },
}

globalThis.Prosogram = {
  plugin,
  /** Register with a host. `host.start(plugin)` is the harness/player hook that drives draw(). */
  mount(host) { host.start(plugin) },
}
