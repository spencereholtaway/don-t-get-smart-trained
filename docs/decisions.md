# Decisions so far

## Product
- An iOS app for SMART train riders (Sonoma-Marin Area Rail Transit).
- **First screen:** a map showing the user's current location plus all the SMART data available: stations, the route line, live train positions, predicted arrivals and service alerts.

## Platforms
- `ios/`: the real app, fully native Swift/SwiftUI with no cross-platform frameworks. Work starts when the new Mac arrives.
- `web/`: a **throwaway** proof of concept to explore the idea. Its code will not be reused.
- `docs/`: everything that should carry over from web to iOS.
- One `main` branch. Platforms are folders, not branches.

## Data: 511.org Open Data API
- The SMART operator is `SA`. The API provides GTFS static data (stops, routes, shapes, timetable) and GTFS-realtime data (trip updates, vehicle positions, alerts).
- The key goes in the query string: `?api_key=...`.
  - In cloud sessions it is the environment variable `API_511_KEY`, set as a plain env var, not a "network secret".
  - Locally it goes in `web/.env`, which is gitignored. Never commit the key.
- **The key is shared with MyBusSF, a live paid app.** Rate limits are counted per key, so follow the strict usage rules in `docs/plan.md` (preferably, get a separate dev key).
- The browser probably can't call 511 directly, because CORS likely blocks it. Expect a tiny local proxy server that holds the key.
