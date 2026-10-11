// Wufour Maps service worker (installable app and offline use), as Maps-js's:
// - The app's own files: network first (so deploys show up immediately), cache as offline fallback.
// - Map tiles: cache first, capped so the cache can't fill the phone's storage.
// - Place search, reverse lookups and routes the map already asked for: network first, the last
//   answer kept (capped) so a search or route seen before still shows offline.
// - Pages: the map from the cache when offline; any other page gets the offline page.
// - Other API calls (keys, tracking, sign-in), embeds' data and other sites' requests: never cached.
const CACHE_NAME = 'wufour-maps-v16';
const TILE_CACHE = 'wufour-tiles-v2';
const API_CACHE = 'wufour-api-v1';
const MAX_TILES = 1500; // ~15-30 MB of raster tiles
const MAX_API = 300;    // small JSON answers
const OFFLINE_PAGE = '/offline.html';

const ASSETS_TO_CACHE = [
    '/',
    OFFLINE_PAGE,
    '/manifest.json',
    '/zui.js',
    '/app.wasm',
    '/assets/images/icon.svg',
    '/assets/images/icons/icon-192.png',
];

// Read-only lookups the map makes (GET, no API key, same answer for the same question).
const CACHED_API = ['/api/v1/search', '/api/v1/reverse', '/api/route/valhalla', '/api/v1/route'];

self.addEventListener('install', (event) => {
    self.skipWaiting();
    // One by one, so a single missing file doesn't leave the whole shell uncached.
    event.waitUntil(caches.open(CACHE_NAME).then((cache) => Promise.all(ASSETS_TO_CACHE.map((url) => cache.add(url).catch(() => {})))));
});

self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys()
            .then((names) => Promise.all(names.filter((n) => n.startsWith('wufour-') && ![CACHE_NAME, TILE_CACHE, API_CACHE].includes(n)).map((n) => caches.delete(n))))
            .then(() => self.clients.claim())
    );
});

async function trim(cacheName, max) {
    const cache = await caches.open(cacheName);
    const keys = await cache.keys();
    for (let i = 0; i < keys.length - max; i++) await cache.delete(keys[i]); // oldest first
}

async function tile(request) {
    const cached = await caches.match(request, { cacheName: TILE_CACHE });
    if (cached) return cached;
    try {
        const response = await fetch(request);
        if (response.ok) {
            const copy = response.clone();
            caches.open(TILE_CACHE).then((cache) => cache.put(request, copy)).then(() => trim(TILE_CACHE, MAX_TILES)).catch(() => {});
        }
        return response;
    } catch {
        return new Response('', { status: 503 });
    }
}

async function lookup(request) {
    try {
        const response = await fetch(request);
        if (response.ok) {
            const copy = response.clone();
            // Delete first so a refreshed answer moves to the end and the oldest are trimmed first.
            caches.open(API_CACHE).then((cache) => cache.delete(request).then(() => cache.put(request, copy))).then(() => trim(API_CACHE, MAX_API)).catch(() => {});
        }
        return response;
    } catch {
        const cached = await caches.match(request, { cacheName: API_CACHE });
        return cached || new Response(JSON.stringify({ success: false, message: 'You are offline.' }), { status: 503, headers: { 'Content-Type': 'application/json' } });
    }
}

async function networkFirst(request) {
    try {
        const response = await fetch(request);
        if (response.ok && response.type === 'basic') {
            const copy = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(request, copy)).catch(() => {});
        }
        return response;
    } catch {
        const cached = await caches.match(request, { cacheName: CACHE_NAME });
        return cached || new Response('', { status: 503 });
    }
}

// The map page (any link into it, ?start=... included) opens from the cache offline.
async function page(request, url) {
    try {
        const response = await fetch(request);
        if (response.ok && url.pathname === '/') {
            const copy = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put('/', copy)).catch(() => {});
        }
        return response;
    } catch {
        if (url.pathname === '/') {
            const cached = await caches.match('/', { cacheName: CACHE_NAME });
            if (cached) return cached;
        }
        return (await caches.match(OFFLINE_PAGE, { cacheName: CACHE_NAME })) || new Response('You are offline.', { status: 503 });
    }
}

self.addEventListener('fetch', (event) => {
    const request = event.request;
    if (request.method !== 'GET' || request.headers.has('range')) return;
    const url = new URL(request.url);
    if (url.origin !== self.location.origin) return;

    if (url.pathname.startsWith('/tiles/')) {
        event.respondWith(tile(request));
        return;
    }
    if (request.mode === 'navigate') {
        event.respondWith(page(request, url));
        return;
    }
    if (CACHED_API.includes(url.pathname) && !request.headers.has('x-maps-api-key')) {
        event.respondWith(lookup(request));
        return;
    }
    // Live data and per-key pages must always come from the server.
    if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/embed/') || url.pathname.startsWith('/auth')) return;
    if (url.pathname === '/developers' || url.pathname === '/healthz' || url.pathname.startsWith('/sdk/')) return;

    event.respondWith(networkFirst(request));
});
