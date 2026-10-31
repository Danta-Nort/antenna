// SPDX-License-Identifier: AGPL-3.0-only
//! Replies about updates that install by themselves (x-control/7, D-103) and the file-name check, for humans. A contact
//! label is escaped like everywhere in `output`.

use antenna_proto::control::{FileNameCheck, UpdateAutoInfo, UpdateRecord, UpdatedInfo};

use super::clean;

fn ago(at_ms: u64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let m = now.saturating_sub(at_ms) / 60_000;
    match m {
        0 => "just now".into(),
        1..=119 => format!("{m} min ago"),
        _ => format!("{} h ago", m / 60),
    }
}

fn source(src: &str, contact: Option<&str>) -> String {
    match (src, contact) {
        ("link", Some(c)) => format!("from {}", clean(c)),
        ("url", _) => "from the update URL".into(),
        (s, _) => format!("from {}", clean(s)),
    }
}

fn record(r: &UpdateRecord) -> String {
    let what = match r.result.as_str() {
        "installed" => format!(
            "installed {}{}{}",
            clean(&r.version),
            r.from
                .as_deref()
                .map(|f| format!(" (was {})", clean(f)))
                .unwrap_or_default(),
            match r.unlocked {
                Some(true) => ", keys kept",
                Some(false) => ", came up locked",
                None => "",
            }
        ),
        "failed" => format!("{} FAILED", clean(&r.version)),
        "refused" => format!("{} refused", clean(&r.version)),
        other => format!("{} {}", clean(&r.version), clean(other)),
    };
    format!(
        "{what} {}, {}{}",
        source(&r.source, r.contact.as_deref()),
        ago(r.at_ms),
        r.reason
            .as_deref()
            .map(|x| format!(": {}", clean(x)))
            .unwrap_or_default()
    )
}

/// `update_auto_*`.
pub(super) fn update_auto(u: &UpdateAutoInfo) {
    outln!(
        "Install signed updates by itself: {}{}",
        if u.enabled { "on" } else { "off" },
        if u.enabled && u.keys_kept {
            " (the keys will come across the update's restart)"
        } else if u.enabled {
            " (keys locked: the update will come up locked until you unlock)"
        } else {
            ""
        }
    );
    if !u.supported {
        outln!(
            "  this installation cannot replace itself: {}",
            clean(u.unsupported_reason.as_deref().unwrap_or("unknown"))
        );
    }
    match &u.url {
        Some(url) => outln!(
            "  update URL: {} (checked once a day{})",
            clean(url),
            u.last_check_ms
                .map(|t| format!(", last {}", ago(t)))
                .unwrap_or_default()
        ),
        None => {
            outln!("  update URL: not configured (release files from your level-5 computers only)")
        }
    }
    if let Some(s) = &u.staged {
        let when = match (s.state.as_str(), s.at_ms) {
            ("soon", Some(_)) => {
                "installs in a few minutes (antenna update --auto later postpones it)".to_string()
            }
            ("installing", _) => "installing now".into(),
            (_, Some(_)) => "postponed; then installs when agents are idle for 10 minutes".into(),
            _ => "installs when agents are idle for 10 minutes (antenna update --auto now)".into(),
        };
        outln!(
            "  staged: {} {}: {when}",
            clean(&s.version),
            source(&s.source, s.contact.as_deref())
        );
    }
    if !u.failed.is_empty() {
        outln!(
            "  not tried again by itself (failed here): {}",
            u.failed
                .iter()
                .map(|v| clean(v))
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    for r in u.history.iter().take(5) {
        outln!("  {}", record(r));
    }
}

/// `status.updated`.
pub(super) fn updated(u: &UpdatedInfo) {
    outln!(
        "updated by itself: {} → {} {}{}",
        clean(&u.from),
        clean(&u.to),
        ago(u.at_ms),
        if u.unlocked {
            ", keys kept"
        } else {
            ", came up locked"
        }
    );
}

/// `file_name_check`.
pub(super) fn file_name(f: &FileNameCheck) {
    match f.state.as_str() {
        "free" => outln!("{}: free", clean(&f.name)),
        "same_file" => outln!(
            "{}: the same file is already in the folder (accepting it saves nothing new)",
            clean(&f.name)
        ),
        "taken" => outln!(
            "{}: taken{}",
            clean(&f.name),
            f.suggestion
                .as_deref()
                .map(|s| format!("; free: {}", clean(s)))
                .unwrap_or_default()
        ),
        other => outln!(
            "{}: {}{}",
            clean(&f.name),
            clean(other),
            f.message
                .as_deref()
                .map(|m| format!(" ({})", clean(m)))
                .unwrap_or_default()
        ),
    }
}
