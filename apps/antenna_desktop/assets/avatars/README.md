<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Drawn profile pictures

Animal pictures a person can choose for themselves or for one of their agents (Settings → Profile → Your picture).
They were drawn for Antenna and are part of the application, under its license (AGPL-3.0-only).

| File | What |
| --- | --- |
| `sets.json` | the manifest: each set's id and English name, its animals in grid order with their English names |
| `<set>/<animal>-512.webp` | the picture at 512 × 512 (the picker, the contact card) |
| `<set>/<animal>-128.webp` | the same at 128 × 128 (lists, the conversation) |
| `<set>/cover-128.webp` | the set's icon for the picker's tabs, 128 × 128 with transparency |

A chosen picture travels to contacts as its id only (`set1/fox`): every Antenna draws it from its own copy, and an id
it does not know is shown as initials. Russian names live in the window's Russian localization (`pictureAnimal`,
`pictureSet` in `lib/l10n/app_ru.arb`).

The files are made by `tools/avatars.py` from the original drawings (large square PNGs, one folder per set, and a
`covers` folder with one icon per set, kept outside the repository): square, metadata stripped, WebP of at most 60 KB
at 512 px. Adding a set is putting its folder next to the others and running `python3 tools/avatars.py --src
<folder>`; `python3 tools/avatars.py --check` checks the committed files, and `python3 tools/avatars_test.py` tests
the script.
