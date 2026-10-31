// SPDX-License-Identifier: Apache-2.0
// Unit test of the worker's routes that need no Cloudflare runtime:  node build/worker-test.mjs
// The update host is replaced by a local stub, so the test never reaches the network.
import assert from 'node:assert/strict';
import worker from '../src/worker.js';

const REPO = 'https://github.com/Danta-Nort/antenna';
const manifest = (version, extra = []) => ({
  version,
  assets: [
    { name: `Antenna-${version}-macos-arm64.dmg`, os: 'macos', kind: 'app' },
    { name: `antenna-${version}-linux-x86_64.tar.gz`, os: 'linux', kind: 'cli' },
    { name: `antenna-desktop-${version}-linux-x86_64.tar.gz`, os: 'linux', kind: 'app' },
    { name: `antenna-desktop-${version}-linux-x86_64.deb`, os: 'linux', kind: 'deb_app' },
    ...extra,
  ],
});
let hosted = {};
globalThis.fetch = async (url) => {
  const body = hosted[url];
  if (body === undefined) return new Response('not found', { status: 404 });
  return new Response(typeof body === 'string' ? body : JSON.stringify(body), { status: 200 });
};
const STABLE = 'https://updates.stillbyte.dev/antenna/antenna-stable-manifest.json';
const PREVIEW = 'https://updates.stillbyte.dev/antenna/antenna-preview-manifest.json';
const get = (path, host = 'antenna.contact') => worker.fetch(new Request(`https://${host}${path}`), {});

// Only a preview is published: the buttons lead to its files.
hosted = { [PREVIEW]: manifest('0.1.0-preview.11') };
let r = await get('/download/mac');
assert.equal(r.status, 302);
assert.equal(r.headers.get('Location'), `${REPO}/releases/download/v0.1.0-preview.11/Antenna-0.1.0-preview.11-macos-arm64.dmg`);
assert.ok(r.headers.get('Content-Security-Policy'), 'security headers on the redirect');

// A stable release wins over the preview.
hosted = { [STABLE]: manifest('0.1.0'), [PREVIEW]: manifest('0.1.1-preview.1') };
r = await get('/download/server');
assert.equal(r.headers.get('Location'), `${REPO}/releases/download/v0.1.0/antenna-0.1.0-linux-x86_64.tar.gz`);
r = await get('/download/linux-deb');
assert.equal(r.headers.get('Location'), `${REPO}/releases/download/v0.1.0/antenna-desktop-0.1.0-linux-x86_64.deb`);

// Unknown targets, missing assets, broken JSON and names that could leave the path go to the releases page.
for (const [path, h] of [
  ['/download/windows', { [STABLE]: manifest('0.1.0') }],
  ['/download/__proto__', { [STABLE]: manifest('0.1.0') }],
  ['/download/mac-cli', { [STABLE]: manifest('0.1.0') }],
  ['/download/mac', { [STABLE]: 'not json' }],
  ['/download/mac', {}],
  ['/download/mac', { [STABLE]: { version: '0.1.0', assets: [{ name: '../../evil', os: 'macos', kind: 'app' }] } }],
  ['/download/mac', { [STABLE]: { version: '0.1.0/../x', assets: [{ name: 'a.dmg', os: 'macos', kind: 'app' }] } }],
]) {
  hosted = h;
  r = await get(path);
  assert.equal(r.status, 302, path);
  assert.equal(r.headers.get('Location'), `${REPO}/releases/latest`, `${path} with ${JSON.stringify(h).slice(0, 80)}`);
}

// The old beta domain now points at the downloads.
r = await get('/', 'antennachat.app');
assert.equal(r.status, 301);
assert.equal(r.headers.get('Location'), 'https://antenna.contact/#download');

console.log('worker-test: ok');
