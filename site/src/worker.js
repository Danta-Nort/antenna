// SPDX-License-Identifier: Apache-2.0
// antenna.contact — Cloudflare Worker in front of static assets (docs/SITE.md).
//
// Every request passes through here (run_worker_first) so that:
//   * the secondary domains answer 301 (antennachat.com/.org → antenna.contact, antennachat.app → /#download,
//     www.antenna.contact → apex), and plain http → https;
//   * GET /download/<what> answers 302 to that file of the newest release on GitHub, found in the signed release
//     manifest on the update host (the same address the app checks), so a download button is one click;
//   * every response — page, asset, redirect, error — carries the same security headers;
//   * POST /api/beta stores a closed-beta request in D1 (env.DB); the page no longer shows the form, the endpoint
//     stays for clients that still post to it.
// Nothing here logs request data: no IPs, no emails, no bodies.

const PRIMARY = 'antenna.contact';
const ORIGIN = `https://${PRIMARY}`;

// host → function(url) returning the redirect target
const REDIRECTS = {
  'www.antenna.contact': (u) => ORIGIN + u.pathname + u.search,
  'antennachat.com': (u) => ORIGIN + u.pathname + u.search,
  'www.antennachat.com': (u) => ORIGIN + u.pathname + u.search,
  'antennachat.org': (u) => ORIGIN + u.pathname + u.search,
  'www.antennachat.org': (u) => ORIGIN + u.pathname + u.search,
  'antennachat.app': () => ORIGIN + '/#download',
  'www.antennachat.app': () => ORIGIN + '/#download',
};

const CSP = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self'",
  "img-src 'self'",
  "font-src 'self'",
  "connect-src 'self'",
  "manifest-src 'self'",
  "form-action 'self'",
  "base-uri 'none'",
  "frame-ancestors 'none'",
  "require-trusted-types-for 'script'",
  "trusted-types 'none'",
].join('; ');

const SECURITY_HEADERS = {
  'Strict-Transport-Security': 'max-age=63072000; includeSubDomains; preload',
  'Content-Security-Policy': CSP,
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Permissions-Policy':
    'accelerometer=(), browsing-topics=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), ' +
    'hid=(), magnetometer=(), microphone=(), midi=(), payment=(), publickey-credentials-get=(), serial=(), usb=()',
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Embedder-Policy': 'require-corp',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Origin-Agent-Cluster': '?1',
};

function secure(response, extra = {}) {
  const r = new Response(response.body, response);
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) r.headers.set(k, v);
  for (const [k, v] of Object.entries(extra)) r.headers.set(k, v);
  return r;
}

function redirect(location, status = 301) {
  return secure(new Response(null, { status, headers: { Location: location, 'Cache-Control': 'public, max-age=3600' } }));
}

function json(status, data, extra = {}) {
  return secure(new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...extra },
  }));
}

function cacheControl(pathname, status) {
  if (status !== 200 && status !== 304) return 'no-store';
  if (pathname.startsWith('/assets/fonts/')) return 'public, max-age=31536000, immutable';
  if (pathname.startsWith('/assets/')) return 'public, max-age=3600, stale-while-revalidate=86400';
  return 'public, max-age=0, must-revalidate';
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const host = url.hostname.toLowerCase();

    if (REDIRECTS[host]) return redirect(REDIRECTS[host](url));
    if (url.protocol === 'http:') return redirect(ORIGIN + url.pathname + url.search);
    if (host !== PRIMARY) {
      // workers.dev or preview hosts: serve, but keep out of search engines
      const res = await handle(request, env, url);
      const r = new Response(res.body, res);
      r.headers.set('X-Robots-Tag', 'noindex, nofollow');
      return r;
    }
    return handle(request, env, url);
  },
};

async function handle(request, env, url) {
  if (url.pathname.startsWith('/download/') && (request.method === 'GET' || request.method === 'HEAD')) {
    return download(url.pathname.slice('/download/'.length));
  }
  if (url.pathname === '/api/beta') {
    if (request.method !== 'POST') return json(405, { ok: false, error: 'Method not allowed.' }, { Allow: 'POST' });
    try {
      return await beta(request, env);
    } catch (_) {
      return json(500, { ok: false, error: 'Something went wrong on our side. Please try again later.' });
    }
  }
  if (url.pathname.startsWith('/api/')) return json(404, { ok: false, error: 'Not found.' });
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return secure(new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } }));
  }
  const res = await env.ASSETS.fetch(request);
  return secure(res, { 'Cache-Control': cacheControl(url.pathname, res.status) });
}

// ---------- downloads ----------

const REPO = 'https://github.com/Danta-Nort/antenna';
// Stable first; until the first stable release exists, the newest preview.
const MANIFESTS = [
  'https://updates.stillbyte.dev/antenna/antenna-stable-manifest.json',
  'https://updates.stillbyte.dev/antenna/antenna-preview-manifest.json',
];
// /download/<key> → the asset of the manifest (os, kind) it stands for (docs/UPDATES.md §5).
const DOWNLOADS = {
  mac: { os: 'macos', kind: 'app' },
  'mac-cli': { os: 'macos', kind: 'cli' },
  linux: { os: 'linux', kind: 'app' },
  'linux-deb': { os: 'linux', kind: 'deb_app' },
  server: { os: 'linux', kind: 'cli' },
  'server-deb': { os: 'linux', kind: 'deb_cli' },
};
const SAFE = /^[0-9A-Za-z][0-9A-Za-z._+-]*$/;

async function download(key) {
  const want = Object.hasOwn(DOWNLOADS, key) ? DOWNLOADS[key] : null;
  if (!want) return redirect(`${REPO}/releases/latest`, 302);
  for (const m of MANIFESTS) {
    try {
      const r = await fetch(m, { cf: { cacheTtl: 300, cacheEverything: true } });
      if (!r.ok) continue;
      const j = await r.json();
      const a = (Array.isArray(j.assets) ? j.assets : []).find((x) => x && x.os === want.os && x.kind === want.kind);
      // Only names that cannot leave the release's download path; the files are checked again by the app's updater.
      if (a && typeof j.version === 'string' && SAFE.test(j.version) && typeof a.name === 'string' && SAFE.test(a.name)) {
        return secure(new Response(null, {
          status: 302,
          headers: { Location: `${REPO}/releases/download/v${j.version}/${a.name}`, 'Cache-Control': 'public, max-age=300' },
        }));
      }
    } catch (_) {
      // the next manifest, then the releases page
    }
  }
  return redirect(`${REPO}/releases/latest`, 302);
}

// ---------- closed beta ----------

const AGENTS = new Set(['claude-code', 'codex', 'cursor', 'mcp-other', 'own', 'none']);
const POW_DIFFICULTY = 15; // must match public/assets/site.js
const POW_WINDOW_MS = 30 * 60 * 1000;
const CONSENT_VERSION = 'privacy-2026-10-02';
const MAX_BODY = 8192;
const MAX_NEW_PER_10_MIN = 60; // whole site; protects storage from a distributed flood

const EMAIL_RE = /^[^\s@<>()",;:]+@[^\s@<>()",;:]+\.[^\s@<>()",;:]+$/;

async function beta(request, env) {
  const origin = request.headers.get('Origin');
  if (origin && origin !== ORIGIN) {
    return json(403, { ok: false, error: 'Requests are accepted only from antenna.contact.' });
  }
  if (!(request.headers.get('Content-Type') || '').toLowerCase().startsWith('application/json')) {
    return json(415, { ok: false, error: 'Unsupported request.' });
  }

  // Per-address rate limit at the edge (memory only, nothing stored).
  if (env.BETA_RL) {
    const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
    const { success } = await env.BETA_RL.limit({ key: ip });
    if (!success) return json(429, { ok: false, error: 'Too many requests. Please try again in a minute.' });
  }

  const raw = await request.text();
  if (raw.length > MAX_BODY) return json(413, { ok: false, error: 'The request is too long.' });
  let body;
  try { body = JSON.parse(raw); } catch (_) { return json(400, { ok: false, error: 'Malformed request.' }); }
  if (!body || typeof body !== 'object') return json(400, { ok: false, error: 'Malformed request.' });

  // Honeypot: a field humans never see. Pretend success, store nothing.
  if (typeof body.website === 'string' && body.website.trim() !== '') return json(200, { ok: true });

  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
  if (!email || email.length > 254 || !EMAIL_RE.test(email)) {
    return json(400, { ok: false, error: 'Please enter a valid email address.' });
  }
  if (body.consent !== true) {
    return json(400, { ok: false, error: 'Please confirm the consent checkbox.' });
  }

  const agents = Array.isArray(body.agents) ? [...new Set(body.agents.filter((a) => AGENTS.has(a)))] : [];
  const agentsOther = clean(body.agents_other, 200);
  const scenario = clean(body.scenario, 2000);

  const pow = body.pow || {};
  if (!(await powValid(email, pow))) {
    return json(400, { ok: false, error: 'The spam check did not pass. Please reload the page and try again.' });
  }

  const now = new Date().toISOString();
  const recent = await env.DB.prepare(
    "SELECT count(*) AS n FROM beta_requests WHERE created_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-10 minutes')",
  ).first();
  if (recent && recent.n >= MAX_NEW_PER_10_MIN) {
    return json(503, { ok: false, error: 'We are receiving a lot of requests right now. Please try again later.' });
  }

  await env.DB.prepare(
    `INSERT INTO beta_requests (email, agents, agents_other, scenario, consent_version, created_at, updated_at, submissions)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, 1)
     ON CONFLICT(email) DO UPDATE SET
       agents = excluded.agents, agents_other = excluded.agents_other, scenario = excluded.scenario,
       consent_version = excluded.consent_version, updated_at = excluded.updated_at,
       submissions = beta_requests.submissions + 1`,
  ).bind(email, agents.join(','), agentsOther, scenario, CONSENT_VERSION, now).run();

  // Same answer for new and repeated addresses: the form must not reveal who is already on the list.
  return json(200, { ok: true });
}

function clean(v, max) {
  if (typeof v !== 'string') return '';
  // drop control characters except newline and tab, collapse to max length
  return v.replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, '').trim().slice(0, max);
}

async function powValid(email, pow) {
  const ts = Number(pow.ts), nonce = Number(pow.nonce);
  if (!Number.isSafeInteger(ts) || !Number.isSafeInteger(nonce) || nonce < 0) return false;
  if (Math.abs(Date.now() - ts) > POW_WINDOW_MS) return false;
  const data = new TextEncoder().encode(`antenna-beta/v1|${ts}|${email}|${nonce}`);
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', data));
  let bits = 0;
  for (const b of h) {
    if (b === 0) { bits += 8; continue; }
    bits += Math.clz32(b) - 24;
    break;
  }
  return bits >= POW_DIFFICULTY;
}
