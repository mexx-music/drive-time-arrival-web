/* Minimal Express proxy for Google Maps APIs (local testing)
 * - Reads GOOGLE_MAPS_API_KEY from env
 * - Provides POST /api/geocode, /api/directions, /api/autocomplete
 * - Basic CORS allowlist and rate-limiting for local dev
 */

const express = require('express');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const cors = require('cors');
const fetch = require('node-fetch');

const app = express();
app.use(helmet());
app.use(express.json({ limit: '1mb' }));

// Simple rate limiter
const limiter = rateLimit({ windowMs: 60 * 1000, max: 120 });
app.use(limiter);

// CORS allowlist
const allowedOrigins = new Set([
  'http://localhost',
  'http://127.0.0.1',
  'http://localhost:8080',
  'http://127.0.0.1:8080',
  'http://localhost:5000',
  'http://127.0.0.1:5000',
  'https://mexx-music.github.io'
]);
app.use(cors({
  origin: (origin, callback) => {
    if (!origin) return callback(null, true);
    // allow exact host matches (ignores ports in allowedOrigins entries above)
    const host = origin.replace(/:\d+$/, '');
    if (allowedOrigins.has(origin) || allowedOrigins.has(host)) return callback(null, true);
    return callback(new Error('Not allowed by CORS'));
  }
}));

const GOOGLE_KEY = process.env.GOOGLE_MAPS_API_KEY;
if (!GOOGLE_KEY) {
  console.warn('Warning: GOOGLE_MAPS_API_KEY not set. Proxy will return errors for Google requests.');
}

function forwardGet(url) {
  return fetch(url).then(async (r) => {
    const text = await r.text();
    return { status: r.status, body: text };
  });
}

app.get('/health', (_, res) => res.json({ ok: true, proxy: true }));

app.post('/api/geocode', async (req, res) => {
  try {
    const address = (req.body && req.body.address) || '';
    if (!address) return res.status(400).json({ error: 'missing_address' });
    const url = `https://maps.googleapis.com/maps/api/geocode/json?address=${encodeURIComponent(address)}&key=${GOOGLE_KEY}`;
    const r = await forwardGet(url);
    res.status(r.status).type('application/json').send(r.body);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'proxy_error', message: err.message });
  }
});

app.post('/api/directions', async (req, res) => {
  try {
    const { origin, destination, waypoints = [], mode = 'driving', departure_time = 'now' } = req.body || {};
    if (!origin || !destination) return res.status(400).json({ error: 'missing_origin_or_destination' });
    let url = `https://maps.googleapis.com/maps/api/directions/json?origin=${encodeURIComponent(origin)}&destination=${encodeURIComponent(destination)}&mode=${mode}&departure_time=${departure_time}&key=${GOOGLE_KEY}&units=metric`;
    if (Array.isArray(waypoints) && waypoints.length) {
      const wp = waypoints.map(w => encodeURIComponent(w)).join('|');
      url += `&waypoints=${wp}`;
    }
    const r = await forwardGet(url);
    res.status(r.status).type('application/json').send(r.body);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'proxy_error', message: err.message });
  }
});

app.post('/api/autocomplete', async (req, res) => {
  try {
    const { input, sessiontoken } = req.body || {};
    if (!input) return res.status(400).json({ error: 'missing_input' });
    let url = `https://maps.googleapis.com/maps/api/place/autocomplete/json?input=${encodeURIComponent(input)}&key=${GOOGLE_KEY}`;
    if (sessiontoken) url += `&sessiontoken=${encodeURIComponent(sessiontoken)}`;
    const r = await forwardGet(url);
    res.status(r.status).type('application/json').send(r.body);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'proxy_error', message: err.message });
  }
});

const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`Proxy listening on port ${port}`));
