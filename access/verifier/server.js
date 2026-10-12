'use strict';

// Cloudflare Access JWT verifier for the SiteHub entry container.
//
// Used as a Traefik forwardAuth target: Traefik asks this service about
// every request to a protected router, and the request reaches the site
// only when the service answers 2xx. The service validates the
// Cf-Access-Jwt-Assertion header that Cloudflare Access adds after a
// successful login, so a request that reached the origin without passing
// Access (for example, one sent from Cloudflare's own network) is
// rejected.
//
// Zero dependencies: JWT parsing, JWKS handling and RS256 verification
// use node:crypto and node:http only.
//
// Environment:
//   TEAM_DOMAIN - https://<team-name>.cloudflareaccess.com (required)
//   POLICY_AUD  - Application Audience (AUD) tag of the Access app (required)
//   PORT        - listen port (default 4180)

const http = require('node:http');
const crypto = require('node:crypto');

const PORT = Number(process.env.PORT || 4180);
const TEAM_DOMAIN = String(process.env.TEAM_DOMAIN || '').trim().replace(/\/+$/, '');
const POLICY_AUD = String(process.env.POLICY_AUD || '').trim();

const JWKS_URL = `${TEAM_DOMAIN}/cdn-cgi/access/certs`;
// Access rotates the signing key every 6 weeks and keeps the previous key
// valid for 7 days, so an hourly cache plus an on-demand refresh for an
// unknown kid is plenty.
const JWKS_TTL_MS = 60 * 60 * 1000;
// Rate limit for on-demand refreshes (a flood of tokens with random kids
// must not turn into a flood of requests to Cloudflare).
const JWKS_MIN_RETRY_MS = 10 * 1000;
const FETCH_TIMEOUT_MS = 5000;
const CLOCK_SKEW_SECONDS = 5;

if (!TEAM_DOMAIN || !POLICY_AUD) {
  console.error('TEAM_DOMAIN and POLICY_AUD must be set; see access/verifier/.env.example');
  process.exit(1);
}

let keys = [];
let keysFetchedAt = 0;
let lastFetchAttemptAt = 0;
let inflightFetch = null;

// Refresh the cached JWKS when it is stale (force=false) or when a token
// references an unknown kid (force=true). Failures are logged and keep
// the previous cache: an unreachable Cloudflare must not turn into a
// crash loop, requests simply fail closed.
async function refreshJwks(force) {
  const now = Date.now();
  if (!force && keys.length > 0 && now - keysFetchedAt < JWKS_TTL_MS) {
    return;
  }
  if (inflightFetch) {
    return inflightFetch;
  }
  if (now - lastFetchAttemptAt < JWKS_MIN_RETRY_MS) {
    return;
  }
  lastFetchAttemptAt = now;
  inflightFetch = (async () => {
    const res = await fetch(JWKS_URL, {
      headers: { accept: 'application/json' },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }
    const body = await res.json();
    if (!Array.isArray(body.keys) || body.keys.length === 0) {
      throw new Error('response contains no keys');
    }
    keys = body.keys;
    keysFetchedAt = Date.now();
    console.log(`jwks: loaded ${keys.length} key(s) from ${JWKS_URL}`);
  })();
  try {
    await inflightFetch;
  } catch (err) {
    console.error(`jwks: fetch failed: ${err.message}`);
  } finally {
    inflightFetch = null;
  }
}

function base64urlToBuffer(value) {
  return Buffer.from(value.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

function parseJsonSegment(segment, what) {
  try {
    return JSON.parse(base64urlToBuffer(segment).toString('utf8'));
  } catch {
    throw new Error(`malformed ${what}`);
  }
}

// Returns { ok: true, payload } or { ok: false, reason }.
async function verifyToken(token) {
  const parts = token.split('.');
  if (parts.length !== 3) {
    return { ok: false, reason: 'malformed token' };
  }
  const [headerSegment, payloadSegment, signatureSegment] = parts;

  let header;
  let payload;
  try {
    header = parseJsonSegment(headerSegment, 'token header');
    payload = parseJsonSegment(payloadSegment, 'token payload');
  } catch (err) {
    return { ok: false, reason: err.message };
  }

  // Only RS256 is accepted, so a token cannot downgrade the algorithm.
  if (header.alg !== 'RS256') {
    return { ok: false, reason: `unsupported algorithm ${header.alg}` };
  }
  if (typeof header.kid !== 'string' || header.kid === '') {
    return { ok: false, reason: 'missing key id' };
  }

  await refreshJwks(false);
  let jwk = keys.find((key) => key.kid === header.kid);
  if (!jwk) {
    await refreshJwks(true);
    jwk = keys.find((key) => key.kid === header.kid);
  }
  if (!jwk) {
    return { ok: false, reason: 'unknown signing key' };
  }
  // Only RSA keys are usable: importing an EC key would make
  // crypto.verify() do ECDSA instead, which must never pass here.
  if (jwk.kty !== 'RSA') {
    return { ok: false, reason: 'unexpected signing key type' };
  }

  let publicKey;
  try {
    publicKey = crypto.createPublicKey({ key: jwk, format: 'jwk' });
  } catch {
    return { ok: false, reason: 'unusable signing key' };
  }

  const signedData = Buffer.from(`${headerSegment}.${payloadSegment}`);
  let signatureValid = false;
  try {
    signatureValid = crypto.verify('sha256', signedData, publicKey, base64urlToBuffer(signatureSegment));
  } catch {
    signatureValid = false;
  }
  if (!signatureValid) {
    return { ok: false, reason: 'bad signature' };
  }

  if (payload.iss !== TEAM_DOMAIN) {
    return { ok: false, reason: 'unexpected issuer' };
  }
  const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (!audiences.includes(POLICY_AUD)) {
    return { ok: false, reason: 'unexpected audience' };
  }
  const now = Math.floor(Date.now() / 1000);
  if (typeof payload.exp !== 'number' || payload.exp + CLOCK_SKEW_SECONDS < now) {
    return { ok: false, reason: 'token expired' };
  }
  if (typeof payload.nbf === 'number' && payload.nbf - CLOCK_SKEW_SECONDS > now) {
    return { ok: false, reason: 'token not valid yet' };
  }

  return { ok: true, payload };
}

// A header value must be ASCII and free of CR/LF; anything else is
// dropped (the email is used only for the trusted header below).
function safeHeaderValue(value) {
  if (typeof value !== 'string') {
    return '';
  }
  return value.replace(/[^\x20-\x7E]/g, '').slice(0, 254);
}

function deny(res, status, message) {
  res.writeHead(status, { 'content-type': 'text/plain; charset=utf-8' });
  res.end(`${message}\n`);
}

function requestLabel(req) {
  const host = req.headers['x-forwarded-host'] || '-';
  const uri = req.headers['x-forwarded-uri'] || '';
  return `${req.method} ${host}${uri}`;
}

const server = http.createServer((req, res) => {
  // Traefik does not forward the body (forwardBody is disabled), but
  // draining it keeps keep-alive connections healthy.
  req.resume();

  const rawToken = req.headers['cf-access-jwt-assertion'];
  const token = Array.isArray(rawToken) ? rawToken[0] : rawToken;
  if (!token) {
    console.error(`deny 401 ${requestLabel(req)}: missing Cf-Access-Jwt-Assertion`);
    deny(res, 401, 'missing Cf-Access-Jwt-Assertion header');
    return;
  }

  verifyToken(token)
    .then((result) => {
      if (!result.ok) {
        console.error(`deny 403 ${requestLabel(req)}: ${result.reason}`);
        deny(res, 403, `invalid Access JWT: ${result.reason}`);
        return;
      }
      const email = safeHeaderValue(result.payload.email);
      const headers = { 'content-type': 'text/plain; charset=utf-8' };
      if (email) {
        // Traefik copies this header onto the forwarded request, replacing
        // any client-supplied value of the same name.
        headers['cf-access-authenticated-user-email'] = email;
      }
      console.log(`allow ${requestLabel(req)}: ${email || result.payload.sub || 'authenticated'}`);
      res.writeHead(200, headers);
      res.end('ok');
    })
    .catch((err) => {
      console.error(`deny 500 ${requestLabel(req)}: ${err.message}`);
      deny(res, 500, 'JWT verification failed');
    });
});

server.listen(PORT, () => {
  console.log(`cf-access-verify: listening on :${PORT} (team ${TEAM_DOMAIN}, aud ${POLICY_AUD})`);
  // Warm the cache at startup so a wrong team domain shows up in the logs
  // right away (requests would fail closed anyway).
  refreshJwks(true);
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
  });
}
