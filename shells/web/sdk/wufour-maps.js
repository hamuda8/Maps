/*
 * Wufour Maps JS library.
 *
 *   <script src="https://YOUR-MAPS-HOST/sdk/wufour-maps.js"></script>
 *   await WufourMaps.ready();
 *   const map = WufourMaps.map(el, { center: [33.5138, 36.2765], zoom: 13 });
 *   const pin = WufourMaps.marker([33.51, 36.27], { icon: WufourMaps.icon({ html: '<span class="my-marker"></span>', size: [36, 36] }) }).addTo(map);
 *   pin.bindTooltip('Parcel').on('click', () => ...);
 *   WufourMaps.polyline([[33.51, 36.27], [33.52, 36.28]], { color: '#2563eb', weight: 6 }).addTo(map);
 *
 * Coordinates are always [lat, lng] arrays or { lat, lng } objects.
 * The map itself is the Wufour map engine (sdk.wasm, served with this file): the same tiles,
 * colours and gestures as the Wufour Maps app, and no third-party code. Markers, tooltips and
 * popups are HTML on top of it, as before. `map.gl` keeps the parts of the old MapLibre object
 * that pages use (zoomIn/zoomOut, movestart/moveend, turning interactions off).
 */
(function () {
    'use strict';
    if (window.WufourMaps) return;

    const BASE = new URL(document.currentScript.src).origin;
    const DAMASCUS = [33.5138, 36.2765];
    const TILE = 256;

    // ---------- Loading ----------

    function loadCss(href) {
        if (document.querySelector(`link[href="${href}"]`)) return Promise.resolve();
        return new Promise((resolve, reject) => {
            const link = document.createElement('link');
            link.rel = 'stylesheet';
            link.href = href;
            link.onload = resolve;
            link.onerror = () => { link.remove(); reject(new Error(`Failed to load ${href}`)); };
            document.head.appendChild(link);
        });
    }

    let readyPromise = null;
    let engine = null; // { start, module }
    /** Loads the map engine and the styles. Call (and await) before creating maps. */
    function ready() {
        readyPromise = readyPromise || Promise.all([
            loadCss(`${BASE}/sdk/wufour-maps.css`),
            import(`${BASE}/zui.js`),
            WebAssembly.compileStreaming(fetch(`${BASE}/sdk.wasm`)),
        ]).then(([, zui, module]) => { engine = { start: zui.start, module }; })
            .catch(err => { readyPromise = null; throw err; });
        return readyPromise;
    }

    // ---------- Helpers ----------

    function toLngLat(p) {
        if (Array.isArray(p)) return [Number(p[1]), Number(p[0])];
        if (p && p.lat != null && p.lng != null) return [Number(p.lng), Number(p.lat)];
        throw new Error('WufourMaps: expected [lat, lng] or { lat, lng }');
    }

    function boundsOf(points) {
        let minLat = Infinity, minLng = Infinity, maxLat = -Infinity, maxLng = -Infinity;
        for (const p of points) {
            const [lng, lat] = toLngLat(p);
            minLat = Math.min(minLat, lat); maxLat = Math.max(maxLat, lat);
            minLng = Math.min(minLng, lng); maxLng = Math.max(maxLng, lng);
        }
        return [[minLat, minLng], [maxLat, maxLng]];
    }

    const padValue = p => (Array.isArray(p) ? p[0] : (p || 0));

    // Web Mercator, in pixels at zoom 0 (the engine's own numbers).
    function world(lng, lat) {
        const s = Math.sin(Math.max(-85.05112878, Math.min(85.05112878, lat)) * Math.PI / 180);
        return [(lng + 180) / 360 * TILE, (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * TILE];
    }
    function fromWorld(x, y) {
        const n = Math.PI - 2 * Math.PI * y / TILE;
        return [x / TILE * 360 - 180, Math.atan(Math.sinh(n)) * 180 / Math.PI];
    }

    /** An HTML icon: html content, size [w, h], and the anchor point [x, y] inside it (default: centre). */
    function icon({ html = '', size = [36, 36], anchor, className = '' } = {}) {
        return { html, size, anchor: anchor || [size[0] / 2, size[1] / 2], className };
    }

    const DEFAULT_ICON = icon({
        html: '<svg width="36" height="36" viewBox="0 0 24 24" fill="#ef4444"><path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z" stroke="white" stroke-width="1.5"/></svg>',
        size: [36, 36],
        anchor: [18, 34],
    });

    const prefersReducedMotion = () => window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true;

    // ---------- Map ----------

    class WMap {
        constructor(el, opts = {}) {
            if (!engine) throw new Error('WufourMaps: call `await WufourMaps.ready()` first');
            // Zoom numbers: MapLibre's by default (as this library always used), Leaflet's
            // (one higher, the engine's own) with leafletZoom.
            this._zoomOffset = opts.leafletZoom ? 0 : 1;
            this._el = el;
            this._removed = false;
            this._handlers = [];
            this._markers = new Set();
            this._lines = new Set();
            this._queue = [];
            this._app = null;
            this._camera = null;
            this._can = { pan: true, zoom: true };

            el.classList.add('wufour-map');
            if (getComputedStyle(el).position === 'static') el.style.position = 'relative';
            this._host = document.createElement('div');
            this._host.className = 'wufour-map-engine';
            this._overlay = document.createElement('div');
            this._overlay.className = 'wufour-map-overlay';
            el.append(this._host, this._overlay);
            this._addControls();

            const center = opts.center || DAMASCUS;
            const [lng, lat] = toLngLat(center);
            this._send({ cmd: 'view', lat, lng, zoom: (opts.zoom ?? 13) + this._zoomOffset, animate: false });
            engine.start(engine.module, this._host, { link: BASE, dark: false, onPost: text => this._event(JSON.parse(text)) })
                .then(app => {
                    if (this._removed) return app.destroy();
                    this._app = app;
                    for (const cmd of this._queue.splice(0)) app.send(cmd);
                });

            this.gl = this._compat();
        }

        _send(cmd) {
            const text = JSON.stringify(cmd);
            if (this._app) this._app.send(text); else this._queue.push(text);
        }

        _emit(type, out) {
            for (const h of this._handlers.slice()) if (h.type === type) h.fn(out);
        }

        // The engine reports the camera, clicks, movestart and moveend; the other MapLibre events
        // pages may listen to (load, move, zoomstart/zoom/zoomend, dragstart/drag/dragend) are
        // made from those, in MapLibre's order.
        _event(e) {
            const plain = () => ({ originalEvent: this._move && this._move.user ? {} : undefined, target: this.gl });
            if (e.event === 'camera') {
                const before = this._camera;
                this._camera = e;
                for (const m of this._markers) m._place();
                if (!before) { this._emit('load', { target: this.gl }); return; }
                const mv = this._move;
                if (!mv) return;
                if (e.zoom !== mv.zoom && !mv.zooming) { mv.zooming = true; this._emit('zoomstart', plain()); }
                if (mv.user && !mv.zooming && !mv.dragging && (e.lat !== mv.lat || e.lng !== mv.lng)) { mv.dragging = true; this._emit('dragstart', plain()); }
                this._emit('move', plain());
                if (mv.zooming && e.zoom !== before.zoom) this._emit('zoom', plain());
                if (mv.dragging) this._emit('drag', plain());
                return;
            }
            if (e.event === 'movestart') {
                const c = this._camera || {};
                this._move = { user: e.user, zoom: c.zoom, lat: c.lat, lng: c.lng, zooming: false, dragging: false };
                this._emit('movestart', plain());
                return;
            }
            if (e.event === 'moveend') {
                const mv = this._move;
                const out = plain();
                this._move = null;
                if (mv && mv.dragging) this._emit('dragend', out);
                if (mv && mv.zooming) this._emit('zoomend', out);
                this._emit('moveend', out);
                return;
            }
            if (e.event === 'click') {
                // MapLibre closes popups on a map click.
                for (const m of this._markers) if (m._popup && m._popup.isConnected) m._popup.remove();
                this._emit('click', { latlng: { lat: e.lat, lng: e.lng }, originalEvent: {} });
            }
        }

        /** Screen point of a coordinate, in the map element's pixels. */
        _project(lng, lat) {
            const c = this._camera;
            if (!c) return null;
            const k = Math.pow(2, c.zoom);
            const [x, y] = world(lng, lat);
            const [cx, cy] = world(c.lng, c.lat);
            return [(x - cx) * k + c.width / 2, (y - cy) * k + c.height / 2];
        }

        _unproject(px, py) {
            const c = this._camera;
            const k = Math.pow(2, c.zoom);
            const [cx, cy] = world(c.lng, c.lat);
            return fromWorld(cx + (px - c.width / 2) / k, cy + (py - c.height / 2) / k);
        }

        _addControls() {
            // The same class as MapLibre's zoom buttons, so pages that hide them still can.
            const group = document.createElement('div');
            group.className = 'wufour-ctrl maplibregl-ctrl-group';
            for (const [label, delta] of [['+', 1], ['−', -1]]) {
                const b = document.createElement('button');
                b.type = 'button';
                b.textContent = label;
                b.setAttribute('aria-label', delta > 0 ? 'Zoom in' : 'Zoom out');
                b.addEventListener('click', () => this._send({ cmd: 'zoomBy', delta, animate: !prefersReducedMotion() }));
                group.append(b);
            }
            this._overlay.append(group);
        }

        /** What pages used of the MapLibre object: kept working on the new engine. */
        _compat() {
            const map = this;
            const handler = (what) => ({
                disable() { map._can[what] = false; map._send({ cmd: 'interactive', pan: map._can.pan, zoom_enabled: map._can.zoom }); },
                enable() { map._can[what] = true; map._send({ cmd: 'interactive', pan: map._can.pan, zoom_enabled: map._can.zoom }); },
                isEnabled() { return map._can[what]; },
            });
            return {
                getContainer: () => map._el,
                zoomIn: ({ duration } = {}) => map._send({ cmd: 'zoomBy', delta: 1, animate: duration !== 0 }),
                zoomOut: ({ duration } = {}) => map._send({ cmd: 'zoomBy', delta: -1, animate: duration !== 0 }),
                getZoom: () => map.getZoom(),
                getCenter: () => map.getCenter(),
                resize: () => map.resize(),
                on: (type, fn) => { map._handlers.push({ type, fn, wrapped: fn }); },
                off: (type, fn) => { map._handlers = map._handlers.filter(h => h.type !== type || h.fn !== fn); },
                dragPan: handler('pan'),
                scrollZoom: handler('zoom'),
                boxZoom: handler('zoom'),
                doubleClickZoom: handler('zoom'),
                touchZoomRotate: handler('zoom'),
                keyboard: handler('zoom'),
            };
        }

        /** Move the view. animate: glide there (default) instead of jumping. */
        setView(center, zoom, { animate = true, duration = 700 } = {}) {
            const [lng, lat] = toLngLat(center);
            this._send({ cmd: 'view', lat, lng, zoom: zoom != null ? zoom + this._zoomOffset : null, animate: animate && !prefersReducedMotion(), duration });
            return this;
        }

        /** Fly to a point with the zoom-out-and-in arc; good for jumping across a city. */
        flyTo(center, zoom, { duration = 1200 } = {}) {
            const [lng, lat] = toLngLat(center);
            this._send({ cmd: 'fly', lat, lng, zoom: zoom != null ? zoom + this._zoomOffset : null, duration: prefersReducedMotion() ? 0 : duration });
            return this;
        }

        getZoom() { return this._camera ? this._camera.zoom - this._zoomOffset : 13; }

        getCenter() { return this._camera ? { lat: this._camera.lat, lng: this._camera.lng } : { lat: DAMASCUS[0], lng: DAMASCUS[1] }; }

        /** Fit the view to the given points (two or more, e.g. polyline.getBounds()). */
        fitBounds(points, { padding = 0, maxZoom, animate = true } = {}) {
            const pts = (points || []).filter(Boolean);
            if (!pts.length) return this;
            const [[minLat, minLng], [maxLat, maxLng]] = boundsOf(pts);
            const max = maxZoom != null ? maxZoom + this._zoomOffset : null;
            if (minLat === maxLat && minLng === maxLng) {
                this._send({ cmd: 'view', lat: minLat, lng: minLng, zoom: max, animate: animate && !prefersReducedMotion(), duration: 600 });
                return this;
            }
            this._send({ cmd: 'fit', points: [[minLat, minLng], [maxLat, maxLng]], padding: padValue(padding), max_zoom: max, animate: animate && !prefersReducedMotion() });
            return this;
        }

        /** Events: 'click' (receives { latlng }), 'load', 'movestart', 'move', 'moveend', 'zoomstart', 'zoom', 'zoomend', 'dragstart', 'drag', 'dragend'. */
        on(type, fn) {
            this._handlers.push({ type, fn });
            return this;
        }

        off(type, fn) {
            this._handlers = this._handlers.filter(h => h.type !== type || h.fn !== fn);
            return this;
        }

        resize() { return this; } // the engine follows its element's size by itself

        _sendLines() {
            const lines = [...this._lines].map(l => ({
                points: l._points.map(p => { const [lng, lat] = toLngLat(p); return [lat, lng]; }),
                color: l._opts.color || '#2563eb',
                weight: l._opts.weight ?? 6,
                opacity: l._opts.opacity ?? 0.8,
                dash: Array.isArray(l._opts.dashArray) && l._opts.dashArray.length >= 2 ? [Number(l._opts.dashArray[0]), Number(l._opts.dashArray[1])] : null,
            }));
            this._send({ cmd: 'lines', lines });
        }

        remove() {
            if (this._removed) return;
            this._removed = true;
            for (const m of [...this._markers]) m.remove();
            this._app?.destroy();
            this._host.remove();
            this._overlay.remove();
        }
    }

    // ---------- Marker ----------

    class Marker {
        constructor(latlng, opts = {}) {
            this._latlng = toLngLat(latlng);
            this._opts = opts;
            this._handlers = { click: [], dragend: [] };
            this._map = null;
            this._group = null;
            this._tooltip = null;
            this._tooltipContent = undefined;
            this._popup = null;
            this._popupContent = null;

            this._el = document.createElement('div');
            this._el.className = 'wufour-marker';
            if (opts.opacity != null) this._el.style.opacity = opts.opacity;
            if (opts.zIndexOffset) this._el.style.zIndex = String(opts.zIndexOffset);
            this._el.addEventListener('click', e => {
                if (this._dragged) return;
                for (const fn of this._handlers.click) fn({ latlng: this.getLatLng(), originalEvent: e });
                if (this._popupContent != null) this._togglePopup();
            });
            if (opts.draggable) this._draggable();
            this._applyIcon(opts.icon || DEFAULT_ICON);
        }

        _applyIcon(ic) {
            const [w, h] = ic.size;
            this._icon = ic;
            this._el.style.width = `${w}px`;
            this._el.style.height = `${h}px`;
            this._el.innerHTML = ic.html;
            if (ic.className) this._el.classList.add(...ic.className.split(/\s+/).filter(Boolean));
            this._place();
        }

        _place() {
            const map = this._map;
            if (!map) return;
            const p = map._project(this._latlng[0], this._latlng[1]);
            if (!p) { this._el.style.visibility = 'hidden'; return; }
            this._el.style.visibility = '';
            this._el.style.transform = `translate(${p[0] - this._icon.anchor[0]}px, ${p[1] - this._icon.anchor[1]}px)`;
            for (const b of [this._tooltip, this._popup]) {
                if (b && b.isConnected) b.style.transform = `translate(${p[0]}px, ${p[1] - this._popupOffset()}px) translate(-50%, -100%)`;
            }
        }

        _draggable() {
            this._el.style.touchAction = 'none';
            this._el.addEventListener('pointerdown', down => {
                if (!this._map) return;
                down.stopPropagation();
                this._el.setPointerCapture(down.pointerId);
                this._dragged = false;
                const start = [down.clientX, down.clientY];
                // Where on the icon it was taken: that point stays under the pointer (as MapLibre).
                const box = this._map._el.getBoundingClientRect();
                const at = this._map._project(this._latlng[0], this._latlng[1]) || [down.clientX - box.left, down.clientY - box.top];
                const grab = [down.clientX - box.left - at[0], down.clientY - box.top - at[1]];
                const move = e => {
                    if (!this._dragged && Math.hypot(e.clientX - start[0], e.clientY - start[1]) < 4) return;
                    this._dragged = true;
                    const r = this._map._el.getBoundingClientRect();
                    this._latlng = this._map._unproject(e.clientX - r.left - grab[0], e.clientY - r.top - grab[1]);
                    this._place();
                };
                const up = () => {
                    this._el.removeEventListener('pointermove', move);
                    this._el.removeEventListener('pointerup', up);
                    this._el.removeEventListener('pointercancel', up);
                    if (this._dragged) for (const fn of this._handlers.dragend) fn({ latlng: this.getLatLng() });
                    setTimeout(() => { this._dragged = false; }, 0);
                };
                this._el.addEventListener('pointermove', move);
                this._el.addEventListener('pointerup', up);
                this._el.addEventListener('pointercancel', up);
            });
        }

        addTo(target) {
            if (target instanceof LayerGroup) {
                target._add(this);
                return this;
            }
            this._attach(target);
            return this;
        }

        _attach(map) {
            if (this._map) this._detach();
            this._map = map;
            map._markers.add(this);
            map._overlay.append(this._el);
            this._place();
        }

        _detach() {
            if (!this._map) return;
            this._map._markers.delete(this);
            this._el.remove();
            this._tooltip?.remove();
            this._popup?.remove();
            this._map = null;
        }

        setLatLng(latlng) {
            this._latlng = toLngLat(latlng);
            this._place();
            return this;
        }

        getLatLng() { return { lat: this._latlng[1], lng: this._latlng[0] }; }

        setIcon(ic) { this._applyIcon(ic); return this; }

        setOpacity(value) { this._el.style.opacity = value; return this; }

        /** Events: 'click' and 'dragend' (both receive { latlng }). */
        on(type, fn) {
            if (this._handlers[type]) this._handlers[type].push(fn);
            return this;
        }

        _popupOffset() { return this._icon.anchor[1] + 4; }

        _bubble(className, content, closable) {
            const outer = document.createElement('div');
            outer.className = `wufour-bubble ${className} maplibregl-popup`;
            const inner = document.createElement('div');
            inner.className = 'maplibregl-popup-content';
            if (content instanceof Node) inner.append(content); else inner.textContent = String(content); // text, never HTML
            if (closable) {
                const x = document.createElement('button');
                x.type = 'button';
                x.className = 'maplibregl-popup-close-button';
                x.setAttribute('aria-label', 'Close popup');
                x.textContent = '×';
                x.addEventListener('click', ev => { ev.stopPropagation(); outer.remove(); });
                inner.append(x);
            }
            const tip = document.createElement('div');
            tip.className = 'maplibregl-popup-tip';
            outer.append(inner, tip);
            return outer;
        }

        /** A small label shown on hover (or tap on touch screens). Strings are shown as text. */
        bindTooltip(content) {
            const first = this._tooltipContent === undefined;
            this._tooltipContent = content;
            if (this._tooltip) this._tooltip.replaceWith(this._tooltip = this._bubble('wufour-tooltip', content));
            if (!first) return this;
            const show = () => {
                if (!this._map || this._map._removed) return;
                if (!this._tooltip) this._tooltip = this._bubble('wufour-tooltip', this._tooltipContent);
                this._map._overlay.append(this._tooltip);
                this._place();
            };
            const hide = () => this._tooltip?.remove();
            let tapTimer;
            this._el.addEventListener('mouseenter', show);
            this._el.addEventListener('mouseleave', hide);
            this._el.addEventListener('touchend', () => {
                show();
                clearTimeout(tapTimer);
                tapTimer = setTimeout(hide, 3000);
            }, { passive: true });
            return this;
        }

        _togglePopup() {
            if (!this._map) return;
            if (this._popup?.isConnected) { this._popup.remove(); return; }
            this._popup = this._bubble('wufour-popup', this._popupContent, true);
            this._map._overlay.append(this._popup);
            this._place();
        }

        /** A popup opened by clicking the marker. Strings are shown as text. */
        bindPopup(content) {
            this._popupContent = content;
            return this;
        }

        remove() {
            this._detach();
            if (this._group) this._group._layers.delete(this);
            this._group = null;
            return this;
        }
    }

    // ---------- Polyline ----------

    class Polyline {
        constructor(points, opts = {}) {
            this._points = points || [];
            this._opts = opts;
            this._map = null;
        }

        addTo(map) {
            if (this._map) this.remove();
            this._map = map;
            map._lines.add(this);
            map._sendLines();
            return this;
        }

        setLatLngs(points) {
            this._points = points || [];
            this._map?._sendLines();
            return this;
        }

        getLatLngs() { return this._points.slice(); }

        /** [[south, west], [north, east]]: pass to map.fitBounds(). */
        getBounds() { return boundsOf(this._points); }

        remove() {
            const map = this._map;
            this._map = null;
            if (!map || map._removed) return this;
            map._lines.delete(this);
            map._sendLines();
            return this;
        }
    }

    // ---------- Layer group ----------

    class LayerGroup {
        constructor() {
            this._layers = new Set();
            this._map = null;
        }

        _add(marker) {
            marker.remove();
            marker._group = this;
            this._layers.add(marker);
            if (this._map) marker._attach(this._map);
        }

        addTo(map) {
            this._map = map;
            for (const marker of this._layers) marker._attach(map);
            return this;
        }

        clearLayers() {
            for (const marker of [...this._layers]) marker.remove();
            this._layers.clear();
            return this;
        }

        remove() {
            this.clearLayers();
            this._map = null;
            return this;
        }
    }

    // ---------- Search ----------

    /** Places matching a text, nearest to `near` first: [{ name, label, street, area, city, lat, lng }]. */
    async function search(text, { near, limit = 6, lang } = {}) {
        const q = new URLSearchParams({ q: String(text || ''), limit: String(limit) });
        if (near) { const [lng, lat] = toLngLat(near); q.set('lat', lat); q.set('lng', lng); }
        if (lang) q.set('lang', lang);
        const res = await fetch(`${BASE}/api/v1/search?${q}`);
        const data = await res.json().catch(() => ({}));
        if (!res.ok || !data.success) throw new Error(data.message || 'Search failed');
        return data.results;
    }

    /** The address at a point: { name, label, street, area, city, lat, lng } or null. */
    async function reverse(latlng, { lang } = {}) {
        const [lng, lat] = toLngLat(latlng);
        const res = await fetch(`${BASE}/api/v1/reverse?lat=${lat}&lng=${lng}${lang ? `&lang=${encodeURIComponent(lang)}` : ''}`);
        const data = await res.json().catch(() => ({}));
        if (!res.ok || !data.success) throw new Error(data.message || 'Search failed');
        return data.place;
    }

    window.WufourMaps = {
        version: '2.0.0',
        ready,
        search,
        reverse,
        icon,
        map: (el, opts) => new WMap(el, opts),
        marker: (latlng, opts) => new Marker(latlng, opts),
        polyline: (points, opts) => new Polyline(points, opts),
        layerGroup: () => new LayerGroup(),
    };
})();
