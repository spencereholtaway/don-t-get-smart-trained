// Turns the cached SMART GTFS + the newest realtime fixtures into app/data.json,
// the single data file the map page reads. Makes no network requests.
import fs from 'node:fs';
import path from 'node:path';
import { CACHE_DIR, FIXTURES_DIR } from '../lib/api511.mjs';
import { shapeTripUpdates, shapeVehicles, shapeAlerts } from '../worker/src/shape.js';

const GTFS = path.join(CACHE_DIR, 'gtfs');
const OUT = path.resolve(CACHE_DIR, '..', 'app', 'data.json');

function csv(file) {
  const [head, ...rows] = fs.readFileSync(path.join(GTFS, file), 'utf8').trim().split(/\r?\n/);
  const keys = head.split(',');
  // SMART's files have no quoted commas except in stop_desc, which we drop.
  return rows.map((line) => {
    const cells = [];
    let cur = '', q = false;
    for (const ch of line) {
      if (ch === '"') q = !q;
      else if (ch === ',' && !q) { cells.push(cur); cur = ''; }
      else cur += ch;
    }
    cells.push(cur);
    return Object.fromEntries(keys.map((k, i) => [k, cells[i] ?? '']));
  });
}
const sec = (t) => { const [h, m, s] = t.split(':').map(Number); return h * 3600 + m * 60 + s; };
const r5 = (n) => Math.round(n * 1e5) / 1e5;

// Stations: parent stations, with their platform stop_ids mapped back to them.
const stops = csv('stops.txt');
const platformToStation = {};
const stations = stops.filter((s) => s.location_type === '1').map((s) => ({
  id: s.stop_id,
  name: s.stop_name.replace(/^SMART /, ''),
  lat: r5(+s.stop_lat), lon: r5(+s.stop_lon),
}));
for (const s of stops) if (s.parent_station) platformToStation[s.stop_id] = s.parent_station;

// Shapes: one polyline per direction with cumulative distance in meters.
const shapes = {};
for (const p of csv('shapes.txt')) {
  (shapes[p.shape_id] ??= []).push([+p.shape_pt_sequence, r5(+p.shape_pt_lon), r5(+p.shape_pt_lat), Math.round(+p.shape_dist_traveled)]);
}
for (const id in shapes) shapes[id] = shapes[id].sort((a, b) => a[0] - b[0]).map(([, lon, lat, d]) => [lon, lat, d]);

// Trips with stop times: [stationId, arrSec, depSec, distMeters].
const byTrip = {};
for (const st of csv('stop_times.txt')) (byTrip[st.trip_id] ??= []).push(st);
const trips = csv('trips.txt').map((t) => ({
  id: t.trip_id,
  name: t.trip_short_name,
  headsign: t.trip_headsign,
  dir: +t.direction_id, // 1 = north, 0 = south
  service: t.service_id,
  shape: t.shape_id,
  stops: byTrip[t.trip_id]
    .sort((a, b) => a.stop_sequence - b.stop_sequence)
    .map((s) => [platformToStation[s.stop_id] ?? s.stop_id, sec(s.arrival_time), sec(s.departure_time), Math.round(+s.shape_dist_traveled)]),
})).sort((a, b) => a.stops[0][1] - b.stops[0][1]);

const calendar = csv('calendar.txt').map((c) => ({
  service: c.service_id,
  days: ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'].map((d) => c[d] === '1'),
  start: c.start_date, end: c.end_date,
}));
const exceptions = csv('calendar_dates.txt').map((c) => ({ service: c.service_id, date: c.date, add: c.exception_type === '1' }));

// Realtime: newest fixture of each feed.
function newest(prefix) {
  const f = fs.readdirSync(FIXTURES_DIR).filter((n) => n.startsWith(prefix) && n.endsWith('.json')).sort().at(-1);
  return f ? JSON.parse(fs.readFileSync(path.join(FIXTURES_DIR, f), 'utf8')) : null;
}
const tu = newest('tripupdates');
const vp = newest('vehiclepositions');
const sa = newest('servicealerts');

const realtime = { ...shapeTripUpdates(tu), ...shapeVehicles(vp), ...shapeAlerts(sa) };

// Keep crossings from scripts/build-crossings.mjs.
const previous = fs.existsSync(OUT) ? JSON.parse(fs.readFileSync(OUT, 'utf8')) : {};
const data = { crossings: previous.crossings, crossingsSource: previous.crossingsSource, builtAt: new Date().toISOString(), timezone: 'America/Los_Angeles', routeColor: '#4d6d51', stations, shapes, trips, calendar, exceptions, realtime };
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(data));
console.log(`Wrote ${OUT}: ${(fs.statSync(OUT).size / 1024).toFixed(0)} KB, ${stations.length} stations, ${trips.length} trips, ${realtime.tripUpdates.length} trip updates, ${realtime.vehicles.length} trains with GPS, ${realtime.alerts.length} alerts.`);
