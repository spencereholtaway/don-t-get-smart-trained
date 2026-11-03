# Plan: web proof of concept, first screen

Read `docs/decisions.md` first. It explains why the web version is throwaway and the real app will be native iOS.

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
4. **Live refresh is an explicit UI toggle**, refreshes at most once per minute and turns itself off after 10 minutes.
5. **Stop on 429.** On a 429 response, stop calling 511 until the hour resets. Never retry in a loop.
6. **Tests use saved fixture files**, never the live API.
7. **Log every request** (time, endpoint, status) so usage can be checked.
8. **Never print, log or commit the key's value.**

---

## Phase 0: check the key (1–2 requests in total)

- Confirm `API_511_KEY` is set. Never print, log or commit its value.
- Make **one** request to download the SMART static GTFS data (operator `SA`, from the `/transit/datafeeds` endpoint), save it to `web/.cache/`, and unzip it.
- Make **one** request to a realtime feed to see what SMART actually publishes. Vehicle positions may not exist for SMART; trip updates and alerts are more likely. Save the response as a test fixture in `web/fixtures/`.
- Write what you find in `docs/data.md`: which feeds exist, which fields are populated, how the data is shaped and anything surprising. **This doc carries over to iOS.**

## Phase 1: proxy server

- A tiny Node server in `web/server/` that holds the key, enforces every rule in Rule zero, and serves:
  - `GET /api/static`: stations, the route line and the timetable, read from the cache.
  - `GET /api/realtime`: vehicles, predictions and alerts, from the cache or one fresh request if the budget allows. The response also says how old the data is.
  - `GET /api/usage`: requests made in the last hour, compared with the budget.
- The key is read from `web/.env` (gitignored). Add a `web/.env.example` without the real key.

## Phase 2: the map screen

- A phone-sized layout (about 390×844), so it maps to an iPhone screen.
- The map uses Leaflet with OpenStreetMap tiles. It's free and needs no extra key.
- On the map:
  - The user's current location, from the browser's geolocation (with a prompt and a fallback if the user says no)
  - The SMART route line
  - All stations, where tapping one shows its next arrivals (scheduled and predicted)
  - Live train positions, if SMART publishes them; otherwise trains placed by interpolating between stops, clearly labeled as estimates
  - Service alerts in a banner or list
- A small status line showing how old the data is ("updated 40s ago"), the live-refresh toggle, and the request count from `/api/usage`.
- Keep it scrappy. This code gets thrown away.

## Phase 3: write down what we learned

- Update `docs/` with the screen layout, the interactions, the data quirks and what worked or didn't. That's what carries over to the native iOS build.

---

## How the user runs it locally (on their Mac)

```bash
cd web
cp .env.example .env    # then paste the key into .env
npm install
npm run dev
```

## Out of scope for now
- Accounts, notifications, favorites, trip planning
- Any production hosting. If we ever host the prototype, the request budget and cache must stay server-side.
