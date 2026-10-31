<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Vendor configuration schemas (test fixtures)

Parts of the JSON schemas the vendors publish for the files Connect writes, downloaded 2026-10-03 and used by
`test/host/mcp_config_test.dart` to validate the generated files (with Python's `jsonschema`, when installed; each
test also checks that a wrong entry is rejected). They belong to their publishers; refresh them when a vendor changes
its format.

| File | Source | Kept | Validates |
| --- | --- | --- | --- |
| `codex-config.schema.json` | https://learn.chatgpt.com/docs/config-schema.json (redirect target of https://developers.openai.com/codex/config-schema.json) | `model`, `mcp_servers` | `~/.codex/config.toml` (Codex, the ChatGPT desktop app), parsed with `tomllib` |
| `gemini-settings.schema.json` | https://raw.githubusercontent.com/google-gemini/gemini-cli/main/schemas/settings.schema.json (Apache-2.0) | `mcpServers`, `ui` | `~/.gemini/settings.json` (Gemini CLI) |

`strip.py` made them from the downloaded files: it keeps the top-level properties listed above, the definitions they
reference, and the schema's top-level keywords (`additionalProperties: false` stays), and removes descriptions and
titles. Every validation keyword it keeps is unchanged, so a file whose parts are valid here is valid against the full
schema. To refresh: download the schema and run `python3 strip.py <downloaded> <fixture> <property>…`.

The other apps publish no schema for their MCP files (`docs/CONNECT-APPS.md`); their entries are checked against the
shapes in the vendors' documentation.
