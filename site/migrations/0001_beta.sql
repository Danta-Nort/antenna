-- SPDX-License-Identifier: Apache-2.0
-- Closed-beta requests from the form on antenna.contact (src/worker.js, POST /api/beta).
-- Only what the person typed, plus timestamps and the consent version. No IP, no user agent.
CREATE TABLE IF NOT EXISTS beta_requests (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  email           TEXT    NOT NULL UNIQUE,
  agents          TEXT    NOT NULL DEFAULT '',   -- comma-separated keys: claude-code,codex,cursor,mcp-other,own,none
  agents_other    TEXT    NOT NULL DEFAULT '',
  scenario        TEXT    NOT NULL DEFAULT '',
  consent_version TEXT    NOT NULL,              -- e.g. privacy-2026-10-02 (date of public/privacy.html)
  created_at      TEXT    NOT NULL,              -- ISO 8601 UTC
  updated_at      TEXT    NOT NULL,
  submissions     INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS beta_requests_created ON beta_requests (created_at);
