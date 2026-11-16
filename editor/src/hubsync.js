// Derived from Spec: FEAT-18 (H1c). When Draftpad is opened from a Recense hub (https://recense.local), keep the note in
// step with the hub: send what was typed, take what changed elsewhere. Writing never waits for this; the text is saved
// on this device first (webstore.js) and the hub catches up later, on a timer, when the device comes back online, and when
// the tab becomes visible. With no hub, no token, or a failed request, nothing changes for the writer.
//
// Facts it relies on (hub/Sources/recense-hub/HubNote.swift): POST /api/note {base, mine} with `Authorization: Bearer`.
// `base` is the text this browser last agreed on with the hub (null the first time, so a scrap never replaces the note).
// The reply's `text` is what to show; `base` is what to send next time.

export const SYNC_DELAY_MS = 1500;
export const POLL_MS = 20000;

export function isHubHost(hostname) {
  return typeof hostname === 'string' && (hostname === 'recense.local' || hostname.endsWith('.recense.local'));
}

/** `#pair=<token>` in the address, or null. */
export function tokenFromHash(hash) {
  const m = /(?:^#|&)pair=([A-Za-z0-9_-]{16,128})/.exec(hash || '');
  return m ? m[1] : null;
}

export function createHubSync({ store, fetchFn, getApi, setTimer, clearTimer, now = Date.now, visible = () => true }) {
  let timer = null, poll = null, busy = false, again = false, dirty = false;

  async function run() {
    if (busy) { again = true; return; }
    const token = await store.get('hubToken');
    if (typeof token !== 'string' || !token) return;
    busy = true;
    try {
      const raw = await store.get('text');
      const mine = typeof raw === 'string' ? raw : '';
      const known = await store.get('hubBase');
      // A page with no text yet, or an empty editor that has not loaded yet, must never be read as "delete the note":
      // it goes as a first contact (base null), where the hub keeps the note and only joins what was typed.
      const base = typeof known === 'string' && known !== '' && mine !== '' ? known : null;
      let res;
      try {
        res = await fetchFn('/api/note', {
          method: 'POST',
          headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
          body: JSON.stringify({ base, mine })
        });
      } catch { dirty = true; return; }
      if (res.status === 401) { await store.put('hubToken', ''); return; }
      if (res.status !== 200) { dirty = true; return; }
      const reply = await res.json();
      dirty = false;
      if (typeof reply.base === 'string') await store.put('hubBase', reply.base);
      if (typeof reply.text === 'string' && reply.text !== mine) {
        // Something arrived (the Mac's edit, a recovered note, a conflict kept as mine): show it and keep it here too.
        const typedSince = await store.get('text');
        if (typedSince === raw) {
          await store.put('text', reply.text);
          const api = getApi();
          if (api && typeof api.setText === 'function') api.setText(reply.text);
        } else dirty = true; // more was typed while the request was out: send that next, from the new base
      }
    } finally {
      busy = false;
      if (again) { again = false; schedule(0); }
    }
  }

  function schedule(ms = SYNC_DELAY_MS) {
    if (timer !== null) clearTimer(timer);
    timer = setTimer(() => { timer = null; run(); }, ms);
  }

  return {
    /** The editor saved new text. */
    changed() { dirty = true; schedule(); },
    /** Back online or the tab came back: catch up now. */
    wake() { if (visible()) schedule(0); },
    /** Look for changes made elsewhere every POLL_MS while the tab is visible. */
    startPolling() {
      if (poll !== null) return;
      const tick = () => { if (visible()) run(); poll = setTimer(tick, POLL_MS); };
      poll = setTimer(tick, POLL_MS);
    },
    isDirty: () => dirty,
    run
  };
}

/** Wire it into the page. Does nothing off a hub host, so the Cloudflare copy and file:// are untouched. */
export function installHubSync(win, store) {
  try {
    if (!win || !store || !isHubHost(win.location?.hostname)) return null;
    const sync = createHubSync({
      store,
      fetchFn: (url, init) => win.fetch(url, init),
      getApi: () => win.recenseEditor,
      setTimer: (fn, ms) => win.setTimeout(fn, ms),
      clearTimer: id => win.clearTimeout(id),
      visible: () => win.document?.visibilityState !== 'hidden'
    });
    const token = tokenFromHash(win.location.hash);
    if (token) {
      store.put('hubToken', token).then(() => {
        try { win.history.replaceState(null, '', win.location.pathname + win.location.search); } catch { /* cosmetic */ }
        sync.wake();
      });
    }
    win.addEventListener('online', () => sync.wake());
    win.document?.addEventListener('visibilitychange', () => sync.wake());
    win.addEventListener('load', () => { sync.startPolling(); sync.wake(); });
    return sync;
  } catch { return null; }
}
