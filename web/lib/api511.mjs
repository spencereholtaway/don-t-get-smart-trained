// The only code allowed to call 511.org. Enforces Rule zero in docs/plan.md:
// a 40-requests-per-hour budget, a log of every request, a stop after any 429,
// and the key never printed, logged or saved.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const CACHE_DIR = path.join(WEB_DIR, '.cache');
export const FIXTURES_DIR = path.join(WEB_DIR, 'fixtures');
const LOG_FILE = path.join(CACHE_DIR, 'request-log.json');

export const HOURLY_BUDGET = 40;
const HOUR_MS = 60 * 60 * 1000;
const BASE = 'https://api.511.org/transit';

function loadKey() {
  if (process.env.API_511_KEY) return process.env.API_511_KEY.trim();
  const envFile = path.join(WEB_DIR, '.env');
  if (fs.existsSync(envFile)) {
    const m = fs.readFileSync(envFile, 'utf8').match(/^API_511_KEY=(.*)$/m);
    if (m && m[1].trim()) return m[1].trim();
  }
  throw new Error('API_511_KEY is not set (env var or web/.env).');
}

function readLog() {
  try { return JSON.parse(fs.readFileSync(LOG_FILE, 'utf8')); } catch { return []; }
}

function writeLog(log) {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  fs.writeFileSync(LOG_FILE, JSON.stringify(log, null, 2));
}

export function usage(now = Date.now()) {
  const lastHour = readLog().filter((e) => now - Date.parse(e.time) < HOUR_MS);
  const last429 = lastHour.filter((e) => e.status === 429).at(-1);
  return {
    usedLastHour: lastHour.length,
    budget: HOURLY_BUDGET,
    remaining: Math.max(0, HOURLY_BUDGET - lastHour.length),
    blockedUntil: last429 ? new Date(Date.parse(last429.time) + HOUR_MS).toISOString() : null,
  };
}

// endpoint: e.g. 'datafeeds', 'tripupdates'. params: query params, without the key.
// Returns { status, body: Buffer, headers }. Throws if the budget or a 429 forbids the call.
export async function call511(endpoint, params) {
  const u = usage();
  if (u.blockedUntil) throw new Error(`511 returned 429 recently; no calls until ${u.blockedUntil}.`);
  if (u.remaining <= 0) throw new Error(`Hourly budget of ${HOURLY_BUDGET} requests is used up.`);

  const key = loadKey();
  const query = new URLSearchParams({ ...params, api_key: key });
  const safeParams = new URLSearchParams(params).toString();
  const entry = { time: new Date().toISOString(), endpoint, params: safeParams, status: null };

  const log = readLog();
  log.push(entry);
  writeLog(log); // log before the call, so a crash still counts against the budget

  try {
    const res = await fetch(`${BASE}/${endpoint}?${query}`);
    const body = Buffer.from(await res.arrayBuffer());
    entry.status = res.status;
    entry.bytes = body.length;
    writeLog(log);
    return { status: res.status, body, headers: Object.fromEntries(res.headers) };
  } catch (err) {
    entry.status = 'network-error';
    writeLog(log);
    // Never let the key leak through an error message.
    throw new Error(`Request to 511 ${endpoint} failed: ${String(err?.cause?.code || err.message).replaceAll(key, '***')}`);
  }
}
