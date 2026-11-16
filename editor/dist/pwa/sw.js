// Derived from Spec: UI-12 (S1). Cache the editor page once; open it from the cache from then on, with no network.
// Opens at once from the cache, then quietly refreshes it when online. A sign-in redirect (Access) or an error is never cached.
const CACHE = 'recense-editor-36a631d09b';
const SHELL = ['./', 'manifest.webmanifest', 'icon.svg'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(ks => Promise.all(ks.filter(k => k.startsWith('recense-editor-') && k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin || !url.pathname.startsWith(new URL('./', location.href).pathname)) return;
  e.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const hit = await cache.match(req, { ignoreSearch: true });
    const fresh = fetch(req).then(res => {
      if (res.ok && res.type === 'basic') cache.put(req, res.clone());
      return res;
    });
    if (hit) { fresh.catch(() => {}); return hit; }
    try { return await fresh; } catch { return (await cache.match('./')) || Response.error(); }
  })());
});
