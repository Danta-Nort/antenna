// SPDX-License-Identifier: Apache-2.0
//! Local models (x-control/7, `docs/CONTROL.md` §24; D-96 phase 2, D-104): the catalog with the hardware assessment,
//! verified downloads, and local agents, ordinary agents of this node whose program is our loop with a model that
//! runs on this computer, each in its own sandbox. Owner commands only: an agent has none of them.

use serde::{Deserialize, Serialize};

fn is_false(b: &bool) -> bool {
    !*b
}

/// The machine as the daemon reads it, without any permission or prompt (`docs/LOCAL-ASSISTANT.md` §2.4).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HardwareInfo {
    /// `linux`, `macos`.
    pub os: String,
    /// `x86_64`, `aarch64`.
    pub arch: String,
    /// The CPU's name (`Apple M2 Pro`, `AMD Ryzen 7 7840U`); empty when unknown.
    pub cpu: String,
    /// Physical cores (performance cores on Apple silicon).
    pub cores: u32,
    /// Hardware threads this process may use.
    pub threads: u32,
    /// x86-64 with AVX2 (a model runs too slowly without it); `false` elsewhere.
    #[serde(default, skip_serializing_if = "is_false")]
    pub avx2: bool,
    /// Where the model computes: `metal` (Apple silicon GPU) or `cpu`.
    pub accel: String,
    /// Total memory (or the cgroup's limit), bytes.
    pub memory_bytes: u64,
    /// Available now, bytes.
    pub available_bytes: u64,
    /// What local models may use now: the smaller of half the total and the available memory minus 1 GB, minus the
    /// models already loaded.
    pub budget_bytes: u64,
    /// Free space on the disk that holds the models, bytes.
    pub disk_free_bytes: u64,
}

/// The runtime this daemon starts models with.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalRuntimeInfo {
    /// The runtime and its sandbox are there: models can run.
    pub available: bool,
    /// `llama.cpp v0.6.0`; empty when the runtime is missing.
    pub version: String,
    /// The sandbox it runs in: `bwrap`, `landlock`, `seatbelt`, or `none`.
    pub sandbox: String,
    /// When not available: why (for the owner); otherwise what the sandbox closes.
    pub detail: String,
}

/// One model of the catalog and its state on this computer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalModelInfo {
    /// Catalog ID (`qwen3.5-2b`).
    pub id: String,
    /// Display name.
    pub name: String,
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
    /// Quantization (`Q4_K_M`).
    pub quant: String,
    /// Download size, bytes.
    pub size_bytes: u64,
    /// Memory in use on this computer with one conversation, bytes.
    pub memory_bytes: u64,
    /// Context per conversation, tokens.
    pub context: u32,
    /// Where the file comes from: `huggingface.co/<repo>@<commit>/<file>`.
    pub source: String,
    /// How it suits this computer: `recommended` (the one the daemon suggests), `fits`, `slow` (fits in memory but
    /// answers slowly here), `too_big` (needs more memory than local models may use now), `unsupported` (this
    /// computer runs no local model: below 8 GB of memory, or an x86-64 CPU without AVX2).
    pub fit: String,
    /// Facts behind `fit`, in English (the window shows its own text by `fit`).
    pub fit_detail: String,
    /// Expected generation speed here, tokens per second (an estimate from the memory bandwidth); absent when
    /// unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub est_tokens_per_s: Option<u32>,
    /// `available` (not on this computer), `downloading`, `verifying`, `ready`, `failed`.
    pub state: String,
    /// Bytes on disk so far (downloading, verifying: bytes checked).
    #[serde(default)]
    pub done_bytes: u64,
    /// Download speed, bytes per second (downloading only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speed_bytes_per_s: Option<u64>,
    /// `failed`: an error code (`hash_mismatch`, `no_space`, `fetch_failed`, `sandbox_unavailable`, …).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    /// `failed`: what happened, for the owner.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// The runtime holds this model in memory now.
    #[serde(default, skip_serializing_if = "is_false")]
    pub loaded: bool,
    /// Local agents that run on this model.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub agents: Vec<String>,
}

/// A local agent: an agent of this node whose program the daemon runs with a local model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalAgentInfo {
    /// Agent name (as in `agent_list`).
    pub name: String,
    /// Catalog ID of its model.
    pub model: String,
    /// `local`: this daemon launched the runtime itself. The "Local" badge is shown only for this value (D-96 §7.5).
    pub runtime: String,
    /// `sleeping` (no process), `waiting` (for memory: another model has to unload first), `loading` (the model is
    /// being loaded), `idle`, `busy` (a turn is running), `failed` (the next turn tries again), `no_model` (its
    /// model is not on this computer).
    pub state: String,
    /// Facts behind the state (the reason of a failure, what it waits for).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub detail: String,
    /// Turns so far (all conversations).
    pub turns: u64,
    /// When the last turn ended, Unix ms.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_turn_ms: Option<u64>,
    /// Tokens and time of the last turn (its speed is `output_tokens` over `output_ms`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_usage: Option<LocalUsage>,
    /// When it was created, Unix ms.
    pub created_ms: u64,
}

/// Tokens and time of one turn, as the runtime reports them.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalUsage {
    /// Prompt tokens the runtime read in this turn (not from its cache).
    pub prompt_tokens: u64,
    /// Prompt tokens taken from the runtime's cache of the conversation.
    #[serde(default)]
    pub cached_tokens: u64,
    /// Tokens generated.
    pub output_tokens: u64,
    /// Time spent reading the prompt, ms.
    #[serde(default)]
    pub prompt_ms: u64,
    /// Time spent generating, ms.
    #[serde(default)]
    pub output_ms: u64,
}

/// The end of a turn (`local_say`).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalTurn {
    /// Agent.
    pub agent: String,
    /// Turn number in the conversation.
    pub turn: u64,
    /// `done`, `interrupted`, `failed`.
    pub outcome: String,
    /// The whole reply (what was generated before an interrupt or a failure).
    pub text: String,
    /// What went wrong (`failed`), or empty.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub detail: String,
    /// Tokens and speed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<LocalUsage>,
}

impl std::fmt::Debug for LocalTurn {
    // Conversation text never reaches the logs.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "LocalTurn({}, {}, {}, {} bytes)",
            self.agent,
            self.turn,
            self.outcome,
            self.text.len()
        )
    }
}

/// One message of a local agent's conversation (`local_history`), kept in the node's encrypted database.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalItem {
    /// Order in the database.
    pub seq: i64,
    /// Turn number.
    pub turn: u64,
    /// Who wrote it: `owner` or `agent`.
    pub role: String,
    /// The text.
    pub text: String,
    /// Unix ms.
    pub ts_ms: u64,
    /// The agent's messages: `done`, `interrupted`, `failed`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<String>,
    /// The agent's messages that did not end `done`: why (for the owner).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// The agent's messages: tokens and speed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<LocalUsage>,
}

impl std::fmt::Debug for LocalItem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "LocalItem({}, {}, {} bytes)",
            self.seq,
            self.role,
            self.text.len()
        )
    }
}

/// `local_models`: the computer, the runtime, the catalog and the local agents.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalModelsReply {
    /// The computer.
    pub hardware: HardwareInfo,
    /// The runtime.
    pub runtime: LocalRuntimeInfo,
    /// The catalog of this release with each model's state here, smallest first.
    pub models: Vec<LocalModelInfo>,
    /// Local agents.
    pub agents: Vec<LocalAgentInfo>,
}

/// `local_history`: a page of a local agent's conversation, oldest first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalHistoryReply {
    /// Agent.
    pub agent: String,
    /// Messages, oldest first.
    pub items: Vec<LocalItem>,
    /// Older messages exist (ask again with `before` = the first `seq`).
    #[serde(default, skip_serializing_if = "is_false")]
    pub more: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::{Event, Reply, Request};

    #[test]
    fn requests_and_replies_round_trip() {
        for line in [
            r#"{"cmd":"local_models"}"#,
            r#"{"cmd":"model_install","model":"qwen3.5-2b"}"#,
            r#"{"cmd":"model_install","model":"qwen3.5-2b","from_file":"/media/usb/q.gguf"}"#,
            r#"{"cmd":"model_remove","model":"qwen3.5-2b"}"#,
            r#"{"cmd":"local_agent_add","name":"helper","model":"qwen3.5-2b","password":"pw"}"#,
            r#"{"cmd":"local_say","agent":"helper","text":"hi"}"#,
            r#"{"cmd":"local_say","agent":"helper","text":"stop","interrupt":true,"timeout_ms":5000}"#,
            r#"{"cmd":"local_history","agent":"helper","limit":50,"before":10}"#,
            r#"{"cmd":"local_session","agent":"helper","action":"reset"}"#,
        ] {
            let r: Request = serde_json::from_str(line).unwrap();
            assert!(r.name().starts_with("local_") || r.name().starts_with("model_"));
            assert_eq!(r.owner_password().is_some(), r.name() == "local_agent_add");
            let back = serde_json::to_string(&r).unwrap();
            assert_eq!(serde_json::from_str::<Request>(&back).unwrap(), r);
        }
        // Debug never shows the text.
        let say: Request =
            serde_json::from_str(r#"{"cmd":"local_say","agent":"a","text":"secret words"}"#)
                .unwrap();
        assert!(!format!("{say:?}").contains("secret"));
        let ev = Event::LocalDelta {
            agent: "a".into(),
            turn: 1,
            delta: "secret words".into(),
            activity: None,
        };
        assert!(!format!("{ev:?}").contains("secret"));
        let turn = Reply::LocalTurn(LocalTurn {
            agent: "a".into(),
            turn: 1,
            outcome: "done".into(),
            text: "secret words".into(),
            detail: String::new(),
            usage: Some(LocalUsage {
                prompt_tokens: 10,
                cached_tokens: 0,
                output_tokens: 5,
                prompt_ms: 100,
                output_ms: 164,
            }),
        });
        assert!(!format!("{turn:?}").contains("secret"));
        let j = serde_json::to_string(&turn).unwrap();
        assert!(j.starts_with(r#"{"type":"local_turn""#), "{j}");
        assert_eq!(serde_json::from_str::<Reply>(&j).unwrap(), turn);
    }

    #[test]
    fn unknown_fields_in_a_request_are_refused() {
        serde_json::from_str::<Request>(
            r#"{"cmd":"local_say","agent":"a","text":"x","as":"owner"}"#,
        )
        .unwrap_err();
    }
}
