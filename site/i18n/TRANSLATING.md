# Translating antenna.contact

How a language of antenna.contact is written. The mechanics are in `docs/SITE.md`, "Languages"; this file is the brief
for the person (or tool) writing one language. Read it in full before starting.

## What you produce

Everything goes under `site/i18n/<code>/` (the codes are in `site/build/langs.mjs`). Touch nothing else.

| File | From the English | Notes |
| --- | --- | --- |
| `strings.json` | `site/i18n/en/strings.json` | same keys; translate the values; keep the HTML inside `ctaText` and `hubLead` (and the link's address) |
| `index.html` | `site/public/index.html` | the home page |
| `privacy.html` | `site/public/privacy.html` | plus one extra line, below |
| `404.html` | `site/public/404.html` | |
| `guides/<slug>.html` (16) | `site/guides/<slug>.html` | a different header, below |

Write `strings.json` first (the check needs it), then the pages. When all are written, run from the repository root:

```
node site/build/site.mjs --verify <code>
```

It must print `site: <code> ok (20 pages)`. Fix every error it prints and run it again. Do not run the build without
`--verify` (other languages are being written at the same time), do not edit files outside `site/i18n/<code>/`, and do
not commit.

## The pages: same markup, your words

Copy the English file and change **only the words**:

- **Text between tags**: translate.
- **Attribute values people read or search engines show**: translate `alt`, `aria-label`, `title`, `placeholder`,
  and the `content` of `<meta name="description">`, `og:title`, `og:description`, `og:image:alt`. Keep `<title>` and
  `description` short: the title under about 60 characters where you can, the description at most 160.
- **JSON-LD** (`<script type="application/ld+json">` on the home page): translate the `description` value only.
- **Everything else stays exactly as in English**: every tag, its order, `id`, `class`, `href`, `src`, `srcset`,
  `type`, `width`, `height`, `hidden`; the marker comments `<!-- i18n -->…` and `<!-- lang -->…` (leave them empty, as
  they are); `<html lang="en">` (the build sets the language). Links keep their English address (`/privacy`,
  `/#download`, `/guides/run-claude-code-on-a-vps`): the build points them at your language. Do not add, remove,
  split or merge elements; if a sentence reads better in another order, reorder words inside the same element.
- **Never translate**: product and program names (Antenna, Claude Code, Codex, ChatGPT, Claude Desktop, Cursor,
  Gemini CLI, MCP, tmux, iroh, libsignal, llama.cpp, Qwen3.5, Hugging Face, Homebrew, systemd, Touch ID), commands and
  everything in `<code>`, `<pre>` and `.mono`, file paths, addresses, version numbers, protocol names (`X25519MLKEM768`,
  PQXDH, SPQR, QUIC, TLS), `©` lines, the e-mail address.
- **The app's own words.** Bold labels (**Agents → AI apps**, **New contact → Invite**, **This is my own computer
  (∞)**, **Connect**, trust levels such as **Observer** or **Partner**) are the names of buttons and screens in the
  Antenna app, and the app speaks your language (`apps/antenna_desktop/lib/l10n/app_<code>.arb`; Arabic is the
  exception, below). Write exactly what the app shows: find the English text in
  `apps/antenna_desktop/lib/l10n/app_en.arb`, take the same key from `app_<code>.arb`, and write that, in bold. Where
  one English word has several keys (**Connect** next to an app is `appsConnect`, on the map `mapConnectAction`), find
  the key the screen uses in `apps/antenna_desktop/lib/`. Quoted app texts (a notification, a status line) follow the
  same rule. Text the app types into another program ("Approved — continue.") and the menus of other programs
  (Claude Code, Cursor, macOS) stay as those programs show them.
  - **Arabic (`ar`)**: the app has no Arabic yet. Keep the label in English, in bold, exactly as the app shows it; you
    may add a short translation in parentheses the first time.
- **Privacy page**: add one line at the very end of the text, right after the "← Back to antenna.contact" paragraph and
  before `  </div>\n</main>`:

  ```html
      <p class="i18n-note" data-i18n-extra>…This page is a translation. If it differs from the <a href="https://antenna.contact/privacy">English version</a>, the English version applies.…</p>
  ```

  (written in your language; keep the absolute link). It is the only element you add anywhere.

## The guides: a different header

A translated guide starts with one header line, then the body:

```
<!--guide {"title": "…", "h1": "…", "description": "…", "summary": "…", "source": "2026-11-09"}-->
<p class="lead">…
```

- `source`: copy the English guide's `"updated"` value exactly (it records which English text you translated).
- `title`: at most **70 characters**, ending like the English one (` — Antenna`) when it fits. `description`: at most
  **160 characters**. Both are what a search result shows: write them around the words people in your language type
  for this question (the English `"query"` says what the question is), not a word-for-word copy of the English title.
- `h1`: the page's heading, natural in your language. `summary`: one line for the guides hub.
- The body follows the page rules above (same markup, links unchanged).

## How it should read

- **Write as a good native copywriter of your language would, before AI existed.** Plain, warm, concrete; the way
  people of that language write about software. Not a word-for-word carry-over: English marketing devices (two-word
  "X without Y" slogans, headings chopped into sentences with full stops, "Clear promises. Honest limits.") read as
  machine-written in most languages. Say the same thing the way it is said in your language.
- **Address the reader** as the language's apps do: Russian «вы», Ukrainian «ви», German *Sie*, French *vous*,
  Turkish *siz*, Hindi आप, Japanese です/ます, Korean 해요체; Spanish, Italian, Portuguese (Brazil) and Polish the
  informal form; Chinese 你. Never mix forms on one site.
- **Portuguese** is Brazilian Portuguese. **Chinese** is Simplified. **Arabic** is Modern Standard Arabic; numbers in
  Western digits.
- **Same facts, no more, no less.** Translate what the English says. Add no claims, drop no limits ("Experimental",
  "not yet", "early"), keep every number. Where the English names something that does not exist yet, it says "not
  yet": keep that.
- **Technical terms**: use the term developers of your language actually use (many keep the English: "prompt
  injection", "end-to-end", "peer-to-peer" are often kept or half-kept; follow common usage in your language's tech
  press, and be consistent across all pages).

## When you are done

Report: the language, `--verify` output, and anything you were unsure about (a term, a sentence you could not make
natural without changing the markup). Do not report the translations themselves.
