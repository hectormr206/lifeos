// Minimal service worker — installs to enable "Add to home screen" + Web Push.
// No offline caching: the dashboard is local-network-only and needs the
// FastAPI backend for everything useful, so an offline cache would lie.
self.addEventListener('install', (e) => { self.skipWaiting(); });
self.addEventListener('activate', (e) => { e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', () => { /* network-only */ });

// LifeOS push handler. Payload shape (from lifeos.push):
//   {"title": "...", "body": "...", "url": "/path", "tag": "reminder:<ulid>",
//    "actions": [{"action":"...","title":"..."}], "data": {...}}
self.addEventListener('push', (event) => {
  let payload = { title: 'Axi', body: '', url: '/' };
  try {
    if (event.data) payload = Object.assign(payload, event.data.json());
  } catch (e) { /* fall through with defaults */ }

  // Detect tags that get inline action buttons. Finance reflection nudges
  // ('finance-reflect:<entry_id>') get two action buttons so the user can
  // classify from the notification shade without opening the app.
  const isReflection = (payload.tag || '').startsWith('finance-reflect:');
  const entryId = isReflection ? payload.tag.split(':', 2)[1] : null;

  const actions = isReflection
    ? [
        { action: 'reflect-planned', title: '✓ Planeada' },
        { action: 'reflect-impulsive', title: '⚠ Impulsiva' },
      ]
    : [];

  const opts = {
    body: payload.body || '',
    icon: '/static/axi-192.png',
    badge: '/static/axi-192.png',
    tag: payload.tag || 'lifeos',
    renotify: true,
    actions,
    data: {
      url: payload.url || '/',
      entryId,
      extra: payload.data || {},
    },
  };
  event.waitUntil(self.registration.showNotification(payload.title || 'Axi', opts));
});

self.addEventListener('notificationclick', (event) => {
  const action = event.action; // 'reflect-planned' | 'reflect-impulsive' | '' (tap)
  const data = event.notification.data || {};
  event.notification.close();

  // Inline action buttons — call the API directly without opening the app.
  if (action === 'reflect-planned' || action === 'reflect-impulsive') {
    const tag = action === 'reflect-planned' ? 'planned' : 'impulsive';
    const entryId = data.entryId;
    if (entryId) {
      event.waitUntil(
        fetch('/api/finance/entries/' + entryId + '/reflect', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ tag }),
        }).then(() => {
          // Best-effort badge refresh after classifying
          if ('setAppBadge' in self.navigator) {
            return refreshBadge();
          }
        }).catch(() => {/* offline — silently fail; next foreground refresh fixes it */})
      );
      return;
    }
  }

  // Default tap: focus or open the URL the notification points to.
  const target = data.url || '/';
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

// Badging API — show a count on the installed PWA's icon (Android only as
// of 2026). Number reflects pending reflections + unread system events.
async function refreshBadge() {
  try {
    const r = await fetch('/api/badge/count');
    if (!r.ok) return;
    const { count } = await r.json();
    if (count > 0) {
      await self.navigator.setAppBadge(count);
    } else {
      await self.navigator.clearAppBadge();
    }
  } catch (e) {
    // setAppBadge not supported → silently skip
  }
}

// Periodically refresh badge when SW wakes for a push. Best-effort.
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'refresh-badge') {
    event.waitUntil(refreshBadge());
  }
});
