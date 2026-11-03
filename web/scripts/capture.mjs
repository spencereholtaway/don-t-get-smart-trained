// Phase 0: capture real 511 responses once, so everything else runs offline.
//   node scripts/capture.mjs static        -> 1 request: SMART GTFS zip into .cache/gtfs/
//   node scripts/capture.mjs tripupdates   -> 1 request: fixture in fixtures/
//   node scripts/capture.mjs vehiclepositions | servicealerts  -> 1 request each
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import GtfsRealtimeBindings from 'gtfs-realtime-bindings';
import { call511, usage, CACHE_DIR, FIXTURES_DIR } from '../lib/api511.mjs';

process.on('uncaughtException', (e) => { console.error(e.message); process.exit(1); });

const REALTIME = ['tripupdates', 'vehiclepositions', 'servicealerts'];
const what = process.argv[2];
if (what !== 'static' && !REALTIME.includes(what)) {
  console.error(`Usage: node scripts/capture.mjs <static|${REALTIME.join('|')}>`);
  process.exit(1);
}

console.log(`This makes 1 request to 511. Usage before: ${JSON.stringify(usage())}`);

if (what === 'static') {
  const { status, body } = await call511('datafeeds', { operator_id: 'SA' });
  if (status !== 200) fail(status, body);
  const dir = path.join(CACHE_DIR, 'gtfs');
  fs.mkdirSync(dir, { recursive: true });
  const zip = path.join(CACHE_DIR, 'gtfs-SA.zip');
  fs.writeFileSync(zip, body);
  execFileSync('unzip', ['-o', '-q', zip, '-d', dir]);
  console.log(`Saved ${body.length} bytes; unzipped into ${dir}:`);
  for (const f of fs.readdirSync(dir)) console.log(`  ${f}  ${fs.statSync(path.join(dir, f)).size} bytes`);
} else {
  const { status, body, headers } = await call511(what, { agency: 'SA' });
  if (status !== 200) fail(status, body);
  fs.mkdirSync(FIXTURES_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const base = path.join(FIXTURES_DIR, `${what}-${stamp}`);
  fs.writeFileSync(`${base}.pb`, body);
  let decoded;
  try {
    decoded = GtfsRealtimeBindings.transit_realtime.FeedMessage.toObject(
      GtfsRealtimeBindings.transit_realtime.FeedMessage.decode(body),
      { longs: Number, enums: String, defaults: false },
    );
  } catch (e) {
    console.log(`Not protobuf (content-type ${headers['content-type']}); first bytes:\n${body.subarray(0, 300)}`);
    process.exit(0);
  }
  fs.writeFileSync(`${base}.json`, JSON.stringify(decoded, null, 2));
  console.log(`Saved ${base}.pb and .json: ${decoded.entity?.length ?? 0} entities.`);
}

console.log(`Usage after: ${JSON.stringify(usage())}`);

function fail(status, body) {
  console.error(`511 returned ${status}: ${body.subarray(0, 300)}`);
  if (status === 429) console.error('Stopping. No further 511 calls this hour.');
  process.exit(1);
}
