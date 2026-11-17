// Derived from Spec: FEAT-19 (P4) · in a browser, "Play a file…" plays a sound or video file from this device in a
// real <audio>/<video> that keeps playing on the Lock Screen. Offline: the file never leaves the device (an object
// URL), no server, no Cloudflare. In the app the native audio bridge already owns the Lock Screen, so the item hides.
import '../../library/src/client/mediasession.js';

export const PLAYABLE = 'audio/*,video/*,.mp3,.m4a,.aac,.wav,.flac,.ogg,.opus,.mp4,.m4v,.mov,.webm';
const VIDEO_EXT = /\.(mp4|m4v|mov|webm)$/i;

/** True in a browser; false in the app, whose native audio bridge already owns the Lock Screen. */
export function canPlayFiles(win = globalThis) {
  return !win?.webkit?.messageHandlers?.audio;
}

/** 'video' for a video file (by type, else by extension), 'audio' for anything else. */
export function kindOf(file) {
  const type = String(file?.type || '');
  if (type.startsWith('video/')) return 'video';
  if (type.startsWith('audio/')) return 'audio';
  return VIDEO_EXT.test(String(file?.name || '')) ? 'video' : 'audio';
}

export function createFilePlayer({ doc = document, urls = URL, nowPlaying = globalThis.RecenseNowPlaying } = {}) {
  const panel = doc.createElement('div');
  panel.className = 'rc-fileplayer';
  panel.setAttribute('aria-label', 'Playing a file');
  panel.hidden = true;

  const title = doc.createElement('span');
  title.className = 'rc-fileplayer-title';
  const closeBtn = doc.createElement('button');
  closeBtn.type = 'button';
  closeBtn.className = 'rc-btn rc-fileplayer-close';
  closeBtn.textContent = 'Close player';
  const bar = doc.createElement('div');
  bar.className = 'rc-fileplayer-bar';
  bar.append(title, closeBtn);
  panel.append(bar);

  let el = null;
  let url = null;
  let unbind = null;

  function stop() {
    if (unbind) unbind();
    unbind = null;
    if (el) {
      el.pause();
      el.removeAttribute('src');
      el.remove();
    }
    el = null;
    if (url) urls.revokeObjectURL(url);
    url = null;
    panel.hidden = true;
  }

  function play(file) {
    if (!file) return null;
    stop();
    el = doc.createElement(kindOf(file));
    el.controls = true;
    el.setAttribute('playsinline', '');
    el.preload = 'metadata';
    url = urls.createObjectURL(file);
    el.src = url;
    title.textContent = String(file.name || '');
    if (nowPlaying) unbind = nowPlaying.bind(el, { title: file.name });
    panel.append(el);
    panel.hidden = false;
    const p = el.play();
    if (p && p.catch) p.catch(() => {});
    return el;
  }

  /** Opens the system file picker; the chosen file plays. */
  function pick() {
    const input = doc.createElement('input');
    input.type = 'file';
    input.accept = PLAYABLE;
    input.addEventListener('change', () => play(input.files && input.files[0]));
    input.click();
  }

  closeBtn.addEventListener('click', stop);

  return { panel, play, pick, stop, get element() { return el; } };
}
