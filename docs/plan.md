# Plan: web proof of concept, first screen

Read `docs/decisions.md` first. It explains why the web version is throwaway and the real app will be native iOS.

## Current direction (supersedes the rest of this file where they differ)

- **Three modes, as tabs at the bottom: Rider (the default), Driver and Horse.** The last tab used is remembered.
- **Rider use case:** commuters checking when the next train reaches their station.
  - The map shows live trains, stations and your location, with no crossings or traffic.
  - A card at the bottom shows your nearest station: its name, then Northbound, then Southbound. Each direction shows the next train big (minutes away, or a clock time past an hour, live or scheduled, and how late), its destination, and the two scheduled trains after it. At the ends of the line the card shows only the direction you can go: Windsor has no Northbound row, Larkspur no Southbound row.
  - Tap a station on the map to see its trains instead. Tap elsewhere to go back to the nearest one.
  - **Location and the camera:** the camera moves once per locate, not once per fix.
    - A fix less accurate than 1.5 km (an IP-based guess, which a Mac without GPS often gives, e.g. Portola) never moves the map.
    - The precise fix re-frames only if it lands more than 300 m from where the map framed, and only if you haven't moved or tapped the map, the card or a tab since.
    - More than 30 miles from every station, the map shows the whole line (not a view stretched to include you), and the card asks you to tap a station.
  - **Rider zoom** stops at 13.5, where trains are still the big arrows. Closer in they become small 3D models that are hard to read.
  - **Default framing:** you, your nearest station, and the next northbound and southbound trains to reach it (if they're already on the line), all fitted above the card and map buttons in the 45° tilted view.
  - Tap the Northbound or Southbound row to frame just the station and that direction's next train (or, if it hasn't set off yet, the stop it leaves from). Every other train dims so you can tell which one it is. The other row fades back. Tap the row again, or anywhere on the map, to go back to both trains.
- **Horse use case:** made for one rider whose horses get scared by passing trains. It shows when the next train passes the bit of track nearest you, and which way it's going.
  - The point is your location snapped to the nearest point on the track, marked on the map with a small orange dot.
  - The card lists the next three trains to pass that point, whichever way they're going, soonest first: "1. 2m Northbound", "2. 8m Northbound", "3. 16m Southbound". Past an hour it reads "1h 15m". "Now" from 30 s before a train passes until 20 s after.
  - **Framing:** just you and the next train to pass the track near you, in either direction. If it hasn't set off yet, you and the station it leaves from; with no more trains today, you and the track point.
  - **No interactivity:** nothing on the card or map can be tapped.
- **Driver use case:** before driving, check whether a SMART train is about to block the road crossings near you, so you don't get stuck at a lowered gate.
- **The Driver screen shows only:** a map with live trains, your location, and the crossings near you that a train will block soon (and when). No station panel, no replay or speed controls, nothing else unless the user asks.
- **The user is the designer.** Ask before deciding anything visual or behavioral (what shows, colors, wording, thresholds, layout). Build only what was asked, then show it as soon as there is something to look at.
- **Ask before adding features.** Show the user work early, even unfinished.
- **Hosting:** GitHub Pages from `main` (https://spencereholtaway.github.io/don-t-get-smart-trained/). The app is `web/app/`.
  - https://www.holtawaydesign.com/smart/ shows the same app. The holtawaydesign site (Netlify) proxies GitHub Pages there, so it updates when Pages deploys. Allow up to 10 minutes of caching. If a Pages deploy fails, re-run it or push another commit to `main`.
- **Live data:** a Cloudflare Worker holds `API_511_KEY`, polls 511 within the Rule zero budget, caches, and serves JSON to the page. Deploy it with `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from the environment.
- **Crossing locations:** OpenStreetMap level crossings on the SMART line, fetched once from `overpass-api.de` and saved into the app data.
- **Next steps, in order:** (1) deploy the Worker and make the map live, (2) add crossings near you, (3) show the user and stop.

**Goal:** a phone-sized web page with a map that shows the user's current location plus all the SMART train data 511.org provides.

---

## Rule zero: be careful with the 511 API key

`API_511_KEY` is a **dedicated development key**, separate from the key behind MyBusSF (the user's live, paid App Store app). **Never use MyBusSF's key in this project.** If a key ever looks like it's shared, stop and ask the user.

The dev key still has 511.org's default limit of about 60 requests per hour, so:

1. **Request budget.** No more than **40 requests per hour**, enforced in code, which leaves headroom below the limit. Keep a counter in a file such as `web/.cache/request-log.json`. When the budget runs out, the proxy serves cached data instead of calling 511.
2. **Cache everything on disk** in `web/.cache/` (gitignored):
   - Static GTFS data (stops, routes, shapes, timetable): fetch once and reuse it for days. Only refetch when the user asks.
   - Realtime data (vehicle positions, trip updates, alerts): reuse a cached response that is less than 60 seconds old.
3. **Only the server talks to 511.** Browser tabs and reloads read from the proxy's cache, and a reload never triggers a request by itself.
4. **Live refresh is an explicit UI toggle**, polls on the schedule in "Moving trains smoothly" step 7 (never more than once every 2 minutes per feed) and turns itself off after 10 minutes.
5. **Stop on 429.** On a 429 response, stop calling 511 until the hour resets. Never retry in a loop.
6. **Tests use saved fixture files**, never the live API (see "While building and testing" below).
7. **Log every request** (time, endpoint, status) so usage can be checked.
8. **Never print, log or commit the key's value.**

### While building and testing: stay far below the limit

The 40-per-hour budget is a hard ceiling, not a target. During development, aim to use **no more than about 10 requests per hour**.

- **Offline by default.** The server starts in **fixture mode**: it serves saved responses from `web/fixtures/` and the cached static data, and makes no 511 requests. Live mode needs an explicit opt-in, for example `LIVE=1 npm run dev`.
- **Capture once, reuse many times.** When a real response is needed, fetch it once and save it as a fixture. Build and debug the UI against that fixture. Make up variants such as a delayed train, an alert or an empty feed by editing copies of real fixtures, not by calling the API again.
- **Live calls are for checking, not iterating.** Use live mode only to confirm that something works with real data, then switch back to fixture mode.
- **Dev servers must not make requests on their own.** Hot reload, file watchers, server restarts and automated browser tests (e.g. Playwright screenshots) run in fixture mode and never trigger 511 requests.
- **Say the cost first.** Before running anything in live mode, state how many requests it will make. At the end of each work session, report how many requests were used, from `/api/usage` or the request log.

---

## Phase 0: check the key (1–2 requests in total)

- Confirm `API_511_KEY` is set. Never print, log or commit its value.
- Run it with `web/scripts/capture.mjs` (`npm run capture -- static`, then `npm run capture -- tripupdates`). It enforces the budget, logs each request to `web/.cache/request-log.json` and never prints the key. `npm run usage` shows the last hour's count.
- Cloud sessions: `api.511.org` must be in the environment's allowed network domains, or the request fails without reaching 511.
- Make **one** request to download the SMART static GTFS data (operator `SA`, from the `/transit/datafeeds` endpoint), save it to `web/.cache/`, and unzip it.
- Make **one** request to a realtime feed to see what SMART actually publishes. Vehicle positions may not exist for SMART; trip updates and alerts are more likely. Save the response as a test fixture in `web/fixtures/`.
- Check the other SMART data sources too (no 511 requests needed):
  - SMART's static GTFS feed may be downloadable directly from the agency, without counting against 511's limit. Its [Mobility Database listing](https://mobilitydatabase.org/feeds/gtfs/mdb-815) shows the source URL.
  - The Mobility Database lists a SMART vehicle positions feed from Swiftly ([mdb-3224](https://mobilitydatabase.org/feeds/mdb-3224)). It needs its own Swiftly API key, sent in a header. Note what it would take to get access, but don't sign up for anything.
- Write what you find in `docs/data.md`: which feeds exist, which fields are populated, how the data is shaped and anything surprising. **This doc carries over to iOS.**

## Phase 1: proxy server

- A tiny Node server in `web/server/` that holds the key, enforces every rule in Rule zero, and serves:
  - `GET /api/static`: stations, the route line and the timetable, read from the cache.
  - `GET /api/realtime`: vehicles, predictions and alerts, from the cache or one fresh request if the budget allows. The response also says how old the data is.
  - `GET /api/usage`: requests made in the last hour, compared with the budget.
- The key is read from `web/.env` (gitignored). Add a `web/.env.example` without the real key.

## Phase 2: the map screen

- A phone-sized layout (about 390×844), so it maps to an iPhone screen.
- **Map: smooth and lightly 3D.** Use **MapLibre GL JS**, which is free and open source, renders on the GPU, and supports tilt and rotation. Don't use Leaflet, which is flat and slower when panning and zooming. For map tiles, use a free vector source that needs no key and includes building heights, such as [OpenFreeMap](https://openfreemap.org). Check its usage terms first.
  - **Light 3D:** a gentle default tilt (about 40–50°), low-key 3D buildings that fade in only when zoomed in, and optionally soft hillshading for the valley terrain. OpenFreeMap has building heights but no elevation tiles, so hillshading needs a separate free DEM source with no key, such as the Terrarium tiles on AWS Open Data. Skip it if that adds friction. Keep it understated: the trains and stations are the focus, not the scenery.
  - **Smooth interaction:** pinch to zoom, two-finger rotate and tilt, flick panning with momentum, and animated camera moves (`flyTo`/`easeTo`) when tapping a station, centering on the user or following a train. Avoid instant jumps.
  - **Draw trains, stations and the route as map layers, not HTML markers.** Trains are a GeoJSON source updated every animation frame, which works fine for SMART's handful of trains. This keeps everything at 60fps and lets trains tilt and rotate with the map. Point each train icon in its direction of travel along the track.
  - **Polish:** a subtle pulse on the user's location, and a soft glow or animated dash on the route line. Keep the mood calm, not busy.
  - **Performance:** must feel smooth on a phone-sized viewport. Test on a real phone browser if possible, not just a desktop.
  - This maps directly to iOS: MapKit has the same tilt, 3D buildings and camera animation, so whatever camera angles and gestures feel right here can carry over. Write down the camera settings that work, such as tilt, zoom levels and animation durations, in `docs/`.
- On the map:
  - The user's current location, from the browser's geolocation (with a prompt and a fallback if the user says no)
  - The SMART route line
  - All stations, where tapping one shows its next arrivals (scheduled and predicted)
  - Live train positions, if SMART publishes them; otherwise trains placed by interpolating between stops, clearly labeled as estimates
  - Service alerts in a banner or list
- A small status line showing how old the data is ("updated 40s ago"), the live-refresh toggle, and the request count from `/api/usage`.
- Keep it scrappy. This code gets thrown away. The **approach to moving trains below is worth getting right**, though, because it carries over to iOS. Write it up in `docs/train-motion.md`.

### Moving trains smoothly with few requests

The idea: **the timetable moves the trains, and live data only nudges them.** A train's position is calculated from the clock every frame, so trains move smoothly even with no new data. Live updates only adjust how late each train is.

1. **Work along the track, not in lat/lon.** Build one line along the track from GTFS `shapes.txt` and precompute the distance of each point along it. Place each station at its distance along that line. A train's position is then a single number, its distance along the track, which gets converted to a map point when drawing. That way trains follow the curves instead of cutting across them.
2. **Use the timetable as the baseline.** For each trip, `stop_times.txt` says when the train leaves station A and arrives at station B. At time `t`, the train is between those stations. Use an ease-in/ease-out curve, not a straight line, so it speeds up from A and slows into B. It waits at each station for the scheduled dwell time. **This needs no requests at all.**
3. **Live data sets a delay for each trip.** A trip update gives a predicted delay at the next stops. Position = timetable position at `t − delay`. If the feed has vehicle positions, project the GPS point onto the track and convert it into an implied delay. Don't snap the train to the raw GPS point, because GPS is noisy.
4. **Blend corrections instead of jumping.** Keep a *displayed* delay and a *target* delay. When new data arrives, only the target changes. The displayed delay moves toward it over about 20–30 seconds, so the train looks like it's speeding up or slowing down.
5. **Being right beats never moving backward.** Small backward steps (under about 40 m, the jitter of predictions updating) are held. A real correction is not: when live data says a train is running late after it was drawn on time, it eases back to where it really is within a second or two.
   - Why: holding instead hid a train that was 5 minutes late. On Nov 6 at 4:52 PM, the late northbound was at 4th St in San Rafael, and the app drew it frozen at Marin Civic Center, 2.7 km ahead, where the timetable said it should be. A driver got stopped by a train the app didn't show there.
6. **Show uncertainty as data ages.** Fresh data looks solid. As it gets older, keep using the last known delay but show the train as an estimate (faded marker, "estimated" label). After about 10 minutes without data, fall back to the plain timetable and say so.
7. **Each refresh is one request per feed, covering all trains.** Each 511 realtime feed (e.g. trip updates, filtered to `agency=SA`) returns every SMART train in one response, but each feed is a separate request, so poll them on different schedules and only while the page is visible:
   - **Trip updates:** every 2–5 minutes (12–30 requests per hour). This is the feed that drives delays.
   - **Service alerts:** every 15 minutes (4 per hour). Alerts change rarely.
   - **Vehicle positions:** only if Phase 0 shows SMART publishes them, and then *instead of* trip updates on alternate refreshes, not in addition to them.

   Worst case that's about 34 requests per hour, under the 40 ceiling. During development the 10-per-hour target still applies, which in practice means live mode runs for a few minutes at a time, not continuously. Zero in fixture mode.

Test it in fixture mode with a fake clock: speed time up, make up delays, and swap fixtures to simulate a new update arriving. Check that trains don't jitter, and that a late train is drawn where it really is.

## Phase 3: write down what we learned

- Update `docs/` with the screen layout, the interactions, the data quirks and what worked or didn't. That's what carries over to the native iOS build.

---

## Who runs what

**The user never needs a terminal.** Claude runs every command: installs, the capture script, the dev server, tests and screenshots. The user only looks at results (screenshots or a shared link) and gives feedback. Don't hand the user shell commands. The only thing Claude can't do itself is change the cloud environment's settings (such as allowed network domains); for those, give the user the exact clicks.

## Out of scope for now
- Accounts, notifications, favorites, trip planning
- Any production hosting. If we ever host the prototype, the request budget and cache must stay server-side.
