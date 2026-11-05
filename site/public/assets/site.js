// SPDX-License-Identifier: Apache-2.0
// antenna.contact — the only script on the site. No dependencies, no external requests.
//
// 1. Invite handler: an address like https://antenna.contact/#<invite> carries the invite in the
//    fragment. Browsers never send the fragment to a server; this script reads it locally, shows
//    "Open in Antenna" (antenna://pair#…) and "Copy link", and makes NO network request for it.
//    The fragment is then removed from the address bar and from this tab's history entry.
// 2. Closed-beta form: a small proof-of-work instead of a captcha, then one POST to /api/beta.
//
// The page runs under a strict CSP with Trusted Types: no HTML string sinks, only textContent and
// properties, so nothing taken from the address can become markup or code.
'use strict';

(() => {
  const $ = (id) => document.getElementById(id);

  // 1. Invite handler.
  // Same format as antenna_proto::invite (docs/PROTOCOL.md §3): <E_A>.<s>.<relay>[.<direct>]
  // E_A and s — 32 bytes in lowercase base32 without padding (52 chars); relay/direct — base64url.
  const INVITE_SCHEME = 'antenna://pair#';
  const KNOWN_PREFIXES = ['x://pair#', 'antenna://pair#'];
  const B32_52 = /^[a-z2-7]{52}$/i;
  const B64URL = /^[A-Za-z0-9_-]{0,512}$/;

  function parseInvite(fragment) {
    let s = fragment;
    try { s = decodeURIComponent(s); } catch (_) { /* keep as is */ }
    s = s.trim();
    for (const p of KNOWN_PREFIXES) if (s.toLowerCase().startsWith(p)) { s = s.slice(p.length); break; }
    if (!s || s.length > 1024) return { kind: s ? 'broken' : 'none' };
    const parts = s.split('.');
    if (parts.length === 1) return { kind: 'none' }; // a normal in-page anchor such as #beta
    const ok = (parts.length === 3 || parts.length === 4) &&
      B32_52.test(parts[0]) && B32_52.test(parts[1]) &&
      B64URL.test(parts[2]) && (parts.length === 3 || (parts[3] !== '' && B64URL.test(parts[3]))) &&
      (parts[2] !== '' || parts.length === 4);
    if (!ok) return { kind: 'broken' };
    return { kind: 'invite', payload: parts[0].toLowerCase() + '.' + parts[1].toLowerCase() + '.' + parts.slice(2).join('.') };
  }

  function showInvite(result) {
    const section = $('invite');
    const open = $('invite-open');
    const copy = $('invite-copy');
    const field = $('invite-link');
    const status = $('invite-copy-status');
    const title = $('invite-title');
    if (!section) return;

    // Forget the fragment: replace the current history entry with the bare address.
    try { history.replaceState(null, '', location.pathname + location.search); } catch (_) { /* ignore */ }

    section.hidden = false;
    if (result.kind === 'invite') {
      const link = INVITE_SCHEME + result.payload;
      open.href = link;
      open.hidden = false;
      copy.hidden = false;
      field.value = link;
      field.parentElement.hidden = false;
      title.textContent = 'You’ve been invited to connect on Antenna';
      status.textContent = '';
    } else {
      open.hidden = true;
      copy.hidden = true;
      field.value = '';
      field.parentElement.hidden = true;
      title.textContent = 'This invite link looks damaged';
      status.textContent = 'Part of the link seems to be missing or changed. Ask your contact to send it again, and copy it in full.';
    }
    window.scrollTo(0, 0);
    title.setAttribute('tabindex', '-1');
    title.focus({ preventScroll: true });
  }

  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      try { await navigator.clipboard.writeText(text); return true; } catch (_) { /* fall back */ }
    }
    const field = $('invite-link');
    field.focus();
    field.select();
    try { return document.execCommand('copy'); } catch (_) { return false; }
  }

  function checkFragment() {
    const frag = location.hash.slice(1);
    if (!frag) return;
    const result = parseInvite(frag);
    if (result.kind !== 'none') showInvite(result);
  }

  function initInvite() {
    const copy = $('invite-copy');
    if (copy) {
      copy.addEventListener('click', async () => {
        const ok = await copyText($('invite-link').value);
        $('invite-copy-status').textContent = ok
          ? 'Copied. Paste it into Antenna where it asks for an invite link.'
          : 'Could not copy automatically — select the link above and copy it.';
      });
    }
    checkFragment();
    window.addEventListener('hashchange', checkFragment);
  }

  // 2. Closed-beta form.
  // Proof-of-work: find n such that SHA-256("antenna-beta/v1|ts|email|n") starts with DIFFICULTY zero
  // bits. ~33 000 hashes on average: about a second in a browser, real cost for a spam bot.
  // The worker (src/worker.js) checks the same rule with one hash.
  const DIFFICULTY = 15;
  const enc = new TextEncoder();

  function zeroBits(bytes) {
    let bits = 0;
    for (const b of bytes) {
      if (b === 0) { bits += 8; continue; }
      bits += Math.clz32(b) - 24;
      break;
    }
    return bits;
  }

  async function solve(email) {
    const ts = Date.now();
    for (let n = 0; n < 1 << 26; n++) {
      const h = new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(`antenna-beta/v1|${ts}|${email}|${n}`)));
      if (zeroBits(h) >= DIFFICULTY) return { ts, nonce: n };
    }
    throw new Error('pow');
  }

  function initForm() {
    const form = $('beta-form');
    if (!form) return;
    const status = $('beta-status');
    const button = form.querySelector('button[type=submit]');
    const say = (text, kind) => { status.textContent = text; status.className = 'status' + (kind ? ' ' + kind : ''); };

    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const email = form.email.value.trim().toLowerCase();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) { say('Please enter a valid email address.', 'err'); form.email.focus(); return; }
      if (!form.consent.checked) { say('Please confirm the consent checkbox — without it we cannot store your request.', 'err'); form.consent.focus(); return; }
      if (!window.crypto || !crypto.subtle) { say('Your browser cannot run the spam check. Please write to hello@antenna.contact instead.', 'err'); return; }

      button.disabled = true;
      say('Checking that you are not a bot…');
      try {
        const pow = await solve(email);
        say('Sending…');
        const body = {
          email,
          agents: [...form.querySelectorAll('input[name=agents]:checked')].map((i) => i.value),
          agents_other: form.agents_other.value.trim(),
          scenario: form.scenario.value.trim(),
          consent: true,
          website: form.website.value,
          pow,
        };
        const res = await fetch('/api/beta', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(body),
          credentials: 'omit',
          cache: 'no-store',
          referrerPolicy: 'no-referrer',
        });
        let data = {};
        try { data = await res.json(); } catch (_) { /* empty */ }
        if (res.ok && data.ok) {
          form.reset();
          say('Thank you — your request is in. We will write to you from hello@antenna.contact.', 'ok');
        } else if (res.status === 429) {
          say('Too many requests from your network. Please try again in a minute.', 'err');
        } else {
          say(typeof data.error === 'string' ? data.error : 'Something went wrong. Please try again, or write to hello@antenna.contact.', 'err');
        }
      } catch (_) {
        say('Could not send the request. Check your connection and try again.', 'err');
      } finally {
        button.disabled = false;
      }
    });
  }

  initInvite();
  initForm();
})();
