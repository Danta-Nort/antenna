<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Tools

Checks and generators used by contributors, CI and the release scripts. Each file starts with its usage.

| Tool | What it does |
| --- | --- |
| `check-darwin.sh` | Type check of the Rust code for macOS from Linux, without a Mac (with `darwin-check.toml`) |
| `check-windows.sh` | Type check of the Rust code for Windows (MSVC) from Linux (with `windows-check.toml`) |
| `mcp_smoke.py` | A live MCP round trip against built `antennad` and `antenna` binaries |
| `claude-canary.sh` | Code mode's wake against the real Claude Code on this computer; says when a Claude Code update breaks it |
| `fake-llama-server.py` | A stand-in for llama.cpp's `llama-server` in the tests of local models |
| `guide_check.py` | Checks `docs/guide/` against the window it documents and its screenshots (`guide_check_test.py`: its negative controls) |
| `guide_shots.py` | Copies the golden frames the guide uses from `docs/design/screens/` into `docs/guide/img/` |
| `readme_tour.py` | Builds the README's animated tour from the window's golden frames |
| `avatars.py` | Turns the drawn profile picture sets into the window's assets (`avatars_test.py`: its tests) |
| `watchlist_check.py` | The weekly check of the technologies listed in `docs/WATCHLIST.md` |
