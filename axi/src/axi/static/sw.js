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

const CACHE_VERSION = 'axi-shell-v13';
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
  '/setup',
  '/share-receive',
  '/brain3d',
  '/manifest.webmanifest',
  '/static/axi-192.png',
  '/static/axi-512.png',
  '/static/axi-512-maskable.png',
  '/static/vendor/tailwind.js',
  '/static/vendor/marked.min.js',
  '/static/vendor/alpine.min.js',
  '/static/vendor/cytoscape.min.js',
  '/static/vendor/3d-force-graph.min.js',
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

  // Navigation requests (HTML pages): NETWORK-FIRST with a short timeout.
  // Always serve FRESH HTML when the laptop is reachable (localhost = instant),
  // so the user NEVER sees a stale page. Falls back to cache only if the
  // network is slow/down (flaky VPN from the phone), so it never hangs.
  if (req.mode === 'navigate' || (req.headers.get('accept') || '').includes('text/html')) {
    event.respondWith(networkFirstWithTimeout(req, 3000));
    return;
  }

  // Static assets under /static/ or manifest: cache-first (long-lived).
  if (url.pathname.startsWith('/static/') || url.pathname === '/manifest.webmanifest') {
    event.respondWith(cacheFirst(req));
    return;
  }

  // API GETs (no special handling — page itself decides how to degrade).
});

// network-first with a short timeout for navigations: fresh when reachable,
// cache fallback only when the network is slow/down (so it never hangs).
async function networkFirstWithTimeout(req, timeoutMs) {
  const cache = await caches.open(CACHE_VERSION);
  try {
    const fresh = await Promise.race([
      fetch(req),
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), timeoutMs)),
    ]);
    if (fresh) {
      if (fresh.ok) cache.put(req, fresh.clone()).catch(() => {});
      return fresh;
    }
  } catch (e) { /* network slow/down → fall back to cache below */ }
  const cached = await cache.match(req);
  if (cached) return cached;
  const home = await cache.match('/');
  if (home) return home;
  return new Response(
    '<!DOCTYPE html><meta charset="utf-8"><meta name="viewport" content="width=device-width">' +
    '<style>body{font-family:system-ui;padding:2rem;text-align:center;color:#888}h1{color:#FF6B9D}</style>' +
    '<h1>📡 Sin conexión</h1><p>Axi no puede comunicarse con la laptop ahora mismo.</p>',
    { headers: { 'Content-Type': 'text/html; charset=utf-8' }, status: 503 }
  );
}

// stale-while-revalidate: return cached IMMEDIATELY if we have it. Fire
// a fresh fetch in background to update the cache for next visit. If no
// cached version exists yet (first visit ever), wait for the fresh fetch.
// This is what makes the app load fast even on broken VPN — we don't
// wait for a TCP timeout.
async function staleWhileRevalidate(req) {
  const cache = await caches.open(CACHE_VERSION);
  const cached = await cache.match(req);
  const fetchAndUpdate = fetch(req).then((fresh) => {
    if (fresh && fresh.ok) {
      cache.put(req, fresh.clone()).catch(() => {});
    }
    return fresh;
  }).catch(() => null);

  if (cached) {
    // Don't wait for the network — page renders instantly. The fetch
    // continues in the background and updates the cache so the user
    // gets the latest version on the NEXT visit. waitUntil() is not
    // available on a `fetch` event from inside `respondWith`, but the
    // pending promise stays alive in browser context.
    fetchAndUpdate.catch(() => {});  // suppress unhandled-rejection warnings
    return cached;
  }
  // First visit (no cache yet): wait for network. If that fails, fall
  // back to the homepage shell so SOMETHING renders.
  const fresh = await fetchAndUpdate;
  if (fresh) return fresh;
  const home = await cache.match('/');
  if (home) return home;
  return new Response(
    '<!DOCTYPE html><meta charset="utf-8"><meta name="viewport" content="width=device-width">' +
    '<style>body{font-family:system-ui;padding:2rem;text-align:center;color:#888}' +
    'h1{color:#FF6B9D}</style>' +
    '<h1>📡 Sin conexión</h1>' +
    '<p>Axi no puede comunicarse con la laptop ahora mismo.</p>' +
    '<p>Verificá la VPN o reintenta cuando estés en casa.</p>',
    { headers: { 'Content-Type': 'text/html; charset=utf-8' } }
  );
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
  // Only drain items in 'queued' state — items in 'error' state require
  // user intervention (manual retry from chat UI) so we don't auto-resend.
  const items = (await idbAll(QUEUE_STORE)).filter((i) => i.status === 'queued');
  let lastTransientError = null;
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
          client_ts: item.created_at,
        }),
      });
      if (r.ok) {
        const data = await r.json();
        // SUCCESS — safe to remove from queue.
        await idbDelete(QUEUE_STORE, item.id);
        await notifyClients({
          type: 'sync-sent', tempId: item.id,
          answer: data.answer, latency_ms: data.latency_ms,
        });
        continue;
      }
      // 5xx = transient (server momentarily down, brain crashed, etc.).
      //   KEEP in queue, throw so the browser retries the sync later.
      // 4xx = permanent (validation, auth, bad payload).
      //   Mark as 'error' but DO NOT DELETE — let the user see + retry
      //   from the chat UI. Never silently lose data.
      if (r.status >= 500) {
        lastTransientError = new Error(`HTTP ${r.status}`);
        await notifyClients({ type: 'sync-retry', tempId: item.id });
        // Don't continue to next item — let throw signal sync incomplete.
        break;
      } else {
        await idbPut({ ...item, status: 'error', error: `HTTP ${r.status}` });
        await notifyClients({ type: 'sync-error', tempId: item.id, error: `HTTP ${r.status}` });
      }
    } catch (e) {
      // Network failure (offline / VPN down). Keep item queued, browser
      // will retry the sync when network is back.
      lastTransientError = e;
      await notifyClients({ type: 'sync-retry', tempId: item.id });
      break;  // stop processing — the rest will retry next time
    }
  }
  // Refresh badge after any successful drain.
  try { await refreshBadge(); } catch (e) { /* offline */ }
  if (lastTransientError) throw lastTransientError;  // signal sync incomplete
}

async function idbPut(item) {
  const db = await openIdb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction([QUEUE_STORE], 'readwrite');
    tx.objectStore(QUEUE_STORE).put(item);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
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
