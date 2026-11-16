// Derived from Spec: UI-12 P6 (FEAT-19 S-editor P4). The editor's player: one interface, two backends.
//   host: a native host is present (webkit.messageHandlers.audio): every call is a post to it, as before. Host wins.
//   web:  no host (a browser): the calls drive Gallery's player rules (library/src/client/webplayer.js, bundled here),
//         so Media Session, the Lock Screen scrubber and background play come with it. No second player.
// Offline: a recording plays with no network only if this device holds it (availability below); otherwise one plain line.
import '../../library/src/client/webplayer.js';

export const OFFLINE_LINE = "This recording isn't on this device. It needs a connection.";
export const LOAD_LINE = "This recording couldn't be opened.";

export function hasNativeAudioHost(globalObj) {
  return Boolean(globalObj?.webkit?.messageHandlers?.audio?.postMessage);
}

// Where a recording would come from: 'device' (blob:/data:/file:, or the local hub's own origin), 'cached'
// (in Cache Storage), 'network' (needs a connection, and there is one) or 'unavailable' (needs one, there is none).
export async function mediaAvailability(src, { globalObj = typeof window !== 'undefined' ? window : null } = {}) {
  const s = String(src || '');
  if (!s) return 'unavailable';
  if (/^(blob|data|file):/i.test(s)) return 'device';
  let url = null;
  try { url = new URL(s, globalObj?.location?.href); } catch { return 'unavailable'; }
  if (/^(blob|data|file):$/.test(url.protocol)) return 'device';
  const here = globalObj?.location;
  if (here && url.origin === here.origin && isLocalHost(url.hostname)) return 'device';
  try {
    if (globalObj?.caches?.match && (await globalObj.caches.match(url.href))) return 'cached';
  } catch { /* no cache here */ }
  const online = globalObj?.navigator ? globalObj.navigator.onLine !== false : true;
  return online ? 'network' : 'unavailable';
}

export function isLocalHost(h) {
  const n = String(h || '').toLowerCase();
  return n === 'localhost' || n === '[::1]' || n === '::1' || /^127\./.test(n) || n.endsWith('.local');
}

/**
 * The adapter. Same calls whichever backend serves them.
 * options: globalObj, doc, onTime(sec), onState({playing}), onStatus(line|''), makeWebPlayer (tests).
 */
export function createPlayer(options = {}) {
  const globalObj = options.globalObj ?? (typeof window !== 'undefined' ? window : null);
  const onTime = options.onTime ?? (() => {});
  const onState = options.onState ?? (() => {});
  const onStatus = options.onStatus ?? (() => {});
  const host = hasNativeAudioHost(globalObj);
  let web = null;
  let src = '';
  let rate = 1;
  let loop = [0, 0];
  let blocked = false;

  const post = msg => globalObj.webkit.messageHandlers.audio.postMessage(msg);

  function webPlayer() {
    if (web) return web;
    const make = options.makeWebPlayer ?? (o => globalThis.RecenseWebPlayer.create(o));
    web = make({ doc: options.doc ?? globalObj?.document, nav: globalObj?.navigator });
    web.on('time', t => onTime(t));
    web.on('state', s => onState({ playing: s === 'playing' }));
    web.on('error', e => {
      if (e === 'AbortError') return;
      const offline = globalObj?.navigator?.onLine === false;
      onStatus(offline ? OFFLINE_LINE : LOAD_LINE);
    });
    return web;
  }

  const api = {
    get backend() { return host ? 'host' : 'web'; },
    get element() { return web ? web.el : null; },
    async load(source, title = '', artwork = '') {
      src = String(source || '');
      if (host) { post({ action: 'load', src, title: String(title || '') }); return 'host'; }
      const where = await mediaAvailability(src, { globalObj });
      blocked = where === 'unavailable';
      onStatus(blocked ? OFFLINE_LINE : '');
      if (blocked) return where;
      webPlayer().load(src, { title, artwork });
      web.setRate(rate);
      return where;
    },
    async play() {
      if (host) { post({ action: 'play' }); return true; }
      if (!web || !src) return false;
      if (blocked || (await mediaAvailability(src, { globalObj })) === 'unavailable') {
        blocked = true;
        onStatus(OFFLINE_LINE);
        return false;
      }
      await web.play();
      return !web.el.paused;
    },
    pause() {
      if (host) return post({ action: 'pause' });
      if (web) web.pause();
    },
    toggle() {
      if (host) return post({ action: 'toggle' });
      if (web && !web.el.paused) return web.pause();
      return api.play();
    },
    seek(time) {
      const t = Math.max(0, Number(time) || 0);
      if (host) return post({ action: 'seek', time });
      if (web) web.seek(t);
    },
    setRate(r) {
      rate = Number(r) || 1;
      if (host) return post({ action: 'rate', rate });
      if (web) web.setRate(rate);
    },
    setLoop(a, b) {
      loop = [Math.max(0, Number(a) || 0), Math.max(0, Number(b) || 0)];
      if (host) return post({ action: 'loop', start: loop[0], end: loop[1] });
      if (web) web.setLoop(loop[0], loop[1]);
    },
    state() {
      if (web) return { backend: 'web', ...web.state() };
      return { backend: host ? 'host' : 'web', src, playing: false, currentTime: 0, duration: 0, rate, loopA: loop[1] > loop[0] ? loop[0] : null, loopB: loop[1] > loop[0] ? loop[1] : null };
    },
    close() {
      if (host) return post({ action: 'close' });
      if (web) web.close();
      src = '';
      onStatus('');
    }
  };
  return api;
}

const RATES = [1, 1.25, 1.5, 2, 0.75];

/**
 * The browser's own transport, shown only with the web backend (a host draws its own controls).
 * Play/pause, the time, a scrubber, speed, a file picker, and the status line (never a spinner).
 */
export function createTransport(doc, player, { onPick } = {}) {
  const mk = (tag, cls, text) => { const e = doc.createElement(tag); if (cls) e.className = cls; if (text) e.textContent = text; return e; };
  const bar = mk('div', 'rc-player');
  const playBtn = mk('button', 'rc-player-play', 'Play');
  playBtn.type = 'button';
  const time = mk('span', 'rc-player-time', '0:00');
  const scrub = mk('input', 'rc-player-scrub');
  scrub.type = 'range'; scrub.min = '0'; scrub.max = '0'; scrub.step = '0.1'; scrub.value = '0';
  scrub.setAttribute('aria-label', 'Position');
  const speed = mk('button', 'rc-player-speed', '1×');
  speed.type = 'button';
  const pick = mk('label', 'rc-player-pick', 'Choose a recording…');
  const file = mk('input');
  file.type = 'file'; file.accept = 'audio/*,video/*'; file.hidden = true;
  pick.appendChild(file);
  const status = mk('p', 'rc-player-status');
  status.setAttribute('role', 'status');
  status.hidden = true;
  bar.append(playBtn, time, scrub, speed, pick, status);

  const fmt = s => { s = Math.max(0, Math.floor(s || 0)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };
  let ri = 0;
  playBtn.addEventListener('click', () => player.toggle());
  speed.addEventListener('click', () => { ri = (ri + 1) % RATES.length; player.setRate(RATES[ri]); speed.textContent = `${RATES[ri]}×`; });
  scrub.addEventListener('input', () => player.seek(Number(scrub.value)));
  file.addEventListener('change', () => {
    const f = file.files && file.files[0];
    if (!f) return;
    const url = (doc.defaultView || globalThis).URL.createObjectURL(f);
    if (onPick) onPick(url, f.name.replace(/\.[^/.]+$/, ''));
  });

  return {
    el: bar,
    setStatus(line) { status.textContent = line || ''; status.hidden = !line; },
    setPlaying(on) { playBtn.textContent = on ? 'Pause' : 'Play'; },
    setTime(t) {
      const st = player.state();
      if (st.duration) scrub.max = String(st.duration);
      scrub.value = String(t || 0);
      time.textContent = fmt(t);
    }
  };
}
