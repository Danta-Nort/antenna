// SPDX-License-Identifier: Apache-2.0
// Builds the generated parts of antenna.contact in every language:  node build/site.mjs [--check]
//
// Sources
//   public/index.html, privacy.html, 404.html   the English pages, written by hand; this script only fills their
//                                               <!-- i18n --> (head) and <!-- lang --> (header) blocks
//   site/guides/<slug>.html                     the English guides: a <!--guide {JSON}--> header line and the body
//   site/i18n/<code>/strings.json               a language's interface words (en included); its presence puts the
//                                               language on the site
//   site/i18n/<code>/{index,privacy,404}.html   a language's copy of each English page: the same markup, its own words,
//                                               links as on the English page (this script points them at the language)
//   site/i18n/<code>/guides/<slug>.html         a language's guide: <!--guide {"title","h1","description","summary",
//                                               "source"}--> ("source": the English "updated" it was translated from)
// Output
//   public/<code>/…, public/guides/…, public/<code>/guides/…, the whole sitemap.xml (with hreflang alternates), and the
//   guides block of llms.txt (English).
// Rules it enforces (and --check, which build/check.mjs runs, fails on): every page of the site exists in every language
// on the site; a translation keeps the markup of its English page element by element (tags, ids, classes, links, the
// same order), only words differ; headers within limits; generated files up to date. A translation made from an older
// English page is reported as a warning (the English page was edited since).
import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { LANGS as ALL_LANGS } from './langs.mjs';

const ORIGIN = 'https://antenna.contact';
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const pub = join(root, 'public');
const i18n = join(root, 'i18n');
const checkOnly = process.argv.includes('--check');
// --verify <code>: check one language's sources only (headers, markup, every page present) and write nothing; for
// translators working on several languages at once, before the language is built.
const verifyAt = process.argv.indexOf('--verify');
const verifyCode = verifyAt > 0 ? process.argv[verifyAt + 1] : null;
const errors = [];
const warnings = [];

const read = (f) => readFileSync(f, 'utf8');
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const text = (html) => html.replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<')
  .replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;|&rsquo;|’/g, '’').replace(/\s+/g, ' ').trim();
const sha = (s) => createHash('sha256').update(s).digest('hex').slice(0, 16);

// The languages on the site: those with a strings file. English is always first.
const LANGS = verifyCode
  ? ALL_LANGS.filter((l) => l.code === 'en' || l.code === verifyCode)
  : ALL_LANGS.filter((l) => existsSync(join(i18n, l.code, 'strings.json')));
if (verifyCode && (verifyCode === 'en' || LANGS.length !== 2)) { console.error(`site: --verify needs a language code of build/langs.mjs other than en`); process.exit(2); }
if (verifyCode && !existsSync(join(i18n, verifyCode, 'strings.json'))) { console.error(`site: FAILED\n  i18n/${verifyCode}/strings.json is missing`); process.exit(1); }
const STR = Object.fromEntries(LANGS.map((l) => [l.code, JSON.parse(read(join(i18n, l.code, 'strings.json')))]));
for (const l of LANGS) {
  for (const k of Object.keys(STR.en)) if (!(k in STR[l.code])) errors.push(`i18n/${l.code}/strings.json lacks "${k}"`);
  for (const k of Object.keys(STR.en.js)) if (!(k in (STR[l.code].js ?? {}))) errors.push(`i18n/${l.code}/strings.json lacks "js.${k}"`);
}
const url = (code, path) => (code === 'en' ? path : `/${code}${path}`);
const longDate = (l, iso) => new Date(`${iso}T00:00:00Z`).toLocaleDateString(l.dateLocale, { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' });

// ---------- shared pieces ----------

// Pages that exist in every language; a link to one of them from a language's page goes to that language's copy.
const isPage = (p) => p === '/' || p === '/privacy' || p === '/guides/' || /^\/guides\/[a-z0-9-]+$/.test(p);
const localize = (html, code) => (code === 'en' ? html : html.replace(/(<a\b[^>]*?\bhref=")(\/[^"#?]*)([#?][^"]*)?"/g,
  (m, pre, path, rest = '') => (isPage(path) ? `${pre}/${code}${path}${rest}"` : m)));

const GLOBE = '<svg viewBox="0 0 20 20" width="18" height="18" aria-hidden="true" focusable="false"><circle cx="10" cy="10" r="7.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M2.5 10h15M10 2.5c2.2 2.1 3.2 4.6 3.2 7.5S12.2 15.4 10 17.5M10 2.5C7.8 4.6 6.8 7.1 6.8 10s1 5.4 3.2 7.5" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>';
// The switcher: the same page in each language (path null: the home page, as for 404).
const switcher = (l, path) => LANGS.length < 2 ? '' : `    <details class="lang">
      <summary aria-label="${esc(STR[l.code].language)}: ${esc(l.name)}">${GLOBE}<span class="lang-code">${l.code.toUpperCase()}</span></summary>
      <ul class="lang-menu">
${LANGS.map((o) => `        <li><a href="${url(o.code, path ?? '/')}" hreflang="${o.hreflang}" lang="${o.hreflang}"${o.code === l.code ? ' aria-current="true"' : ''}>${esc(o.name)}</a></li>`).join('\n')}
      </ul>
    </details>
`;
// hreflang alternates and og:locale; path null (404): no alternates.
const alternates = (l, path) => {
  const out = [`<meta property="og:locale" content="${l.locale}">`];
  if (path !== null && LANGS.length > 1) {
    for (const o of LANGS) out.push(`<link rel="alternate" hreflang="${o.hreflang}" href="${ORIGIN}${url(o.code, path)}">`);
    out.push(`<link rel="alternate" hreflang="x-default" href="${ORIGIN}${path}">`);
  }
  return out.join('\n');
};
const fillBlock = (html, open, close, block, where) => {
  const a = html.indexOf(open), b = html.indexOf(close);
  if (a < 0 || b < a) { errors.push(`${where}: the markers ${open} … ${close} are missing`); return html; }
  return html.slice(0, a + open.length) + '\n' + block + html.slice(b);
};
// Strip what may differ between languages and compare the rest of the markup, element by element.
const KEPT = new Set(['id', 'class', 'href', 'src', 'srcset', 'type', 'name', 'for', 'rel', 'property', 'width', 'height', 'datetime', 'hidden', 'open']);
const skeleton = (html, code) => {
  const s = html
    .replace(/<!-- i18n -->[\s\S]*?<!-- \/i18n -->/, '').replace(/<!-- lang -->[\s\S]*?<!-- \/lang -->/, '')
    .replace(/<script type="application\/(ld\+)?json"[^>]*>[\s\S]*?<\/script>/g, '')
    .replace(/<([a-z0-9]+)\b[^>]*\bdata-i18n-extra\b[^>]*>[\s\S]*?<\/\1>/g, '')
    .replace(/<!--[\s\S]*?-->/g, '');
  const out = [];
  for (const m of s.matchAll(/<([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>/g)) {
    const tag = m[1].toLowerCase();
    const attrs = {};
    // Attribute by attribute, so words inside a value (alt, aria-label) are never read as attributes.
    for (const a of m[2].matchAll(/\s([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*"([^"]*)")?/g)) {
      if (!KEPT.has(a[1])) continue;
      let v = a[2] ?? '';
      if (a[1] === 'href' && code !== 'en') v = v.replace(new RegExp(`^/${code}(?=/)`), '');
      if (tag === 'html' || (tag === 'link' && /canonical|alternate/.test(m[2])) || (tag === 'meta' && a[1] === 'property' && v === 'og:url')) continue;
      attrs[a[1]] = v;
    }
    if (tag === 'meta' && /property="og:url"/.test(m[2])) { out.push('meta og:url'); continue; }
    out.push(`${tag} ${JSON.stringify(attrs)}`);
  }
  return out;
};
const sameMarkup = (en, tr, code, where) => {
  const a = skeleton(en, 'en'), b = skeleton(tr, code);
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) { errors.push(`${where}: markup differs from English at element ${i + 1}: English «${a[i] ?? 'end'}», here «${b[i] ?? 'end'}»`); return; }
  }
};

const files = {}; // path under public/ → content

// ---------- the hand-written pages (home, privacy, 404) ----------

const PAGES = [{ file: 'index.html', path: '/' }, { file: 'privacy.html', path: '/privacy' }, { file: '404.html', path: null }];
const sources = {}; // what each translation was made from, by English page: the hash is in i18n/<code>/sources.json
for (const { file, path } of PAGES) {
  const enSrc = read(join(pub, file));
  sources[file] = sha(enSrc.replace(/<!-- i18n -->[\s\S]*?<!-- \/i18n -->/, '').replace(/<!-- lang -->[\s\S]*?<!-- \/lang -->/, ''));
  for (const l of LANGS) {
    const where = l.code === 'en' ? `public/${file}` : `i18n/${l.code}/${file}`;
    let html = l.code === 'en' ? enSrc : (existsSync(join(i18n, l.code, file)) ? read(join(i18n, l.code, file)) : null);
    if (html === null) { errors.push(`${where} is missing: every page must exist in every language on the site`); continue; }
    if (l.code !== 'en') {
      sameMarkup(enSrc, html, l.code, where);
      html = html.replace(/<html lang="[^"]*"( dir="[^"]*")?>/, `<html lang="${l.hreflang}"${l.dir ? ` dir="${l.dir}"` : ''}>`);
      html = localize(html, l.code);
      if (path !== null) {
        html = html.replace(/(<link rel="canonical" href=")[^"]*"/, `$1${ORIGIN}${url(l.code, path)}"`)
          .replace(/(<meta property="og:url" content=")[^"]*"/, `$1${ORIGIN}${url(l.code, path)}"`);
      }
      // JSON-LD: this language's address and language.
      html = html.replace(/(<script type="application\/ld\+json">)([\s\S]*?)(<\/script>)/, (m, a, json, b) => {
        try {
          const d = JSON.parse(json);
          if (d.url) d.url = `${ORIGIN}${url(l.code, path ?? '/')}`;
          d.inLanguage = l.hreflang;
          return `${a}\n${JSON.stringify(d, null, 2)}\n${b}`;
        } catch (e) { errors.push(`${where}: JSON-LD does not parse: ${e.message}`); return m; }
      });
    }
    let block = alternates(l, path);
    if (file === 'index.html' && l.code !== 'en') block += `\n<script type="application/json" id="i18n">${JSON.stringify(STR[l.code].js)}</script>`;
    html = fillBlock(html, '<!-- i18n -->', '<!-- /i18n -->', block + '\n', where);
    html = fillBlock(html, '    <!-- lang -->', '    <!-- /lang -->', switcher(l, path), where);
    files[l.code === 'en' ? file : `${l.code}/${file}`] = html;
  }
}
// --stamp <code>: record that this language's pages now match the English ones (after translating a change).
const stampAt = process.argv.indexOf('--stamp');
if (stampAt > 0) {
  const code = process.argv[stampAt + 1];
  if (!LANGS.some((l) => l.code === code && code !== 'en')) { errors.push(`--stamp: "${code}" is not a translated language on the site`); fail(); }
  writeFileSync(join(i18n, code, 'sources.json'), JSON.stringify(sources, null, 2) + '\n');
}
for (const l of LANGS) {
  if (l.code === 'en') continue;
  const f = join(i18n, l.code, 'sources.json');
  const was = existsSync(f) ? JSON.parse(read(f)) : {};
  for (const { file } of PAGES) if (was[file] !== sources[file]) warnings.push(`i18n/${l.code}/${file}: the English page changed since it was translated (sources.json); translate the change`);
}

// ---------- guides ----------

const parseGuide = (f, where) => {
  const raw = read(f);
  const m = /^<!--guide (\{[\s\S]*?\})-->\n/.exec(raw);
  if (!m) { errors.push(`${where}: no <!--guide {…}--> header on the first line`); return null; }
  return { meta: JSON.parse(m[1]), body: raw.slice(m[0].length).trim() };
};
const enGuides = readdirSync(join(root, 'guides')).filter((f) => f.endsWith('.html')).sort().map((f) => {
  const g = parseGuide(join(root, 'guides', f), `guides/${f}`);
  return g && { slug: f.slice(0, -5), body: g.body, ...g.meta };
}).filter(Boolean).sort((a, b) => (a.order ?? 99) - (b.order ?? 99) || a.slug.localeCompare(b.slug));
const bySlug = Object.fromEntries(enGuides.map((g) => [g.slug, g]));

const checkHeader = (g, where) => {
  if (g.description?.length > 160) errors.push(`${where}: description is ${g.description.length} characters (160 at most)`);
  if (g.title && g.title.length > 70) errors.push(`${where}: title is ${g.title.length} characters (70 at most)`);
  if (/<h1[\s>]/i.test(g.body)) errors.push(`${where}: the body has its own <h1> (the page makes it from "h1")`);
  if (!/^<p class="lead">/.test(g.body)) errors.push(`${where}: the body must open with <p class="lead">, the quotable answer`);
};
for (const g of enGuides) {
  for (const k of ['title', 'h1', 'description', 'query', 'updated', 'related', 'summary']) if (!(k in g)) errors.push(`guides/${g.slug}: header lacks "${k}"`);
  if (!/^\d{4}-\d\d-\d\d$/.test(g.updated ?? '')) errors.push(`guides/${g.slug}: "updated" is not YYYY-MM-DD`);
  checkHeader(g, `guides/${g.slug}`);
  for (const r of g.related ?? []) if (!bySlug[r] || r === g.slug) errors.push(`guides/${g.slug}: related "${r}" is not another guide`);
}
// Each language's guides: words from the translation, everything else (order, dates, related) from English.
const guidesOf = {};
for (const l of LANGS) {
  guidesOf[l.code] = enGuides.map((en) => {
    if (l.code === 'en') return en;
    const where = `i18n/${l.code}/guides/${en.slug}.html`;
    const f = join(i18n, l.code, 'guides', `${en.slug}.html`);
    if (!existsSync(f)) { errors.push(`${where} is missing: every page must exist in every language on the site`); return null; }
    const t = parseGuide(f, where);
    if (!t) return null;
    for (const k of ['title', 'h1', 'description', 'summary', 'source']) if (!(k in t.meta)) errors.push(`${where}: header lacks "${k}"`);
    if (t.meta.source !== en.updated) warnings.push(`${where}: translated from the English of ${t.meta.source}, the English is of ${en.updated}; translate the change`);
    const g = { ...en, title: t.meta.title, h1: t.meta.h1, description: t.meta.description, summary: t.meta.summary, body: t.body };
    checkHeader(g, where);
    sameMarkup(en.body, t.body, l.code, where);
    return g;
  });
  if (l.code !== 'en' && existsSync(join(i18n, l.code, 'guides'))) {
    for (const f of readdirSync(join(i18n, l.code, 'guides'))) if (!bySlug[f.slice(0, -5)]) errors.push(`i18n/${l.code}/guides/${f} has no English guide`);
  }
}
if (errors.length) fail();

const faqOf = (body) => [...body.matchAll(/<details>\s*<summary>([\s\S]*?)<\/summary>([\s\S]*?)<\/details>/g)]
  .map(([, q, a]) => ({ '@type': 'Question', name: text(q), acceptedAnswer: { '@type': 'Answer', text: text(a) } }));
const crumbs = (items) => ({
  '@type': 'BreadcrumbList',
  itemListElement: items.map(([name, path], i) => ({ '@type': 'ListItem', position: i + 1, name, item: ORIGIN + path })),
});

const head = (l, { title, description, path, ld }) => `<!doctype html>
<html lang="${l.hreflang}"${l.dir ? ` dir="${l.dir}"` : ''}>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<link rel="canonical" href="${ORIGIN}${url(l.code, path)}">
<meta name="color-scheme" content="light">
<meta name="theme-color" content="#FFFFFF">
<meta name="referrer" content="no-referrer">
<meta property="og:type" content="article">
<meta property="og:site_name" content="Antenna">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${ORIGIN}${url(l.code, path)}">
<meta property="og:image" content="${ORIGIN}/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
${alternates(l, path)}
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="stylesheet" href="/assets/site.css?v=7">
<script type="application/ld+json">
${JSON.stringify(ld, null, 1)}
</script>
</head>
<body>
<a class="skip" href="#main">${esc(STR[l.code].skip)}</a>
<header class="top">
  <div class="wrap top-row">
    <a class="brand" href="${url(l.code, '/')}" aria-label="${esc(STR[l.code].home)}"><img src="/assets/mark-blue.svg" alt="" width="26" height="35"><span class="wordmark">Antenna</span></a>
    <nav class="nav" aria-label="${esc(STR[l.code].mainNav)}">
      <a href="${url(l.code, '/')}#product">${esc(STR[l.code].navProduct)}</a>
      <a href="${url(l.code, '/')}#security">${esc(STR[l.code].navSecurity)}</a>
      <a href="${url(l.code, '/guides/')}">${esc(STR[l.code].navGuides)}</a>
    </nav>
${switcher(l, path)}    <a class="btn btn-small top-cta" href="${url(l.code, '/')}#download">${esc(STR[l.code].download)}</a>
  </div>
</header>
`;

const foot = (l) => `<footer class="foot">
  <div class="wrap foot-row">
    <a class="brand brand-small" href="${url(l.code, '/')}" aria-label="${esc(STR[l.code].home)}"><img src="/assets/mark-blue.svg" alt="" width="18" height="24"><span class="wordmark">Antenna</span></a>
    <p><a href="${url(l.code, '/guides/')}">${esc(STR[l.code].navGuides)}</a></p>
    <p><a href="https://github.com/Danta-Nort/antenna">GitHub</a></p>
    <p>${esc(STR[l.code].footContact)} <a href="mailto:hello@antenna.contact">hello@antenna.contact</a></p>
    <p><a href="${url(l.code, '/privacy')}">${esc(STR[l.code].footPrivacy)}</a></p>
    <p class="copy">© 2026 Stillbyte LLC</p>
  </div>
</footer>
</body>
</html>
`;

const latest = enGuides.map((g) => g.updated).sort().at(-1) ?? '2026-11-14';
for (const l of LANGS) {
  const S = STR[l.code];
  const gs = guidesOf[l.code];
  const byS = Object.fromEntries(gs.map((g) => [g.slug, g]));
  const dir = l.code === 'en' ? 'guides' : `${l.code}/guides`;
  for (const g of gs) {
    const path = `/guides/${g.slug}`;
    const faq = faqOf(g.body);
    const graph = [
      crumbs([['Antenna', url(l.code, '/')], [S.navGuides, url(l.code, '/guides/')], [g.h1, url(l.code, path)]]),
      {
        '@type': 'TechArticle', headline: g.h1, description: g.description, datePublished: g.published ?? g.updated,
        dateModified: g.updated, inLanguage: l.hreflang, url: ORIGIN + url(l.code, path), image: `${ORIGIN}/og.png`,
        author: { '@type': 'Organization', name: 'Stillbyte LLC', url: ORIGIN + '/' },
        publisher: { '@type': 'Organization', name: 'Stillbyte LLC', url: ORIGIN + '/' },
        about: { '@type': 'SoftwareApplication', name: 'Antenna', url: ORIGIN + url(l.code, '/') },
      },
    ];
    if (faq.length) graph.push({ '@type': 'FAQPage', mainEntity: faq });
    const related = g.related.map((r) => `      <li><a href="${url(l.code, `/guides/${r}`)}">${esc(byS[r].h1)}</a></li>`).join('\n');
    const body = localize(g.body, l.code);
    files[`${dir}/${g.slug}.html`] = head(l, { title: g.title, description: g.description, path, ld: { '@context': 'https://schema.org', '@graph': graph } })
      + `<main id="main" class="doc guide">
  <article class="wrap narrow">
    <nav class="crumbs" aria-label="${esc(S.breadcrumb)}"><a href="${url(l.code, '/')}">Antenna</a> <span aria-hidden="true">›</span> <a href="${url(l.code, '/guides/')}">${esc(S.navGuides)}</a></nav>
    <p class="eyebrow">${esc(S.updated)} <time datetime="${g.updated}">${longDate(l, g.updated)}</time></p>
    <h1>${esc(g.h1)}</h1>
${body.split('\n').map((x) => (x ? '    ' + x : x)).join('\n')}
    <aside class="guide-cta">
      <p>${S.ctaText}</p>
      <a class="btn" href="${url(l.code, '/')}#download">${esc(S.ctaButton)}</a>
    </aside>
    <h2>${esc(S.related)}</h2>
    <ul class="related">
${related}
    </ul>
  </article>
</main>
` + foot(l);
  }
  files[`${dir}/index.html`] = head(l, {
    title: S.hubTitle, description: S.hubDescription, path: '/guides/',
    ld: { '@context': 'https://schema.org', '@graph': [crumbs([['Antenna', url(l.code, '/')], [S.navGuides, url(l.code, '/guides/')]]), {
      '@type': 'CollectionPage', name: S.hubName, url: `${ORIGIN}${url(l.code, '/guides/')}`, inLanguage: l.hreflang, dateModified: latest,
      hasPart: gs.map((g) => ({ '@type': 'TechArticle', headline: g.h1, url: `${ORIGIN}${url(l.code, `/guides/${g.slug}`)}` })),
    }] },
  }) + `<main id="main" class="doc guide">
  <div class="wrap narrow">
    <nav class="crumbs" aria-label="${esc(S.breadcrumb)}"><a href="${url(l.code, '/')}">Antenna</a></nav>
    <h1>${esc(S.hubH1)}</h1>
    <p class="lead">${S.hubLead}</p>
    <ul class="guide-list">
${gs.map((g) => `      <li><a href="${url(l.code, `/guides/${g.slug}`)}">${esc(g.h1)}</a><p>${esc(g.summary)}</p></li>`).join('\n')}
    </ul>
  </div>
</main>
` + foot(l);
}

// ---------- sitemap (every page in every language, with its alternates) and llms.txt ----------

// The hand-written pages' last change; set it when you edit one.
const LASTMOD = { '/': '2026-11-14', '/privacy': '2026-11-05' };
const entry = (path, lastmod) => LANGS.map((l) => [
  `  <url><loc>${ORIGIN}${url(l.code, path)}</loc><lastmod>${lastmod}</lastmod>`,
  ...(LANGS.length > 1 ? [...LANGS.map((o) => `    <xhtml:link rel="alternate" hreflang="${o.hreflang}" href="${ORIGIN}${url(o.code, path)}"/>`),
    `    <xhtml:link rel="alternate" hreflang="x-default" href="${ORIGIN}${path}"/>`] : []),
  '  </url>'].join('\n')).join('\n');
files['sitemap.xml'] = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${[entry('/', LASTMOD['/']), entry('/privacy', LASTMOD['/privacy']), entry('/guides/', latest),
  ...enGuides.map((g) => entry(`/guides/${g.slug}`, g.updated))].join('\n')}
</urlset>
`;
const llms = read(join(pub, 'llms.txt'));
{
  const open = '## Guides', close = '\n## Security and design';
  const a = llms.indexOf(open), b = llms.indexOf(close);
  if (a < 0 || b < a) errors.push(`llms.txt: the markers ${open} … ${close} are missing`);
  else files['llms.txt'] = llms.slice(0, a + open.length) + '\n' + enGuides.map((g) => `- [${g.h1}](${ORIGIN}/guides/${g.slug}): ${g.summary}`).join('\n') + '\n' + llms.slice(b);
}

// ---------- write, or check ----------

if (verifyCode) {
  if (errors.length) fail();
  for (const w of warnings) console.warn(`site: warning: ${w}`);
  console.log(`site: ${verifyCode} ok (${Object.keys(files).filter((f) => f.startsWith(`${verifyCode}/`) && f.endsWith('.html')).length} pages)`);
  process.exit(0);
}

for (const [rel, body] of Object.entries(files)) {
  const f = join(pub, rel);
  const cur = existsSync(f) ? read(f) : null;
  if (cur === body) continue;
  if (checkOnly) errors.push(`public/${rel} is out of date: run node build/site.mjs`);
  else { mkdirSync(dirname(f), { recursive: true }); writeFileSync(f, body); }
}
// Generated folders hold only what this build makes: a page whose source is gone is an error (or removed by a build).
const generatedDirs = ['guides', ...ALL_LANGS.filter((l) => l.code !== 'en').map((l) => l.code)];
const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)]));
for (const d of generatedDirs) {
  if (!existsSync(join(pub, d))) continue;
  for (const f of walk(join(pub, d))) {
    const rel = f.slice(pub.length + 1);
    if (files[rel]) continue;
    if (checkOnly) errors.push(`public/${rel} has no source`);
    else rmSync(f);
  }
}

if (errors.length) fail();
for (const w of warnings) console.warn(`site: warning: ${w}`);
const pages = Object.keys(files).filter((f) => f.endsWith('.html')).length;
console.log(`site: ${checkOnly ? 'up to date' : 'built'} (${LANGS.map((l) => l.code).join(' ')}: ${pages} pages, ${enGuides.length} guides each)`);

function fail() { console.error('site: FAILED\n  ' + errors.join('\n  ')); process.exit(1); }
