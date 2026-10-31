// SPDX-License-Identifier: AGPL-3.0-only
//! Local models and local agents for humans (`antenna local …`, CONTROL §24). A model's reply is text from a model:
//! escaped like an agent's (line breaks and tabs stay).

use antenna_proto::control::{
    LocalAgentInfo, LocalHistoryReply, LocalModelInfo, LocalModelsReply, LocalTurn, LocalUsage,
};

use super::{clean, clean_text};

fn gb(b: u64) -> String {
    format!("{:.1} GB", b as f64 / 1e9)
}

/// `12 tokens/s`, from the runtime's numbers.
pub(super) fn speed(u: &LocalUsage) -> String {
    let rate = |n: u64, ms: u64| {
        if ms == 0 {
            "–".to_string()
        } else {
            format!("{:.1}", n as f64 * 1000.0 / ms as f64)
        }
    };
    format!(
        "prompt {} tokens ({} cached) at {} tokens/s, reply {} tokens at {} tokens/s",
        u.prompt_tokens,
        u.cached_tokens,
        rate(u.prompt_tokens, u.prompt_ms),
        u.output_tokens,
        rate(u.output_tokens, u.output_ms)
    )
}

fn model_line(m: &LocalModelInfo) -> String {
    let state = match m.state.as_str() {
        "downloading" => format!(
            "downloading {} of {}{}",
            gb(m.done_bytes),
            gb(m.size_bytes),
            m.speed_bytes_per_s
                .map(|s| format!(" at {:.0} MB/s", s as f64 / 1e6))
                .unwrap_or_default()
        ),
        "verifying" => format!(
            "checking the file ({} of {})",
            gb(m.done_bytes),
            gb(m.size_bytes)
        ),
        "failed" => format!(
            "failed ({}): {}",
            m.error_code.as_deref().unwrap_or("error"),
            clean(m.error.as_deref().unwrap_or(""))
        ),
        other => other.to_string(),
    };
    format!(
        "{:<12} {:<11} {:>7} download, {:>7} memory  {:<11} {}{}",
        m.id,
        m.name,
        gb(m.size_bytes),
        gb(m.memory_bytes),
        m.fit,
        state,
        if m.loaded { ", loaded" } else { "" }
    )
}

fn agent_line(a: &LocalAgentInfo) -> String {
    format!(
        "{:<16} on {:<12} {} ({}), {} turns{}{}",
        clean(&a.name),
        a.model,
        a.state,
        a.runtime,
        a.turns,
        a.last_usage
            .as_ref()
            .map(|u| format!(", last: {}", speed(u)))
            .unwrap_or_default(),
        if a.detail.is_empty() {
            String::new()
        } else {
            format!(" — {}", clean(&a.detail))
        }
    )
}

/// `local models`.
pub(super) fn models(r: &LocalModelsReply) {
    let h = &r.hardware;
    outln!(
        "This computer: {} ({} cores, {}), {} memory, {} available, local models may use {}; {} free on disk",
        if h.cpu.is_empty() { &h.arch } else { &h.cpu },
        h.cores,
        h.accel,
        gb(h.memory_bytes),
        gb(h.available_bytes),
        gb(h.budget_bytes),
        gb(h.disk_free_bytes)
    );
    if r.runtime.available {
        outln!(
            "Runtime: {}, sandbox {}",
            r.runtime.version,
            r.runtime.sandbox
        );
    } else {
        outln!("Runtime: not available — {}", clean(&r.runtime.detail));
    }
    outln!("Models:");
    for m in &r.models {
        outln!("  {}", model_line(m));
        if m.fit != "recommended" && m.fit != "fits" {
            outln!("      {}", clean(&m.fit_detail));
        }
    }
    if r.agents.is_empty() {
        outln!("Local agents: none (antenna local add <name> --model <id>)");
    } else {
        outln!("Local agents:");
        for a in &r.agents {
            outln!("  {}", agent_line(a));
        }
    }
}

/// `local install`, `local remove`.
pub(super) fn model(m: &LocalModelInfo) {
    outln!("{}", model_line(m));
}

/// `local add`, `local session`.
pub(super) fn agent(a: &LocalAgentInfo) {
    outln!("{}", agent_line(a));
}

/// `local say`: the text was printed as it streamed; here only the end of the turn.
pub(super) fn turn(t: &LocalTurn) {
    if !t.text.is_empty() && !t.text.ends_with('\n') {
        outln!();
    }
    eprintln!(
        "turn {}: {}{}{}",
        t.turn,
        t.outcome,
        t.usage
            .as_ref()
            .map(|u| format!(", {}", speed(u)))
            .unwrap_or_default(),
        if t.detail.is_empty() {
            String::new()
        } else {
            format!(" — {}", clean(&t.detail))
        }
    );
}

/// `local history`.
pub(super) fn history(h: &LocalHistoryReply) {
    if h.more {
        outln!(
            "(older messages: antenna local history {} --before {})",
            clean(&h.agent),
            h.items.first().map_or(0, |i| i.seq)
        );
    }
    for i in &h.items {
        let who = if i.role == "owner" {
            "you".to_string()
        } else {
            clean(&h.agent)
        };
        let outcome = match i.outcome.as_deref() {
            Some("done") | None => String::new(),
            Some(o) => format!(" [{o}]"),
        };
        outln!("{who}{outcome}: {}", clean_text(&i.text));
    }
}
