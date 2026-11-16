// Derived from Spec: UI-12 (offline editor link, S1). In a browser there is no native host to keep the
// text, so this stands in for it: the editor posts its text and ink to `webkit.messageHandlers.{editor,ink}`
// exactly as it does for the apps; here those posts land in IndexedDB on this device. Nothing leaves the device.
// Does nothing inside the apps (a real handler already exists).
import { installHubSync } from './hubsync.js';

const DB = 'recense-draftpad';
const STORE = 'kv';

export function openDb(idb) {
  return new Promise((resolve, reject) => {
    const r = idb.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE);
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}
const tx = (db, mode, fn) => new Promise((resolve, reject) => {
  const t = db.transaction(STORE, mode);
  const out = fn(t.objectStore(STORE));
  t.oncomplete = () => resolve(out && 'result' in out ? out.result : undefined);
  t.onerror = () => reject(t.error);
});

export function installWebStore(win, idb = win.indexedDB) {
  if (!win || win.webkit?.messageHandlers?.editor) return null;
  if (!idb) return null;
  const dbp = openDb(idb).catch(() => null);
  const put = (key, value) => dbp.then(db => db && tx(db, 'readwrite', s => s.put(value, key))).catch(() => {});
  const get = key => dbp.then(db => db && tx(db, 'readonly', s => s.get(key))).catch(() => undefined);

  win.webkit = win.webkit || {};
  win.webkit.messageHandlers = win.webkit.messageHandlers || {};
  // At https://recense.local the hub keeps the note in step between devices (FEAT-18); anywhere else this is null.
  const hub = installHubSync(win, { put, get });
  win.webkit.messageHandlers.editor = { postMessage: text => put('text', String(text)).then(() => hub?.changed()) };
  win.webkit.messageHandlers.ink = { postMessage: json => put('ink', typeof json === 'string' ? json : JSON.stringify(json)) };

  // Ask the browser not to evict this device's copy (Safari may after ~7 days unused unless added to the Home Screen).
  try { win.navigator?.storage?.persist?.(); } catch { /* a nicety */ }

  // Put the saved text and ink back once the editor has mounted.
  let tries = 0;
  const restore = async () => {
    const api = win.recenseEditor;
    if (!api) { if (tries++ < 100) win.setTimeout(restore, 50); return; }
    const [text, ink] = [await get('text'), await get('ink')];
    if (typeof text === 'string') api.setText(text);
    if (typeof ink === 'string') api.setInk(ink);
    hub?.wake();
  };
  win.addEventListener('load', restore);
  return { put, get };
}

if (typeof window !== 'undefined') installWebStore(window);
