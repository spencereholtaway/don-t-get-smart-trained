// SMART live data proxy. The only place that talks to 511.org from the hosted app.
// Enforces Rule zero (docs/plan.md) server-side, so no number of open tabs can
// raise 511 usage:
//   - 40 requests per rolling hour, hard ceiling, counted in a Durable Object
//   - each feed fetched at most once per interval, and only when someone asks
//   - any 429 stops all calls for an hour
//   - every request logged (time, feed, status); the key is never logged or returned
import GtfsRealtimeBindings from 'gtfs-realtime-bindings';
import { shapeTripUpdates, shapeVehicles, shapeAlerts } from './shape.js';

const HOUR_MS = 3600_000;
const HOURLY_BUDGET = 40;
// Worst case 15 + 15 + 4 = 34 requests per hour, under the 40 ceiling.
const FEEDS = {
  tripupdates: { everyMs: 4 * 60_000, shape: shapeTripUpdates },
  vehiclepositions: { everyMs: 4 * 60_000, shape: shapeVehicles },
  servicealerts: { everyMs: 15 * 60_000, shape: shapeAlerts },
};

const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-methods': 'GET, OPTIONS' };
const json = (body, extra = {}) => new Response(JSON.stringify(body), {
  headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...CORS, ...extra },
});

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') return new Response(null, { headers: CORS });
    if (request.method !== 'GET') return new Response('Method not allowed', { status: 405, headers: CORS });
    const { pathname } = new URL(request.url);
    if (pathname === '/realtime' || pathname === '/usage') {
      const stub = env.FEEDS.get(env.FEEDS.idFromName('smart'));
      return stub.fetch(new Request(`https://do${pathname}`));
    }
    if (pathname === '/') return new Response('SMART live data. GET /realtime or /usage.\n', { headers: CORS });
    return new Response('Not found', { status: 404, headers: CORS });
  },
};

export class Feeds {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.inflight = null;
  }

  async fetch(request) {
    const { pathname } = new URL(request.url);
    if (pathname === '/usage') return json(await this.usage());
    // One refresh at a time; concurrent callers share it.
    this.inflight ??= this.refresh().finally(() => { this.inflight = null; });
    await this.inflight;
    const out = {};
    for (const name of Object.keys(FEEDS)) Object.assign(out, (await this.ctx.storage.get(`feed:${name}`))?.data ?? FEEDS[name].shape(null));
    out.fetchedAt = Object.fromEntries(await Promise.all(Object.keys(FEEDS).map(async (n) => [n, (await this.ctx.storage.get(`feed:${n}`))?.at ?? null])));
    out.servedAt = Date.now();
    return json(out);
  }

  async log() { return (await this.ctx.storage.get('log')) ?? []; }

  async usage(now = Date.now()) {
    const lastHour = (await this.log()).filter((e) => now - e.time < HOUR_MS);
    const last429 = lastHour.filter((e) => e.status === 429).at(-1);
    return {
      usedLastHour: lastHour.length,
      budget: HOURLY_BUDGET,
      remaining: Math.max(0, HOURLY_BUDGET - lastHour.length),
      blockedUntil: last429 ? new Date(last429.time + HOUR_MS).toISOString() : null,
      recent: lastHour.map((e) => ({ time: new Date(e.time).toISOString(), feed: e.feed, status: e.status })),
    };
  }

  async refresh() {
    const now = Date.now();
    for (const [name, feed] of Object.entries(FEEDS)) {
      const cached = await this.ctx.storage.get(`feed:${name}`);
      if (cached && now - cached.at < feed.everyMs) continue;
      const u = await this.usage(now);
      if (u.blockedUntil || u.remaining <= 0) return; // serve what we have
      await this.call(name, feed);
    }
  }

  async call(name, feed) {
    const key = this.env.API_511_KEY;
    if (!key) throw new Error('API_511_KEY secret is not set');
    const entry = { time: Date.now(), feed: name, status: null };
    // Log before the call so a crash still counts against the budget. Keep a day of history.
    const log = (await this.log()).filter((e) => entry.time - e.time < 24 * HOUR_MS);
    log.push(entry);
    await this.ctx.storage.put('log', log);

    const base = this.env.UPSTREAM_511 || 'https://api.511.org/transit';
    try {
      const res = await fetch(`${base}/${name}?agency=SA&api_key=${encodeURIComponent(key)}`);
      entry.status = res.status;
      await this.ctx.storage.put('log', log);
      console.log(`511 ${name} -> ${res.status}`);
      if (res.status !== 200) return;
      const buf = new Uint8Array(await res.arrayBuffer());
      const T = GtfsRealtimeBindings.transit_realtime.FeedMessage;
      const decoded = T.toObject(T.decode(buf), { longs: Number, enums: String, defaults: false });
      await this.ctx.storage.put(`feed:${name}`, { at: Date.now(), data: feed.shape(decoded) });
    } catch (err) {
      if (entry.status == null) entry.status = 'network-error';
      else entry.status = `decode-error ${entry.status}`;
      await this.ctx.storage.put('log', log);
      // Never let the key leak through an error message.
      console.log(`511 ${name} failed: ${String(err?.message ?? err).replaceAll(key, '***')}`);
    }
  }
}
