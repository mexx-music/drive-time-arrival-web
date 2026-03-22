# DriveTimeArrival - Local Maps Proxy

This minimal Express proxy lets your Flutter Web app call Google Maps REST APIs from the browser by forwarding requests server-side. Use for local testing only.

## Requirements
- Node 16+ (or compatible)
- Set environment variable `GOOGLE_MAPS_API_KEY` before running

## Install

```bash
cd proxy
npm install
```

## Run

```bash
# set API key (bash)
export GOOGLE_MAPS_API_KEY="YOUR_SERVER_SIDE_KEY"
# start
node server.js
# or with nodemon for dev
npm run start:dev
```

## Endpoints
- POST /api/geocode
  - body: { "address": "Rotterdam, NL" }
  - forwards to Google Geocoding API and returns the JSON

- POST /api/directions
  - body: { "origin": "A", "destination": "B", "waypoints": ["X","Y"] }
  - forwards to Google Directions API and returns the JSON

- POST /api/autocomplete
  - body: { "input": "Rot" }
  - forwards to Places Autocomplete API

- GET /health
  - returns { ok: true }

## CORS allowlist
This proxy allows requests from:
- http://localhost
- http://127.0.0.1
- https://mexx-music.github.io

If you serve your web app at a different origin, update `allowedOrigins` in `server.js`.

## Notes
- This is intended for local development and minimal testing. For production, deploy behind HTTPS, add proper auth, restrict your Google API key and add monitoring/rate limits as needed.
