// Downloads OpenFreeMap vector tiles along the SMART corridor and packs them,
// plus the label font, into app/map-pack.bin (gzip). The page can't reach
// tile servers from inside an artifact, so it reads tiles from this pack.
// Tiles are cached in .cache/tiles, so reruns fetch only what's missing.
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { CACHE_DIR } from '../lib/api511.mjs';

const OUT = path.resolve(CACHE_DIR, '..', 'app', 'map-pack.bin');
const TILE_CACHE = path.join(CACHE_DIR, 'tiles');
const data = JSON.parse(fs.readFileSync(path.resolve(CACHE_DIR, '..', 'app', 'data.json'), 'utf8'));

// Which layers the page's style uses. Everything else is dropped to keep the pack small.
const KEEP = new Set(['water', 'waterway', 'landcover', 'landuse', 'park', 'transportation', 'transportation_name', 'building', 'place', 'water_name', 'aeroway']);
// Zoom -> buffer around the track in meters. Low zooms cover the whole corridor box.
const BUFFER = { 6: 60000, 7: 60000, 8: 40000, 9: 30000, 10: 20000, 11: 12000, 12: 7000, 13: 3500, 14: 1800 };
const FONTS = ['Noto Sans Regular', 'Noto Sans Bold', 'Noto Sans Italic'];

const tilejson = await (await fetch('https://tiles.openfreemap.org/planet')).json();
const TILE_URL = tilejson.tiles[0];

const lon2x = (lon, z) => Math.floor(((lon + 180) / 360) * 2 ** z);
const lat2y = (lat, z) => { const r = (lat * Math.PI) / 180; return Math.floor(((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2) * 2 ** z); };

const points = Object.values(data.shapes).flat().filter((_, i) => i % 5 === 0);
const want = new Set();
for (const [zs, buf] of Object.entries(BUFFER)) {
  const z = +zs;
  for (const [lon, lat] of points) {
    const dLat = buf / 111320, dLon = buf / (111320 * Math.cos((lat * Math.PI) / 180));
    for (let x = lon2x(lon - dLon, z); x <= lon2x(lon + dLon, z); x++)
      for (let y = lat2y(lat + dLat, z); y <= lat2y(lat - dLat, z); y++) want.add(`${z}/${x}/${y}`);
  }
}
console.log(`${want.size} tiles needed`);

// Minimal protobuf walk: keep only top-level layer messages (field 3) whose name is in KEEP.
function varint(buf, pos) { let v = 0, s = 0, b; do { b = buf[pos++]; v += (b & 0x7f) * 2 ** s; s += 7; } while (b & 0x80); return [v, pos]; }
function filterTile(buf) {
  const parts = [];
  let pos = 0;
  while (pos < buf.length) {
    const start = pos;
    let tag; [tag, pos] = varint(buf, pos);
    if ((tag & 7) !== 2) throw new Error('unexpected wire type');
    let len; [len, pos] = varint(buf, pos);
    const body = buf.subarray(pos, pos + len);
    pos += len;
    // layer name is field 1 (tag 0x0a) inside the layer
    let p = 0, name = '';
    while (p < body.length) {
      let t; [t, p] = varint(body, p);
      if (t === 0x0a) { let l; [l, p] = varint(body, p); name = body.subarray(p, p + l).toString(); break; }
      if ((t & 7) === 0) [, p] = varint(body, p); else if ((t & 7) === 2) { let l; [l, p] = varint(body, p); p += l; } else break;
    }
    if ((tag >> 3) === 3 && KEEP.has(name)) parts.push(buf.subarray(start, pos));
  }
  return Buffer.concat(parts);
}

async function cached(file, url) {
  const f = path.join(TILE_CACHE, file);
  if (fs.existsSync(f)) return fs.readFileSync(f);
  const res = await fetch(url);
  const body = res.status === 200 ? Buffer.from(await res.arrayBuffer()) : Buffer.alloc(0);
  if (res.status !== 200 && res.status !== 204 && res.status !== 404) throw new Error(`${url} -> ${res.status}`);
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f, body);
  return body;
}

const entries = [];
const list = [...want];
let done = 0;
async function worker() {
  while (list.length) {
    const key = list.shift();
    const [z, x, y] = key.split('/');
    const raw = await cached(`${key}.pbf`, TILE_URL.replace('{z}', z).replace('{x}', x).replace('{y}', y));
    if (raw.length) entries.push([`t/${key}`, filterTile(raw)]);
    if (++done % 100 === 0) console.log(`  ${done}/${want.size}`);
  }
}
await Promise.all(Array.from({ length: 6 }, worker));
for (const font of FONTS) {
  for (const range of ['0-255', '256-511', '8192-8447']) {
    const buf = await cached(`fonts/${font}/${range}.pbf`, `https://tiles.openfreemap.org/fonts/${encodeURIComponent(font)}/${range}.pbf`);
    entries.push([`g/${font}/${range}`, buf]);
  }
}

// Pack: 4-byte index length, JSON index {key: [offset, length]}, then the blobs.
entries.sort((a, b) => (a[0] < b[0] ? -1 : 1));
const index = {};
let off = 0;
for (const [k, b] of entries) { index[k] = [off, b.length]; off += b.length; }
const idx = Buffer.from(JSON.stringify({ tileUrl: TILE_URL, index }));
const head = Buffer.alloc(4); head.writeUInt32LE(idx.length);
const packed = zlib.gzipSync(Buffer.concat([head, idx, ...entries.map((e) => e[1])]), { level: 9 });
fs.writeFileSync(OUT, packed);
console.log(`Wrote ${OUT}: ${(packed.length / 1048576).toFixed(1)} MB gzip (${(off / 1048576).toFixed(1)} MB raw), ${entries.length} entries.`);
