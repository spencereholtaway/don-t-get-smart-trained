// One-time pull: finds where drivable roads cross the SMART tracks at the same level
// (neither on a bridge nor in a tunnel), using OpenFreeMap's OpenStreetMap vector tiles,
// and saves them into app/data.json as `crossings`. Makes no 511 requests.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { VectorTile } from '@mapbox/vector-tile';
import Pbf from 'pbf';

const DATA = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../app/data.json');
const data = JSON.parse(fs.readFileSync(DATA, 'utf8'));
const Z = 14;
const ROADS = new Set(['motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'minor']);
const ARM_M = 250; // how far along the street, each way from the crossing, to keep for the traffic heat

const tileOf = (lon, lat) => {
  const n = 2 ** Z, r = (lat * Math.PI) / 180;
  return [Math.floor(((lon + 180) / 360) * n), Math.floor(((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2) * n)];
};

// Tiles along both directions' track, sampled densely so no tile is skipped.
const tiles = new Set();
for (const pts of Object.values(data.shapes)) {
  for (let i = 0; i < pts.length - 1; i++) {
    const [a, b] = [pts[i], pts[i + 1]];
    const steps = Math.max(1, Math.ceil(Math.hypot(b[0] - a[0], b[1] - a[1]) / 0.0005));
    for (let s = 0; s <= steps; s++) tiles.add(tileOf(a[0] + ((b[0] - a[0]) * s) / steps, a[1] + ((b[1] - a[1]) * s) / steps).join('/'));
  }
}

const tilejson = await (await fetch('https://tiles.openfreemap.org/planet')).json();
const template = tilejson.tiles[0];
console.log(`${tiles.size} tiles from ${template}`);

// Local planar coordinates in meters around the line's latitude.
const LAT0 = 38.2, KX = 111320 * Math.cos((LAT0 * Math.PI) / 180), KY = 110540;
const xy = ([lon, lat]) => [lon * KX, lat * KY];
const lonlat = ([x, y]) => [x / KX, y / KY];

function lines(geom) {
  const ls = geom.type === 'LineString' ? [geom.coordinates] : geom.type === 'MultiLineString' ? geom.coordinates : [];
  return ls.map((l) => l.map(xy));
}
// Walk from the hit point along the road line (from segment i) up to ARM_M, in one direction.
function walk(line, i, hit, dir) {
  const out = [hit];
  let len = 0, prev = hit, j = dir > 0 ? i + 1 : i;
  while (j >= 0 && j < line.length) {
    const p = line[j], d = Math.hypot(p[0] - prev[0], p[1] - prev[1]);
    if (len + d >= ARM_M) { const f = (ARM_M - len) / d; out.push([prev[0] + (p[0] - prev[0]) * f, prev[1] + (p[1] - prev[1]) * f]); len = ARM_M; break; }
    out.push(p); len += d; prev = p; j += dir;
  }
  return { pts: out, len };
}
function segs(geom) {
  const lines = geom.type === 'LineString' ? [geom.coordinates] : geom.type === 'MultiLineString' ? geom.coordinates : [];
  const out = [];
  for (const l of lines) for (let i = 0; i < l.length - 1; i++) out.push([xy(l[i]), xy(l[i + 1])]);
  return out;
}
function intersect([p, p2], [q, q2]) {
  const r = [p2[0] - p[0], p2[1] - p[1]], s = [q2[0] - q[0], q2[1] - q[1]];
  const d = r[0] * s[1] - r[1] * s[0];
  if (Math.abs(d) < 1e-9) return null;
  const t = ((q[0] - p[0]) * s[1] - (q[1] - p[1]) * s[0]) / d, u = ((q[0] - p[0]) * r[1] - (q[1] - p[1]) * r[0]) / d;
  return t >= 0 && t <= 1 && u >= 0 && u <= 1 ? [p[0] + t * r[0], p[1] + t * r[1]] : null;
}
const shapeSegs = Object.values(data.shapes).flatMap((pts) => segs({ type: 'LineString', coordinates: pts.map((p) => [p[0], p[1]]) }));
function distToShape(pt) {
  let best = Infinity;
  for (const [a, b] of shapeSegs) {
    const L = (b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2;
    const u = L ? Math.max(0, Math.min(1, ((pt[0] - a[0]) * (b[0] - a[0]) + (pt[1] - a[1]) * (b[1] - a[1])) / L)) : 0;
    best = Math.min(best, Math.hypot(a[0] + (b[0] - a[0]) * u - pt[0], a[1] + (b[1] - a[1]) * u - pt[1]));
  }
  return best;
}

const found = [];
const list = [...tiles];
for (let i = 0; i < list.length; i += 8) {
  await Promise.all(list.slice(i, i + 8).map(async (key) => {
    const [x, y] = key.split('/').map(Number);
    const res = await fetch(template.replace('{z}', Z).replace('{x}', x).replace('{y}', y));
    if (!res.ok) throw new Error(`tile ${key}: ${res.status}`);
    const layer = new VectorTile(new Pbf(new Uint8Array(await res.arrayBuffer()))).layers.transportation;
    if (!layer) return;
    const rails = [], roads = [];
    for (let f = 0; f < layer.length; f++) {
      const feat = layer.feature(f), p = feat.properties;
      if (p.brunnel) continue; // bridges and tunnels don't block traffic
      const g = feat.toGeoJSON(x, y, Z).geometry;
      if (p.class === 'rail') rails.push(...segs(g));
      else if (ROADS.has(p.class) && p.ramp !== 1) roads.push({ cls: p.class, lines: lines(g) });
    }
    for (const rs of rails) for (const road of roads) for (const line of road.lines) for (let k = 0; k < line.length - 1; k++) {
      const hit = intersect(rs, [line[k], line[k + 1]]);
      if (hit && distToShape(hit) < 30) found.push({ pt: hit, road: road.cls, arms: [walk(line, k, hit, 1), walk(line, k, hit, -1)].filter((a) => a.len > 5) });
    }
  }));
}

// The same crossing shows up in neighboring tiles and on parallel tracks: merge within 40 m.
// Arms from duplicates are merged: per direction (bearing within 30 degrees), keep the longest
// (a tile edge can cut a street short in one tile but not the next).
const crossings = [];
const bearingOf = (a) => { const [p, q] = [a.pts[0], a.pts[Math.min(a.pts.length - 1, 1)]]; return Math.atan2(q[0] - p[0], q[1] - p[1]); };
for (const f of found) {
  const c = crossings.find((c) => Math.hypot(c.pt[0] - f.pt[0], c.pt[1] - f.pt[1]) < 40);
  if (!c) { crossings.push({ ...f, arms: [...f.arms] }); continue; }
  for (const a of f.arms) {
    const same = c.arms.findIndex((b) => { const d = Math.abs(bearingOf(a) - bearingOf(b)) % (2 * Math.PI); return Math.min(d, 2 * Math.PI - d) < Math.PI / 6; });
    if (same < 0) c.arms.push(a);
    else if (a.len > c.arms[same].len) c.arms[same] = a;
  }
}
const r5 = (n) => Math.round(n * 1e5) / 1e5;
data.crossings = crossings.map((c, i) => {
  const [lon, lat] = lonlat(c.pt);
  // arms: street lines leading away from the crossing, [lon, lat] points starting at the crossing
  return { id: i + 1, lat: r5(lat), lon: r5(lon), road: c.road, arms: c.arms.map((a) => a.pts.map((p) => lonlat(p).map(r5))) };
}).sort((a, b) => b.lat - a.lat);
data.crossingsSource = `OpenStreetMap via OpenFreeMap tiles (${template.split('/')[4]}), roads crossing rail at grade`;
fs.writeFileSync(DATA, JSON.stringify(data));
const byClass = {};
for (const c of data.crossings) byClass[c.road] = (byClass[c.road] ?? 0) + 1;
console.log(`${data.crossings.length} crossings`, byClass, `arms per crossing: ${(data.crossings.reduce((n, c) => n + c.arms.length, 0) / data.crossings.length).toFixed(1)}`);
