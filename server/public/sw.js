const CACHE_NAME = 'child-cam-v1';
const PRECACHE = ['./child.html','./manifest.json','./icons/icon-192.png','./icons/icon-512.png'];
self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(PRECACHE)).catch(() => {}));
  self.skipWaiting();
});
self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys().then((names) => Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n)))));
  self.clients.claim();
});
self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.pathname.startsWith('/pairing') || url.pathname.startsWith('/signal')) return;
  event.respondWith(fetch(req).then((res) => {
    if (res.ok && url.origin === location.origin) {
      const clone = res.clone();
      caches.open(CACHE_NAME).then((c) => c.put(req, clone)).catch(() => {});
    }
    return res;
  }).catch(() => caches.match(req)));
});
