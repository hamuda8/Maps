// Parity: Maps-js's own smoke test (tests/smoke.test.js), unchanged except for which server it
// starts: the Zig maps-server instead of `node app.js`. It runs from the Maps-js folder (for its
// public/ files and its node_modules/mongodb), against a throwaway database.
//
//   zig build server && node --test tests/parity/smoke.test.mjs
//
// MAPS_JS (default ../Maps-js) and MAPS_SERVER (default zig-out/bin/maps-server[.exe]) override paths.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

const HERE = import.meta.dirname;
const MAPS_JS = path.resolve(process.env.MAPS_JS || path.join(HERE, '../../../Maps-js'));
const MAPS_SERVER = path.resolve(process.env.MAPS_SERVER || path.join(HERE, '../../zig-out/bin', process.platform === 'win32' ? 'maps-server.exe' : 'maps-server'));
const { MongoClient } = createRequire(path.join(MAPS_JS, 'package.json'))('mongodb');

const MONGO_URI = process.env.TEST_MONGO_URI || 'mongodb://127.0.0.1:27017';
const DB_NAME = 'MapsTest';
const PORT = 5100 + Math.floor(Math.random() * 800);
const BASE = `http://127.0.0.1:${PORT}`;
const PNG = Buffer.from('89504e470d0a1a0a0000000d4948445200000001000000010806000000', 'hex');

let server, tileServer, mongo, db, cacheDir;
let tileHits = 0;
const KEY_A = `wf_maps_test_${crypto.randomBytes(8).toString('hex')}`;
const KEY_B = `wf_maps_test_${crypto.randomBytes(8).toString('hex')}`;

const post = (p, body, key) => fetch(BASE + p, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(key ? { 'x-maps-api-key': key } : {}) },
    body: typeof body === 'string' ? body : JSON.stringify(body),
});

before(async () => {
    mongo = new MongoClient(MONGO_URI);
    await mongo.connect();
    db = mongo.db(DB_NAME);
    await db.dropDatabase();
    await db.collection('apiKeys').insertMany([
        { userId: 'OWNER_A', appName: 'Test A', key: KEY_A, status: 'active', createdAt: new Date() },
        { userId: 'OWNER_B', appName: 'Test B', key: KEY_B, status: 'active', createdAt: new Date() },
    ]);

    tileServer = createServer((req, res) => { tileHits++; res.writeHead(200, { 'Content-Type': 'image/png' }).end(PNG); });
    await new Promise(resolve => tileServer.listen(0, '127.0.0.1', resolve));
    cacheDir = mkdtempSync(path.join(tmpdir(), 'maps-tiles-'));

    server = spawn(MAPS_SERVER, [], {
        cwd: MAPS_JS,
        env: {
            ...process.env,
            PORT: String(PORT),
            MONGO_URI,
            MONGO_DB: DB_NAME,
            MAPS_TILE_URL: `http://127.0.0.1:${tileServer.address().port}/{z}/{x}/{y}.png`,
            TILE_CACHE_DIR: cacheDir,
            VALHALLA_URL: 'http://127.0.0.1:9/route',
        },
        stdio: ['ignore', 'pipe', 'pipe'],
    });
    let log = '';
    server.stdout.on('data', d => { log += d; });
    server.stderr.on('data', d => { log += d; });
    for (let i = 0; i < 50; i++) {
        if (log.includes('running on')) return;
        await new Promise(r => setTimeout(r, 200));
    }
    throw new Error(`server did not start:\n${log}`);
});

after(async () => {
    server?.kill();
    tileServer?.close();
    await db?.dropDatabase();
    await mongo?.close();
    if (cacheDir) rmSync(cacheDir, { recursive: true, force: true });
});

test('health check reports the database', async () => {
    const res = await fetch(`${BASE}/healthz`);
    assert.equal(res.status, 200);
    assert.equal((await res.json()).db, 'up');
});

test('map style points at the tile proxy and carries attribution', async () => {
    const style = await (await fetch(`${BASE}/sdk/style.json`)).json();
    assert.match(style.sources.osm.tiles[0], new RegExp(`^${BASE}/tiles/\\{z\\}/\\{x\\}/\\{y\\}\\.png\\?s=[0-9a-f]+$`));
    assert.ok(style.sources.osm.attribution);
});

test('tile proxy fetches each tile upstream once, then serves it from cache', async () => {
    const before = tileHits;
    const first = await fetch(`${BASE}/tiles/3/4/2.png`);
    assert.equal(first.status, 200);
    assert.equal(first.headers.get('content-type'), 'image/png');
    assert.deepEqual(Buffer.from(await first.arrayBuffer()), PNG);
    await fetch(`${BASE}/tiles/3/4/2.png`);
    assert.equal(tileHits - before, 1);
    assert.equal((await fetch(`${BASE}/tiles/3/8/0.png`)).status, 404); // x outside zoom 3
    assert.equal((await fetch(`${BASE}/tiles/25/0/0.png`)).status, 404);
});

test('security headers: console not frameable, embeds frameable', async () => {
    const dev = await fetch(`${BASE}/developers`);
    assert.equal(dev.headers.get('x-frame-options'), 'SAMEORIGIN');
    assert.equal(dev.headers.get('x-content-type-options'), 'nosniff');
    const embed = await fetch(`${BASE}/embed/full?key=${KEY_A}`);
    assert.equal(embed.status, 200);
    assert.equal(embed.headers.get('x-frame-options'), null);
});

test('malformed JSON is a 400, not a 500', async () => {
    const res = await post('/api/tracking/end', '{bad', KEY_A);
    assert.equal(res.status, 400);
});

test('routing needs a key unless called from the map page', async () => {
    const res = await fetch(`${BASE}/api/route/valhalla?json=x`, { headers: { 'Sec-Fetch-Site': 'cross-site' } });
    assert.equal(res.status, 401);
    const own = await fetch(`${BASE}/api/route/valhalla?json=x`, { headers: { Referer: `${BASE}/` } });
    assert.equal(own.status, 400); // passed the check, then rejected the bad request
});

test('demo key is refused for look-alike referers', async () => {
    const res = await fetch(`${BASE}/embed/full?key=DEMO_KEY`, { headers: { Referer: 'https://evil.example/?wufour.com' } });
    assert.equal(res.status, 403);
});

test('tracking: random track ids, same deliveryId allowed in two apps, live relay, end', async () => {
    const a = await (await post('/api/tracking/batch', { deliveryId: '1001', coordinates: [{ lat: 33.5, lng: 36.3 }] }, KEY_A)).json();
    const b = await (await post('/api/tracking/batch', { deliveryId: '1001', coordinates: [{ lat: 33.6, lng: 36.2 }] }, KEY_B)).json();
    assert.ok(a.success && b.success);
    assert.match(a.trackId, /^[0-9a-f]{32}$/);
    assert.notEqual(a.trackId, b.trackId);
    const again = await (await post('/api/tracking/batch', { deliveryId: '1001', coordinates: [{ lat: 33.51, lng: 36.3 }] }, KEY_A)).json();
    assert.equal(again.trackId, a.trackId); // stable for the delivery's lifetime

    assert.equal((await fetch(`${BASE}/embed/tracking?track_id=${a.trackId}`)).status, 200);
    assert.equal((await fetch(`${BASE}/embed/tracking?track_id=1001`)).status, 403); // deliveryId is not a link

    const viewer = new WebSocket(`ws://127.0.0.1:${PORT}/?room=${a.trackId}&role=viewer`);
    const messages = [];
    const closed = new Promise(resolve => { viewer.onclose = resolve; });
    viewer.onmessage = e => messages.push(JSON.parse(e.data));
    await new Promise((resolve, reject) => { viewer.onopen = resolve; viewer.onerror = reject; });

    const wrongDriver = new WebSocket(`ws://127.0.0.1:${PORT}/?room=${a.trackId}&role=driver&key=${KEY_B}`);
    await new Promise(resolve => { wrongDriver.onerror = resolve; wrongDriver.onclose = resolve; });

    const driver = new WebSocket(`ws://127.0.0.1:${PORT}/?room=${a.trackId}&role=driver&key=${KEY_A}`);
    await new Promise((resolve, reject) => { driver.onopen = resolve; driver.onerror = reject; });
    driver.send(JSON.stringify({ lat: 33.52, lng: 36.31, heading: 370, vehicle: '<b>x</b>', extra: '<script>' }));
    driver.send('not json');
    await new Promise(r => setTimeout(r, 300));
    assert.deepEqual(messages[0], { lat: 33.52, lng: 36.31, heading: 10 });

    assert.equal((await post('/api/tracking/end', { deliveryId: '1001' }, KEY_A)).status, 200);
    await closed;
    assert.deepEqual(messages.at(-1), { status: 'ENDED' });
    driver.close();

    // App B's delivery with the same deliveryId is untouched.
    assert.equal((await fetch(`${BASE}/embed/tracking?track_id=${b.trackId}`)).status, 200);
});

test('route API: valid key passes, unknown key is refused', async () => {
    const ok = await fetch(`${BASE}/api/v1/route?from=1,1&to=2,2`, { headers: { 'x-maps-api-key': KEY_B } });
    assert.equal(ok.status, 502); // key accepted; the test Valhalla address is unreachable on purpose
    const bad = await fetch(`${BASE}/api/v1/route?from=1,1&to=2,2`, { headers: { 'x-maps-api-key': 'wf_maps_nope' } });
    assert.equal(bad.status, 401);
});
