// Service worker — Web Push + Badging + Background Sync + offline shell cache.
//
// Strategy:
//   - INSTALL: precache the dashboard shell + key static assets so the page
//     can load when the laptop is unreachable (no VPN / offline).
//   - FETCH:
//       * navigation requests (HTML) → network-first, fall back to cached
//         shell so the app at least RENDERS offline.
//       * static assets → cache-first (long-lived).
//       * API GETs → network-only (data must be fresh).
//       * /api/chat/ask POST when offline → handled by the page, not here.
//   - SYNC: when the Pixel reconnects, the browser fires `sync` events; we
//     drain the IndexedDB chat queue.
//   - PUSH / NOTIFICATIONCLICK: kept from previous version.
//
// Background Sync API caveats (Chrome/Edge/Samsung Internet only):
//   - Not supported in Firefox/Safari.
//   - The OS decides WHEN to fire — typically within minutes of reconnecting.
//   - Each sync event has ~12s CPU budget; large queues may need multiple fires.

const CACHE_VERSION = 'axi-shell-v3';
const SHELL_URLS = [
  '/',
  '/chat',
  '/reminders',
  '/health',
  '/finance',
  '/relationships',
  '/exercise',
  '/spirituality',
  '/learning',
  '/calendar',
  '/insights',
  '/posture',
  '/share-receive',
  '/manifest.webmanifest',
  '/static/axi-192.png',
  '/static/axi-512.png',
  '/static/axi-512-maskable.png',
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE_VERSION)
      .then((cache) => cache.addAll(SHELL_URLS).catch(() => {
        // Some URLs may fail (server briefly unavailable at install); they'll
        // be cached on first successful navigation instead.
      }))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((k) => k !== CACHE_VERSION && k.startsWith('axi-shell-'))
            .map((k) => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // Only handle same-origin GETs. Cross-origin assets (Tailwind CDN, Alpine)
  // go straight to network.
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;

  // Navigation requests (HTML pages): network-first, cached shell on failure.
  if (req.mode === 'navigate' || (req.headers.get('accept') || '').includes('text/html')) {
    event.respondWith(networkFirst(req));
    return;
  }

  // Static assets under /static/ or manifest: cache-first (long-lived).
  if (url.pathname.startsWith('/static/') || url.pathname === '/manifest.webmanifest') {
    event.respondWith(cacheFirst(req));
    return;
  }

  // API GETs (no special handling — page itself decides how to degrade).
});

async function networkFirst(req) {
  try {
    const fresh = await fetch(req);
    if (fresh.ok) {
      const cache = await caches.open(CACHE_VERSION);
      cache.put(req, fresh.clone()).catch(() => {});
    }
    return fresh;
  } catch (e) {
    const cached = await caches.match(req);
    if (cached) return cached;
    const home = await caches.match('/');
    if (home) return home;
    return new Response(
      '<!DOCTYPE html><meta charset="utf-8"><meta name="viewport" content="width=device-width">' +
      '<style>body{font-family:system-ui;padding:2rem;text-align:center;color:#888}' +
      'h1{color:#cc66ff}</style>' +
      '<h1>📡 Sin conexión</h1>' +
      '<p>Axi no puede comunicarse con la laptop ahora mismo.</p>' +
      '<p>Verificá la VPN o reintenta cuando estés en casa.</p>',
      { headers: { 'Content-Type': 'text/html; charset=utf-8' } }
    );
  }
}

async function cacheFirst(req) {
  const cached = await caches.match(req);
  if (cached) return cached;
  try {
    const fresh = await fetch(req);
    if (fresh.ok) {
      const cache = await caches.open(CACHE_VERSION);
      cache.put(req, fresh.clone()).catch(() => {});
    }
    return fresh;
  } catch (e) {
    return new Response('', { status: 504 });
  }
}

// ─── Background Sync: chat queue drain ───────────────────────────────
//
// The foreground page, when its /api/chat/ask POST fails (offline / no VPN),
// writes the message to IndexedDB `axi-offline/chat_queue` and registers a
// sync event with tag 'chat-queue'. The browser fires the event here when
// network becomes available again.

const IDB_NAME = 'axi-offline';
const IDB_VERSION = 1;
const QUEUE_STORE = 'chat_queue';

function openIdb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(IDB_NAME, IDB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(QUEUE_STORE)) {
        db.createObjectStore(QUEUE_STORE, { keyPath: 'id' });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function idbAll(storeName) {
  const db = await openIdb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction([storeName], 'readonly');
    const req = tx.objectStore(storeName).getAll();
    req.onsuccess = () => resolve(req.result || []);
    req.onerror = () => reject(req.error);
  });
}

async function idbDelete(storeName, key) {
  const db = await openIdb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction([storeName], 'readwrite');
    tx.objectStore(storeName).delete(key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function notifyClients(message) {
  const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  wins.forEach((w) => w.postMessage(message));
}

async function drainChatQueue() {
  const items = (await idbAll(QUEUE_STORE)).filter((i) => i.status === 'queued');
  for (const item of items) {
    try {
      const r = await fetch('/api/chat/ask', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          text: item.text,
          image_b64: item.image_b64 || null,
          speak: false,
          location: item.location || undefined,
        }),
      });
      if (!r.ok) {
        // Server reachable but rejected — drop from queue so it doesn't
        // retry forever, notify foreground for surfaced error.
        await idbDelete(QUEUE_STORE, item.id);
        await notifyClients({ type: 'sync-error', tempId: item.id, error: `HTTP ${r.status}` });
        continue;
      }
      const data = await r.json();
      await idbDelete(QUEUE_STORE, item.id);
      await notifyClients({
        type: 'sync-sent', tempId: item.id,
        answer: data.answer, latency_ms: data.latency_ms,
      });
    } catch (e) {
      await notifyClients({ type: 'sync-retry', tempId: item.id });
      throw e;  // signal to browser that sync didn't complete
    }
  }
  // Refresh badge after successful drain.
  try { await refreshBadge(); } catch (e) { /* offline */ }
}

self.addEventListener('sync', (event) => {
  if (event.tag === 'chat-queue') {
    event.waitUntil(drainChatQueue());
  }
});

self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'refresh-badge') {
    event.waitUntil(refreshBadge());
  }
  if (event.data && event.data.type === 'drain-chat-queue') {
    // Manual trigger from the foreground (e.g. on 'online' event) — useful
    // for browsers where the OS-fired sync is slow to arrive.
    event.waitUntil(drainChatQueue().catch(() => {/* still offline */}));
  }
});

// ─── Web Push (unchanged) ─────────────────────────────────────────────

self.addEventListener('push', (event) => {
  let payload = { title: 'Axi', body: '', url: '/' };
  try {
    if (event.data) payload = Object.assign(payload, event.data.json());
  } catch (e) { /* fall through */ }

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
    data: { url: payload.url || '/', entryId, extra: payload.data || {} },
  };
  event.waitUntil(self.registration.showNotification(payload.title || 'Axi', opts));
});

self.addEventListener('notificationclick', (event) => {
  const action = event.action;
  const data = event.notification.data || {};
  event.notification.close();

  if (action === 'reflect-planned' || action === 'reflect-impulsive') {
    const tag = action === 'reflect-planned' ? 'planned' : 'impulsive';
    const entryId = data.entryId;
    if (entryId) {
      event.waitUntil(
        fetch('/api/finance/entries/' + entryId + '/reflect', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ tag }),
        }).then(() => refreshBadge())
          .catch(() => {})
      );
      return;
    }
  }

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

async function refreshBadge() {
  try {
    const r = await fetch('/api/badge/count');
    if (!r.ok) return;
    const { count } = await r.json();
    if (count > 0) await self.navigator.setAppBadge(count);
    else await self.navigator.clearAppBadge();
  } catch (e) { /* not supported / offline */ }
}
