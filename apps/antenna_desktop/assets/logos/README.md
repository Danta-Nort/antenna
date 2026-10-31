<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# AI app marks

The marks in this folder belong to their owners:

| File | Mark | Owner |
| --- | --- | --- |
| `claude.svg` | Claude | Anthropic, PBC |
| `claudecode.svg` | Claude Code | Anthropic, PBC |
| `cursor.svg` | Cursor | Anysphere, Inc. |
| `zedindustries.svg` | Zed | Zed Industries, Inc. |
| `lmstudio.svg` | LM Studio | Element Labs, Inc. |

Antenna shows them only to identify the app an agent runs in (Agents → AI apps, the Connect dialog, an agent's
avatar), small, next to the app's name. Showing a mark does not mean that its owner endorses, sponsors or is affiliated
with Antenna.

The SVG path data comes from [Simple Icons](https://simpleicons.org) 16.33.0 (CC0-1.0 for the SVG data; Simple Icons
notes that this "doesn't mean to imply that all icons within the project are also CC0" and asks users to seek the
correct permissions). Each mark is drawn in its owner's colour on light tiles and in the owner's white or the same
colour on dark tiles, never redrawn or recoloured otherwise. Source URLs, licences, the date checked and the brands
shown as a neutral monogram instead (OpenAI, Google Gemini, VS Code, Devin Desktop, xAI) are in `sources.json`; the
reasons and the vendors' guidelines are quoted in `docs/CONNECT-APPS.md`, "Marks".

`build.py` generates `lib/theme/ai_logos.dart` from `sources.json` and these files; run it after any change.
