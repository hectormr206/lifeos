// Minimal service worker — installs to enable "Add to home screen" + Web Push.
// No offline caching: the dashboard is local-network-only and needs the
// FastAPI backend for everything useful, so an offline cache would lie.
self.addEventListener('install', (e) => { self.skipWaiting(); });
self.addEventListener('activate', (e) => { e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', () => { /* network-only */ });

// LifeOS push handler. Payload shape (from lifeos.push):
//   {"title": "...", "body": "...", "url": "/path", "tag": "reminder:<ulid>"}
self.addEventListener('push', (event) => {
  let payload = { title: 'Axi', body: '', url: '/' };
  try {
    if (event.data) payload = Object.assign(payload, event.data.json());
  } catch (e) { /* fall through with defaults */ }
  const opts = {
    body: payload.body || '',
    icon: '/static/axi-192.png',
    badge: '/static/axi-192.png',
    tag: payload.tag || 'lifeos',
    renotify: true,
    data: { url: payload.url || '/' },
  };
  event.waitUntil(self.registration.showNotification(payload.title || 'Axi', opts));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || '/';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((wins) => {
      for (const w of wins) {
        if (w.url.endsWith(target) || w.url.indexOf(target) !== -1) {
          return w.focus();
        }
      }
      return self.clients.openWindow(target);
    })
  );
});
