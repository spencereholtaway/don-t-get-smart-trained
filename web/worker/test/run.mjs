// Runs the Worker locally (wrangler dev) against a fake 511 that serves the saved
// fixtures in web/fixtures/. Makes no real 511 requests.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const here = path.dirname(fileURLToPath(import.meta.url));
const FIX = path.resolve(here, '../../fixtures');
const newest = (p) => fs.readdirSync(FIX).filter((n) => n.startsWith(p) && n.endsWith('.pb')).sort().at(-1);

let hits = [], mode = 'ok';
const fake = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  const feed = u.pathname.split('/').pop();
  hits.push({ feed, key: u.searchParams.get('api_key'), agency: u.searchParams.get('agency') });
  if (mode === '429') { res.writeHead(429); return res.end('slow down'); }
  res.writeHead(200, { 'content-type': 'application/octet-stream' });
  res.end(fs.readFileSync(path.join(FIX, newest(feed))));
}).listen(0);
const fakePort = fake.address().port;
const port = 8790;
fs.rmSync(path.join(here, '../.wrangler/state'), { recursive: true, force: true });
const dev = spawn(path.resolve(here, '../node_modules/.bin/wrangler'), ['dev', '--port', String(port), '--ip', '127.0.0.1', '--var', `UPSTREAM_511:http://127.0.0.1:${fakePort}/transit`, '--var', 'API_511_KEY:test-key'],
  { detached: true, cwd: path.resolve(here, '..'), stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } });
let out = '';
dev.stdout.on('data', (d) => (out += d)); dev.stderr.on('data', (d) => (out += d));
const get = async (p) => (await fetch(`http://127.0.0.1:${port}${p}`)).json();

try {
  for (let i = 0; ; i++) {
    try { await fetch(`http://127.0.0.1:${port}/`); break; } catch { if (i > 120) throw new Error('wrangler dev did not start:\n' + out); await new Promise((r) => setTimeout(r, 500)); }
  }
  const a = await get('/realtime');
  assert.equal(hits.length, 3, 'first call fetches each feed once');
  assert.ok(hits.every((h) => h.key === 'test-key' && h.agency === 'SA'));
  assert.ok(a.tripUpdates.length > 0 && a.tripUpdatesAt, 'trip updates decoded');
  assert.ok(a.vehicles.length > 0 && a.vehicles.every((v) => v.trip), 'vehicles decoded');
  assert.ok(Array.isArray(a.alerts));
  assert.ok(!JSON.stringify(a).includes('test-key'), 'key never in response');

  await Promise.all([get('/realtime'), get('/realtime'), get('/realtime')]);
  assert.equal(hits.length, 3, 'cached: no more upstream calls');

  const u = await get('/usage');
  assert.equal(u.usedLastHour, 3);
  assert.equal(u.budget, 40);
  assert.ok(!JSON.stringify(u).includes('test-key'));
  if (process.env.KEEP) { console.log(`worker running on ${port}; fake upstream on ${fakePort}`); await new Promise(() => {}); }
  console.log(`ok: ${a.tripUpdates.length} trip updates, ${a.vehicles.length} trains with GPS, ${a.alerts.length} alerts; usage ${u.usedLastHour}/${u.budget}`);
} finally {
  try { process.kill(-dev.pid, 'SIGTERM'); } catch {}
  fake.close();
}
