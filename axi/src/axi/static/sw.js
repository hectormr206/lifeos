// Minimal service worker — just installs so Chrome shows "Install app".
// No offline caching: the dashboard is local-network-only and needs the
// FastAPI backend for everything useful, so an offline cache would lie.
self.addEventListener('install', (e) => { self.skipWaiting(); });
self.addEventListener('activate', (e) => { e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', () => { /* network-only */ });
