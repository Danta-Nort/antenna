// SPDX-License-Identifier: Apache-2.0
//! The catalog of local models (D-96 phase 2, `docs/LOCAL-ASSISTANT.md` §2.3): which open-weight model files a release
//! of Antenna knows, where each comes from (a Hugging Face repository at a fixed commit), and how to check it (its exact
//! size and SHA-256). One file, `packaging/models.json`, is compiled into the daemon ([`Catalog::builtin`]) and copied
//! into the signed release manifest as its optional `models` field (`docs/UPDATES.md` §2); the release tool checks that
//! the two are equal. A hash fetched at run time is never trusted: the expected SHA-256 comes from the release.
//!
//! Parsing is strict (unknown fields are refused) because the file is ours and shipped with the release; the manifest's
//! copy is read by older versions as a field they do not know and ignore.

use serde::{Deserialize, Serialize};

/// The catalog compiled into this build (`packaging/models.json`).
pub const BUILTIN_JSON: &str = include_str!("../../../packaging/models.json");

/// The only host the catalog's files come from, and the base of their addresses.
pub const HUB: &str = "https://huggingface.co";

/// The largest model file a catalog may list (64 GiB).
pub const MAX_MODEL_BYTES: u64 = 64 << 30;

/// The catalog: the runtime it was tested with and the models.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Catalog {
    /// Format version (1).
    pub version: u32,
    /// The runtime build the catalog was tested with.
    pub runtime: RuntimeRef,
    /// The models, smallest first.
    pub models: Vec<CatalogModel>,
}

/// The runtime the catalog was tested with (llama.cpp's `llama-server`, built by us from this tag).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RuntimeRef {
    /// Name.
    pub name: String,
    /// Release tag of the source.
    pub tag: String,
    /// The tag's commit (40 hex digits).
    pub commit: String,
    /// SPDX license.
    pub license: String,
}

/// One model file of the catalog.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CatalogModel {
    /// Stable ID (`qwen3.5-2b`): `[a-z0-9.-]`, 1–32 characters.
    pub id: String,
    /// Display name.
    pub name: String,
    /// Model family: models of one family share a prompt format.
    pub family: String,
    /// Who made the weights.
    pub maker: String,
    /// SPDX license of the weights.
    pub license: String,
    /// The license text.
    pub license_url: String,
    /// Languages, in a few words.
    pub languages: String,
    /// Parameters (`2.27B`).
    pub params: String,
    /// Roles the model may take: `chat` now; `assistant` and `worker` later (design §8.4).
    pub roles: Vec<String>,
    /// Hugging Face repository (`owner/name`).
    pub repo: String,
    /// The repository commit the file is taken from (40 hex digits): never a branch.
    pub commit: String,
    /// File name in the repository (`*.gguf`).
    pub file: String,
    /// Exact size, bytes.
    pub size: u64,
    /// SHA-256 of the file (64 lowercase hex digits).
    pub sha256: String,
    /// Quantization (`Q4_K_M`).
    pub quant: String,
    /// Context per conversation, tokens.
    pub context: u32,
    /// Memory in use with one conversation at `context` on the CPU build (weights, the CPU's repacked copy of them,
    /// cache and buffers), bytes; measured on the Linux build server (`docs/LOCAL-ASSISTANT.md` §10).
    pub memory: u64,
    /// The same with Metal on Apple silicon (no repacked copy), bytes; an estimate until measured on a Mac.
    pub memory_metal: u64,
    /// Memory for each further conversation served at the same time (one more slot of `context`), bytes.
    pub slot_memory: u64,
    /// Whether the model thinks before it answers (off for chat in this release: it would double the wait on a CPU).
    pub thinking: bool,
    /// The official chat template the runtime is started with, instead of the one the quantizer embedded (design
    /// §2.2): shipped next to the runtime and pinned here by hash.
    pub chat_template: TemplateRef,
}

/// A chat template file shipped with the release.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TemplateRef {
    /// File name next to the runtime.
    pub file: String,
    /// Its SHA-256.
    pub sha256: String,
    /// Where it comes from (`Qwen/Qwen3.5-2B@<commit>`).
    pub source: String,
}

/// Why a catalog was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogError(pub String);

impl std::fmt::Display for CatalogError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "model catalog: {}", self.0)
    }
}

impl std::error::Error for CatalogError {}

fn hex_of_len(s: &str, n: usize) -> bool {
    s.len() == n && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn safe_file(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && !s.starts_with('.')
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

fn safe_repo(s: &str) -> bool {
    let mut parts = s.split('/');
    let ok = |p: Option<&str>| {
        p.is_some_and(|p| {
            !p.is_empty()
                && p.len() <= 96
                && !p.starts_with('.')
                && p.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        })
    };
    ok(parts.next()) && ok(parts.next()) && parts.next().is_none()
}

/// A catalog model ID: `[a-z0-9.-]`, 1–32 characters, starting with a letter or digit.
pub fn valid_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 32
        && s.bytes().next().is_some_and(|b| b.is_ascii_alphanumeric())
        && s.bytes()
            .all(|b| matches!(b, b'a'..=b'z' | b'0'..=b'9' | b'.' | b'-'))
}

impl Catalog {
    /// Parses and checks a catalog (strict).
    pub fn parse(json: &str) -> Result<Catalog, CatalogError> {
        let c: Catalog = serde_json::from_str(json).map_err(|e| CatalogError(e.to_string()))?;
        c.validate()?;
        Ok(c)
    }

    /// The catalog compiled into this build.
    pub fn builtin() -> Result<Catalog, CatalogError> {
        Catalog::parse(BUILTIN_JSON)
    }

    /// The model with this ID.
    pub fn get(&self, id: &str) -> Option<&CatalogModel> {
        self.models.iter().find(|m| m.id == id)
    }

    /// Checks every field a download, a check or a runtime start relies on.
    pub fn validate(&self) -> Result<(), CatalogError> {
        let bad = |m: &str, what: &str| Err(CatalogError(format!("{m}: {what}")));
        if self.version != 1 {
            return Err(CatalogError(format!(
                "format version {} is not supported",
                self.version
            )));
        }
        if !hex_of_len(&self.runtime.commit, 40) {
            return bad("runtime", "the commit must be 40 lowercase hex digits");
        }
        if self.models.is_empty() || self.models.len() > 64 {
            return Err(CatalogError("1–64 models".into()));
        }
        let mut seen = std::collections::HashSet::new();
        for m in &self.models {
            let id = m.id.as_str();
            if !valid_id(id) {
                return bad(id, "the ID must be 1–32 characters of [a-z0-9.-]");
            }
            if !seen.insert(id) {
                return bad(id, "the ID is listed twice");
            }
            if !safe_repo(&m.repo) {
                return bad(id, "the repository must be owner/name");
            }
            if !hex_of_len(&m.commit, 40) {
                return bad(id, "the commit must be 40 lowercase hex digits");
            }
            if !safe_file(&m.file) || !m.file.ends_with(".gguf") {
                return bad(id, "the file must be a plain *.gguf name");
            }
            if !hex_of_len(&m.sha256, 64) {
                return bad(id, "sha256 must be 64 lowercase hex digits");
            }
            if m.size == 0 || m.size > MAX_MODEL_BYTES {
                return bad(id, "the size must be 1 byte … 64 GiB");
            }
            if !(512..=131_072).contains(&m.context) {
                return bad(id, "the context must be 512…131072 tokens");
            }
            if m.memory < m.size || m.memory_metal < m.size {
                return bad(
                    id,
                    "the memory needed cannot be smaller than the file it maps",
                );
            }
            if !m.license_url.starts_with("https://") {
                return bad(id, "the license URL must be https://");
            }
            if !safe_file(&m.chat_template.file) || !hex_of_len(&m.chat_template.sha256, 64) {
                return bad(
                    id,
                    "the chat template needs a plain file name and its sha256",
                );
            }
            if m.roles.is_empty() || m.roles.iter().any(|r| r != "chat") {
                return bad(id, "roles: only `chat` in this format version");
            }
        }
        Ok(())
    }
}

impl CatalogModel {
    /// The file's immutable address on the hub: `<hub>/<repo>/resolve/<commit>/<file>` (`hub` is [`HUB`] outside
    /// tests).
    pub fn url(&self, hub: &str) -> String {
        format!(
            "{}/{}/resolve/{}/{}",
            hub.trim_end_matches('/'),
            self.repo,
            self.commit,
            self.file
        )
    }

    /// Memory for `slots` conversations served at once, on Metal (`metal`) or the CPU.
    pub fn memory_for(&self, slots: u32, metal: bool) -> u64 {
        let base = if metal {
            self.memory_metal
        } else {
            self.memory
        };
        base.saturating_add(
            self.slot_memory
                .saturating_mul(u64::from(slots.saturating_sub(1))),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_builtin_catalog_is_valid_and_pins_files_by_commit_and_hash() {
        let c = Catalog::builtin().unwrap();
        assert_eq!(c.runtime.tag, "v0.6.0");
        let ids: Vec<&str> = c.models.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, ["qwen3.5-2b", "qwen3.5-4b", "qwen3.5-9b"]);
        let m = c.get("qwen3.5-2b").unwrap();
        assert_eq!(m.size, 1_280_835_840);
        assert_eq!(
            m.url(HUB),
            "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf"
        );
        // Sizes grow with the model; each needs more memory than its file.
        for w in c.models.windows(2) {
            assert!(w[0].size < w[1].size && w[0].memory < w[1].memory);
        }
        assert_eq!(m.memory_for(1, false), m.memory);
        assert_eq!(m.memory_for(3, false), m.memory + 2 * m.slot_memory);
        assert_eq!(m.memory_for(1, true), m.memory_metal);
    }

    #[test]
    fn a_catalog_that_could_lead_a_download_astray_is_refused() {
        let good = Catalog::builtin().unwrap();
        let check = |f: &dyn Fn(&mut CatalogModel)| {
            let mut c = good.clone();
            f(&mut c.models[0]);
            c.validate().unwrap_err()
        };
        check(&|m| m.commit = "main".into());
        check(&|m| m.file = "../../.ssh/id_ed25519".into());
        check(&|m| m.file = "model.bin".into());
        check(&|m| m.repo = "unsloth/../../x".into());
        check(&|m| m.repo = "https://evil.example/x".into());
        check(&|m| m.sha256 = "AAF42C8B".into());
        check(&|m| m.size = 0);
        check(&|m| m.id = "Qwen 2B".into());
        check(&|m| m.memory = 1);
        check(&|m| m.chat_template.file = "../t.jinja".into());
        check(&|m| m.roles = vec!["worker".into()]);
        let mut twice = good.clone();
        twice.models.push(twice.models[0].clone());
        twice.validate().unwrap_err();
        // Unknown fields are refused: the file is ours.
        let extra =
            BUILTIN_JSON.replacen("\"version\": 1,", "\"version\": 1, \"mirror\": \"x\",", 1);
        Catalog::parse(&extra).unwrap_err();
    }
}
