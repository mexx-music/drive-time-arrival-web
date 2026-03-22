# drivetimearrival

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Quick start script

You can start the proxy and run Flutter web with the included helper:

```
./start.sh
```

It expects `GOOGLE_MAPS_API_KEY` to be set in your environment or in a `.env` file at the repo root.

## Deploying the proxy to Render

To make the GitHub Pages‑hosted web app work (geocoding/directions), deploy the Node proxy in `/proxy` to a hosted service such as Render.

Render settings (minimal):
- Root directory: `proxy`
- Build command: `npm install`
- Start command: `npm start`
- Env var: `GOOGLE_MAPS_API_KEY` (set in Render dashboard, do not commit)

After deploying, update your web build to use the deployed proxy URL:

```
flutter build web --release --base-href "/drive-time-arrival/" --dart-define=MAPS_PROXY_BASE=https://your-proxy.onrender.com
```

Locally continue to use `MAPS_PROXY_BASE=http://localhost:3000` for development.
