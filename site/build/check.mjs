// SPDX-License-Identifier: Apache-2.0
// Static checks before every deploy:  node build/check.mjs
//  - no external resources anywhere (scripts, styles, fonts, images): the CSP allows only 'self';
//  - no inline scripts, inline styles or on*= handlers (they would be blocked by the CSP anyway);
//  - every local href/src/url() points to a file that exists;
//  - the proof-of-work difficulty is the same in the page and in the worker.
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, dirname, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const pub = join(root, 'public');
const errors = [];
const walk = (d) => readdirSync(d).flatMap((f) => (statSync(join(d, f)).isDirectory() ? walk(join(d, f)) : [join(d, f)]));
const files = walk(pub);
const rel = (f) => f.slice(pub.length);

const localExists = (ref) => {
  const path = ref.split(/[?#]/)[0];
  if (path === '/' || path === '') return true;
  const f = join(pub, path);
  return existsSync(f) || existsSync(f + '.html') || existsSync(join(f, 'index.html'));
};

// Links a visitor can follow (not loaded by the page): allowed to be absolute.
const NAV_OK = /^(#|mailto:|https:\/\/antenna\.contact(\/|$)|https:\/\/github\.com\/Danta-Nort\/antenna(\/|$))/;
// Paths the worker answers itself (src/worker.js), not files in public/.
const WORKER_ROUTES = /^\/download\/(mac|mac-cli|linux|linux-deb|server|server-deb)$/;

for (const f of files) {
  const ext = extname(f);
  const text = ['.html', '.css', '.js'].includes(ext) ? readFileSync(f, 'utf8') : '';
  if (ext === '.html') {
    if (/<script(?![^>]*\bsrc=)[^>]*>/i.test(text)) errors.push(`${rel(f)}: inline <script>`);
    if (/<style[\s>]/i.test(text)) errors.push(`${rel(f)}: inline <style>`);
    if (/\sstyle\s*=/i.test(text)) errors.push(`${rel(f)}: style= attribute`);
    if (/\son[a-z]+\s*=/i.test(text)) errors.push(`${rel(f)}: on*= handler`);
    for (const m of text.matchAll(/<(script|img|link|source|iframe|video|audio|embed|object)\b[^>]*?\b(src|href)="([^"]*)"/gi)) {
      const [, tag, , ref] = m;
      const isNavLink = tag.toLowerCase() === 'link' && /rel="canonical"/.test(m[0]);
      if (isNavLink) continue;
      if (!ref.startsWith('/')) errors.push(`${rel(f)}: <${tag}> loads a non-local resource: ${ref}`);
      else if (!localExists(ref)) errors.push(`${rel(f)}: missing ${ref}`);
    }
    // srcset candidates ("url 720w, url 1440w") — same rules as src
    for (const m of text.matchAll(/\bsrcset="([^"]*)"/gi)) {
      for (const cand of m[1].split(',')) {
        const ref = cand.trim().split(/\s+/)[0];
        if (!ref.startsWith('/')) errors.push(`${rel(f)}: srcset loads a non-local resource: ${ref}`);
        else if (!localExists(ref)) errors.push(`${rel(f)}: missing ${ref} (srcset)`);
      }
    }
    for (const m of text.matchAll(/<a\b[^>]*\bhref="([^"]*)"/gi)) {
      const ref = m[1];
      if (NAV_OK.test(ref) || WORKER_ROUTES.test(ref)) continue;
      if (!ref.startsWith('/')) errors.push(`${rel(f)}: external link ${ref}`);
      else if (!localExists(ref)) errors.push(`${rel(f)}: broken link ${ref}`);
    }
    for (const m of text.matchAll(/content="(https?:[^"]*)"/gi)) {
      if (!NAV_OK.test(m[1])) errors.push(`${rel(f)}: external URL in meta: ${m[1]}`);
      // og:image and the like point at our own files: they must exist
      else if (!localExists(new URL(m[1]).pathname)) errors.push(`${rel(f)}: meta points to a missing file: ${m[1]}`);
    }
  }
  if (ext === '.css') {
    for (const m of text.matchAll(/url\(\s*["']?([^"')]+)/g)) {
      if (!m[1].startsWith('/')) errors.push(`${rel(f)}: non-local url(${m[1]})`);
      else if (!localExists(m[1])) errors.push(`${rel(f)}: missing ${m[1]}`);
    }
    if (/@import/i.test(text)) errors.push(`${rel(f)}: @import`);
  }
  if (ext === '.js') {
    if (/\binnerHTML\b|\bouterHTML\b|insertAdjacentHTML|document\.write|\beval\(|new Function/.test(text)) {
      errors.push(`${rel(f)}: HTML/code sink (Trusted Types is enforced)`);
    }
    if (/fetch\(\s*['"`]https?:|XMLHttpRequest|WebSocket|sendBeacon|EventSource/.test(text)) {
      errors.push(`${rel(f)}: network call to an absolute URL or a non-fetch channel`);
    }
  }
}

const pageDiff = /const DIFFICULTY = (\d+);/.exec(readFileSync(join(pub, 'assets/site.js'), 'utf8'))?.[1];
const workerDiff = /const POW_DIFFICULTY = (\d+);/.exec(readFileSync(join(root, 'src/worker.js'), 'utf8'))?.[1];
if (!pageDiff || pageDiff !== workerDiff) errors.push(`PoW difficulty differs: page ${pageDiff}, worker ${workerDiff}`);

if (errors.length) {
  console.error('check: FAILED\n  ' + errors.join('\n  '));
  process.exit(1);
}
console.log(`check: ok (${files.length} files)`);
