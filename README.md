# Wufour Maps

Maps app, embeddable map pages and the `WufourMaps` JavaScript library, written in Zig.
It replaces Maps-js (Node + MapLibre) with the same HTTP API, SDK contract and MongoDB data.

- **Client** (`src/client`): one zui codebase built for the web (wasm + DOM), Android (native
  Views) and iOS (UIKit). Search, directions, turn-by-turn navigation with voice, 3D view, Arabic
  and English, light and dark.
- **Embeds**: `/embed/picker`, `/embed/driver`, `/embed/tracking` (same `postMessage` contract as Maps-js).
- **SDK** (`src/sdk`): `/sdk/wufour-maps.js`, a Leaflet-style API (markers, polylines, popups,
  events) on our own map engine. No MapLibre.
- **Developer console** (`src/developers`): `/developers` — API keys, usage, snippets, live sandbox.
- **Server** (`src/server`): tiles proxy + cache, routing through Valhalla, search and reverse
  geocoding from our own index, live tracking WebSockets, API keys.

Shared code (UI framework, map engine, HTTP, MongoDB, geo index) lives in
[zig-core](https://github.com/hamuda8/zig-core), pinned in `build.zig.zon`.

## Build

Zig 0.17.0 (`C:\Tools\zig-0.17.0\zig.exe` on the dev laptop).

| Command | Output |
|---|---|
| `zig build web -Doptimize=small` | `zig-out/web` (the pages, wasm, SDK, service worker) |
| `zig build android -Doptimize=safe` | `zig-out/android/maps.apk` |
| `zig build ios` | static libraries for device and simulator (the app is linked on macOS CI) |
| `zig build server -Doptimize=safe` | `zig-out/bin/maps-server` (this machine) |
| `zig build server-linux -Doptimize=safe` | `zig-out/linux/maps-server` (Proxmox) |
| `zig build test` | client and server tests |

Build options: `-Dserver=<url>` is the Maps server the phone apps use (default
`https://maps.wreseal.com`). Only override it for USB development
(`adb reverse tcp:5106 tcp:5106` and `-Dserver=http://127.0.0.1:5106`) and never install such a
build for real use.

Working on zig-core at the same time: add `--fork=C:/MProjects/zig-core` to any command.

Fonts: the phone apps draw with Wufour Sans and Wufour Arabic from zig-core's `shells/fonts/`
(`zui/font.zig` has the rule: weight 400/500/700, Arabic text in the Arabic face with the Sans
filling in, the system font when a file is missing). The APK gets them on its own
(`assets/fonts/`). On iOS `zig build ios` puts them in `zig-out/ios/fonts/`; the bundle needs those
six files next to `Info.plist` (listed there under `UIAppFonts`) and the app links `CoreText`. To
refresh them, copy `..\WufourType\dist\golden\*.ttf` into `..\zig-core\shells\fonts\`, then point
`build.zig.zon` at the new zig-core commit (or build with `--fork`).

## Search regions

Search works for any country whose OpenStreetMap extract is in `regions/` (git-ignored). Drop a
`.osm.pbf` file there (e.g. from download.geofabrik.de) and restart the server: it builds a
`.wgeo` index next to it on its own and searches it from then on.

## Server configuration

Environment variables win; otherwise `.env.local`, then `.env.production`, then `.env` in the
working folder.

| Variable | Default | Meaning |
|---|---|---|
| `PORT`, `LISTEN` | `5005`, `0.0.0.0` | where to listen (plain HTTP; TLS is Cloudflare's) |
| `MONGO_URI`, `MONGO_DB` | local, `Maps` | database (same collections as Maps-js) |
| `VALHALLA_URL`, `VALHALLA_API_KEY` | local Valhalla | routing |
| `MAPS_TILE_URL`, `MAPS_TILE_PROXY`, `TILE_CACHE_DIR` | OSM, on, `cache/tiles` | raster tiles |
| `REGIONS_DIR` | `regions` | `.osm.pbf` files to search |
| `GEOCODER_FALLBACK_URL` | off | a Photon-compatible geocoder for places no region covers (dev only) |
| `AUTH_HOST` | `http://localhost:4000` | Wufour, for the developer console's sign-in |
| `MAPS_PUBLIC_URL`, `TRUST_PROXY` | | the public address behind the tunnel |
| `MAPS_PUBLIC_DIR` | `public` | the web build to serve (use `zig-out/web`) |

## Running it (like the npm scripts)

| Command | Like | What it does |
|---|---|---|
| `zig build dev` (or `local`) | `npm run dev` | builds, then runs on this machine in the window, with `../Maps-js/.env.local` (Ctrl+C stops it) |
| `zig build staging` | `npm run staging` | builds, then runs maps.wreseal.com in this window with `../Maps-js/.env.staging` (Ctrl+C stops it; `tools\run.ps1 -Mode staging -Background` starts it hidden instead) |
| `zig build production` | `npm start` | builds the Linux server and pages into `zig-out/production` and prints how to run them on Proxmox with `.env.production` |

All three run `tools/run.ps1` (`powershell -File tools\run.ps1 -Mode local|staging|production` does the same).
Staging runs behind Cloudflare Tunnel on this laptop: keep its window open (and Wufour's
`npm run staging`) while people use it. Roll back to Node: stop `maps-server.exe` and run
`npm run staging` in Maps-js.

## Tests

- `zig build test`
- `tests/parity`: the same requests against Maps-js and this server must give the same answers
  (`node --test tests/parity`).
- iOS: `.github/workflows/ios.yml` builds and runs the app in the simulator on every push and
  uploads screenshots.
