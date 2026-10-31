// SPDX-License-Identifier: Apache-2.0
// Browser check of the live site (headless Chrome via puppeteer-core):
//   node build/browser-check.mjs [base-url] [--submit test@example.com] [--shots DIR]
//
// 1. Invite page https://antenna.contact/#<invite>: every network request must be same-origin and
//    none may contain the invite; the invite block must be shown with antenna://pair#<invite>;
//    the fragment must be gone from the address; no console errors or CSP violations.
// 2. A damaged invite shows the "damaged" message; a normal anchor (#beta) shows no invite block.
// 3. --submit: fills the beta form, measures the proof-of-work, expects the success message.
//
// puppeteer-core and Chrome are not project dependencies: point PUPPETEER_CORE at a puppeteer-core
// installation (the package directory) and CHROME at a Chrome binary.
import { createRequire } from 'node:module';
import { randomBytes } from 'node:crypto';

if (!process.env.PUPPETEER_CORE || !process.env.CHROME) {
  console.error('set PUPPETEER_CORE (puppeteer-core package directory) and CHROME (Chrome binary)');
  process.exit(2);
}
const require = createRequire(import.meta.url);
const puppeteer = require(process.env.PUPPETEER_CORE);
const CHROME = process.env.CHROME;

const args = process.argv.slice(2);
const base = (args.find((a) => a.startsWith('http')) || 'https://antenna.contact').replace(/\/$/, '');
const submitAt = args.indexOf('--submit');
const submitEmail = submitAt >= 0 ? args[submitAt + 1] : null;
const shotsAt = args.indexOf('--shots');
const shots = shotsAt >= 0 ? args[shotsAt + 1] : null;
const origin = new URL(base).origin;

const B32 = 'abcdefghijklmnopqrstuvwxyz234567';
const b32 = (n) => [...randomBytes(n)].map((b) => B32[b & 31]).join('');
const payload = `${b32(52)}.${b32(52)}.${Buffer.from('https://relay.example.net./').toString('base64url')}`;

const failures = [];
const expect = (cond, msg) => { if (!cond) failures.push(msg); console.log(`${cond ? 'ok  ' : 'FAIL'} ${msg}`); };

const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ['--no-sandbox'] });
try {
  async function open(hash, viewport = { width: 1280, height: 900 }) {
    const page = await browser.newPage();
    await page.setViewport(viewport);
    const requests = [];
    const problems = [];
    // What goes on the wire: puppeteer reports the document URL with its fragment appended
    // (CDP keeps it in a separate urlFragment field); the request line never contains it.
    page.on('request', (r) => requests.push({ wire: r.url().split('#')[0], headers: JSON.stringify(r.headers()) }));
    page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') problems.push(m.text()); });
    page.on('pageerror', (e) => problems.push(String(e)));
    await page.evaluateOnNewDocument(() => {
      document.addEventListener('securitypolicyviolation', (e) => console.error(`CSP violation: ${e.violatedDirective} ${e.blockedURI}`));
    });
    await page.goto(`${base}/${hash}`, { waitUntil: 'networkidle0' });
    return { page, requests, problems };
  }

  // 1. invite
  {
    const { page, requests, problems } = await open('#' + payload);
    const state = await page.evaluate(() => ({
      shown: !document.getElementById('invite').hidden,
      title: document.getElementById('invite-title').textContent,
      link: document.getElementById('invite-link').value,
      href: document.getElementById('invite-open').getAttribute('href'),
      url: location.href,
    }));
    expect(state.shown, 'invite: block is shown');
    expect(state.link === 'antenna://pair#' + payload, 'invite: copy field holds antenna://pair#<invite>');
    expect(state.href === 'antenna://pair#' + payload, 'invite: "Open in Antenna" points to antenna://pair#<invite>');
    expect(!state.url.includes('#'), `invite: fragment removed from the address (${state.url})`);
    const foreign = requests.map((r) => r.wire).filter((u) => !u.startsWith(origin + '/') && !u.startsWith('data:'));
    expect(foreign.length === 0, `invite: no requests outside ${origin} (${requests.length} total)${foreign.length ? ': ' + foreign.join(', ') : ''}`);
    const secretPart = payload.split('.')[1];
    expect(!requests.some((r) => r.wire.includes(secretPart) || r.headers.includes(secretPart)), 'invite: no request line or header carries the invite');
    expect(problems.length === 0, `invite: no console errors / CSP violations${problems.length ? ': ' + problems.join(' | ') : ''}`);
    console.log('     requests: ' + requests.map((r) => r.wire.replace(origin, '')).join(' '));
    if (shots) await page.screenshot({ path: `${shots}/invite-desktop.png` });
    await page.close();
  }
  // 1b. invite on a phone
  if (shots) {
    const { page } = await open('#' + payload, { width: 390, height: 844, deviceScaleFactor: 2, isMobile: true });
    await page.screenshot({ path: `${shots}/invite-mobile.png` });
    await page.close();
  }

  // 2. damaged invite and a normal anchor
  {
    const { page } = await open('#abc.def.ghi');
    const t = await page.evaluate(() => [!document.getElementById('invite').hidden, document.getElementById('invite-title').textContent]);
    expect(t[0] && /damaged/.test(t[1]), 'damaged invite: "looks damaged" message');
    await page.close();
  }
  {
    const { page, problems } = await open('#beta');
    const hidden = await page.evaluate(() => document.getElementById('invite').hidden);
    expect(hidden, '#beta: no invite block');
    expect(problems.length === 0, `home: no console errors${problems.length ? ': ' + problems.join(' | ') : ''}`);
    if (shots) await page.screenshot({ path: `${shots}/home-desktop.png`, fullPage: true });
    await page.close();
  }
  if (shots) {
    const { page } = await open('', { width: 390, height: 844, deviceScaleFactor: 2, isMobile: true });
    await page.screenshot({ path: `${shots}/home-mobile.png`, fullPage: true });
    await page.close();
  }

  // 3. beta form
  if (submitEmail) {
    const { page, problems } = await open('#beta');
    await page.type('input[name=email]', submitEmail);
    await page.click('input[value=claude-code]');
    await page.click('input[value=codex]');
    await page.type('textarea[name=scenario]', 'Automated site check — safe to delete.');
    await page.click('input[name=consent]');
    const t0 = Date.now();
    await page.click('#beta-form button[type=submit]');
    await page.waitForFunction(() => /ok|err/.test(document.getElementById('beta-status').className), { timeout: 60000 });
    const res = await page.evaluate(() => [document.getElementById('beta-status').className, document.getElementById('beta-status').textContent]);
    expect(res[0].includes('ok'), `beta form: accepted in ${Date.now() - t0} ms — "${res[1]}"`);
    expect(problems.length === 0, `beta form: no console errors${problems.length ? ': ' + problems.join(' | ') : ''}`);
    await page.close();
  }
} finally {
  await browser.close();
}
if (failures.length) { console.error(`browser-check: ${failures.length} failed`); process.exit(1); }
console.log('browser-check: ok');
