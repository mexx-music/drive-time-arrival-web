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

// origin checker reused for both normal requests and preflight
const originChecker = (origin, callback) => {
  if (!origin) return callback(null, true);
  const low = origin.toLowerCase();
  // Allow any localhost or 127.0.0.1 origin (with arbitrary port)
  if (low.startsWith('http://localhost') || low.startsWith('http://127.0.0.1')) {
    return callback(null, true);
  }
  // Allow other explicitly listed origins
  if (allowedOrigins.has(origin) || allowedOrigins.has(origin.replace(/:\d+$/, ''))) {
    return callback(null, true);
  }
  return callback(new Error('Not allowed by CORS'));
};

const corsOptions = {
  origin: originChecker,
  methods: ['GET','HEAD','PUT','PATCH','POST','DELETE','OPTIONS'],
  allowedHeaders: ['Content-Type','Authorization','X-Requested-With','Accept'],
  preflightContinue: false,
  optionsSuccessStatus: 204
};

app.use(cors(corsOptions));
// Handle preflight requests for all routes
app.options('*', cors(corsOptions));

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

const handleDirections = async (req, res) => {
  try {
    const params = req.method === 'GET' ? req.query : req.body;

    const { origin, destination, waypoints, mode, departure_time } = params;

    if (!origin || !destination) {
      return res.status(400).json({ error: 'Missing origin or destination' });
    }

    const apiKey = process.env.GOOGLE_MAPS_API_KEY;

    const url = new URL('https://maps.googleapis.com/maps/api/directions/json');

    url.searchParams.append('origin', origin);
    url.searchParams.append('destination', destination);
    url.searchParams.append('mode', mode || 'driving');
    url.searchParams.append('departure_time', departure_time || 'now');
    url.searchParams.append('key', apiKey);

    if (waypoints && waypoints.length > 0) {
      // support both array and single-string waypoint formats
      const wpValue = Array.isArray(waypoints) ? waypoints.join('|') : waypoints;
      url.searchParams.append('waypoints', wpValue);
    }

    const response = await fetch(url.toString());
    const data = await response.json();

    res.json(data);

  } catch (err) {
    console.error('Directions proxy error:', err);
    res.status(500).json({ error: 'Proxy failed' });
  }
};

app.get('/api/directions', handleDirections);
app.post('/api/directions', handleDirections);

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

// replace direct listen with a safe wrapper to avoid crashing if port is in use
const startServer = (port) => {
  const server = app.listen(port, () => {
    console.log(`[proxy] Listening on port ${port}`);
  });
  server.on('error', (err) => {
    if (err && err.code === 'EADDRINUSE') {
      console.error(`[proxy] Port ${port} already in use; proxy will not start a new process.`);
    } else {
      console.error('[proxy] Server error:', err);
      process.exit(1);
    }
  });
};

const port = process.env.PORT || 3000;
startServer(port);
