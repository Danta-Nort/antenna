// SPDX-License-Identifier: AGPL-3.0-only
//! Teams for humans (`antenna team …`, `antenna task …`, CONTROL §25). What a worker or a check wrote (reports, notes,
//! check output, diffs) is an agent's text: quoted or escaped like any agent's (SPEC §9).

use antenna_proto::control::{
    CapacityInfo, CheckRun, TaskDiff, TaskFact, TaskInfo, TeamInfo, TeamLogEntry, WorkerInfo,
    WorkerOutput,
};

use super::{clean, clean_text, quote};

fn short(c: &str) -> &str {
    &c[..12.min(c.len())]
}

fn ceiling(c: Option<u8>) -> String {
    c.map_or("none".into(), |c| c.to_string())
}

/// One line of a team.
fn team_line(t: &TeamInfo) -> String {
    format!(
        "{:<16} {:<7} lead {:<16} {} → {}  workers {}/{}  apply by {}",
        clean(&t.name),
        t.state,
        clean(t.lead.as_deref().unwrap_or("(you)")),
        t.integration,
        t.target,
        t.workers.iter().filter(|w| w.state != "stopped").count(),
        t.max_workers,
        t.template.apply
    )
}

/// `team_list`.
pub(super) fn teams(ts: &[TeamInfo]) {
    if ts.is_empty() {
        outln!(
            "no teams: `antenna team create <name> --project <folder> --lead <agent> --slot coder:claude:2`"
        );
    }
    for t in ts {
        outln!("{}", team_line(t));
    }
}

/// `team_show`, `team_create`, `team_info`.
pub(super) fn team(t: &TeamInfo) {
    outln!("{}", team_line(t));
    outln!("  project {}", clean(&t.project));
    if let Some(c) = &t.integration_commit {
        outln!("  {} at {}", t.integration, short(c));
    }
    for s in &t.slots {
        outln!(
            "  slot {}/{} ×{}{}{}",
            clean(&s.role),
            s.kind,
            s.max,
            s.model
                .as_deref()
                .map(|m| format!(" {}", clean(m)))
                .unwrap_or_default(),
            if s.argv.is_empty() {
                String::new()
            } else {
                format!(" `{}`", clean(&s.argv.join(" ")))
            }
        );
    }
    let tpl = &t.template;
    outln!(
        "  workers run commands: {}; checks: {}; check hosts: {}",
        if tpl.commands {
            "yes (within their ceiling)"
        } else {
            "no"
        },
        if tpl.checks.is_empty() {
            "none".to_string()
        } else {
            tpl.checks
                .iter()
                .map(|c| format!("`{}`", clean(&c.join(" "))))
                .collect::<Vec<_>>()
                .join(", ")
        },
        if tpl.check_hosts.is_empty() {
            "none (no network)".to_string()
        } else {
            tpl.check_hosts.join(", ")
        }
    );
    if tpl.local_only {
        outln!("  local only: no cloud worker, no cloud lead");
    }
    if let Some(r) = &t.apply_request {
        outln!(
            "  {} asks to apply {} to {}: `antenna team apply {}`",
            clean(&r.by),
            short(&r.commit),
            t.target,
            clean(&t.name)
        );
    }
    for w in &t.workers {
        outln!("  {}", worker_line(w));
    }
    for k in &t.tasks {
        outln!("  {}", task_line(k));
    }
}

fn worker_line(w: &WorkerInfo) -> String {
    format!(
        "worker {:<24} {:<8} {}/{}{} ceiling {}{}{}",
        clean(&w.name),
        w.state,
        clean(&w.role),
        w.kind,
        w.model
            .as_deref()
            .map(|m| format!(" {}", clean(m)))
            .unwrap_or_default(),
        ceiling(w.ceiling),
        w.task
            .as_deref()
            .map(|t| format!("  task {t}"))
            .unwrap_or_default(),
        if w.detail.is_empty() {
            String::new()
        } else {
            format!("  ({})", clean(&w.detail))
        }
    )
}

/// `worker_spawn`, `worker_stop`, `team_add_worker`.
pub(super) fn worker(w: &WorkerInfo) {
    outln!("{}", worker_line(w));
}

fn task_line(t: &TaskInfo) -> String {
    format!(
        "task {} {:<9} {}{}{}{}",
        t.id,
        t.state,
        clean(&t.title),
        t.assignee
            .as_deref()
            .map(|a| format!("  → {}", clean(a)))
            .unwrap_or_default(),
        t.check_run
            .as_ref()
            .map(|c| format!("  check {}", c.outcome))
            .unwrap_or_default(),
        t.ceiling
            .map(|c| format!("  ceiling {c}"))
            .unwrap_or_default()
    )
}

/// `task_list`.
pub(super) fn tasks(ts: &[TaskInfo]) {
    if ts.is_empty() {
        outln!("no tasks");
    }
    for t in ts {
        outln!("{}", task_line(t));
    }
}

/// One task in full.
pub(super) fn task(t: &TaskInfo) {
    outln!("{}", task_line(t));
    outln!(
        "  by {}, round {}, {} tokens",
        clean(&t.created_by),
        t.round,
        t.tokens
    );
    if !t.check.is_empty() {
        outln!("  check `{}`", clean(&t.check.join(" ")));
    }
    if !t.brief.is_empty() {
        outln!("  brief:\n{}", quote(&t.brief));
    }
    if let Some(r) = &t.result {
        if r.commit.is_empty() {
            outln!("  result: text");
        } else {
            outln!(
                "  result {} on {} ({} files, +{} -{}), ceiling {}",
                short(&r.commit),
                r.branch,
                r.files,
                r.insertions,
                r.deletions,
                ceiling(r.ceiling)
            );
        }
    }
    if let Some(r) = &t.report {
        outln!("  {} reported {}:", clean(&r.by), r.state);
        if !r.summary.is_empty() {
            outln!("{}", quote(&r.summary));
        }
    }
    for r in &t.reviews {
        outln!("  review by {}: {}", clean(&r.by), r.verdict);
        if !r.comments.is_empty() {
            outln!("{}", quote(&r.comments));
        }
    }
    if let Some(c) = &t.check_run {
        check_run(c);
    }
    if let Some(a) = &t.applied {
        outln!("  applied as {}", short(a));
    }
    if !t.notes.is_empty() {
        outln!("  notes:\n{}", quote(&t.notes));
    }
}

/// `run_check`.
pub(super) fn check_run(c: &CheckRun) {
    outln!(
        "  check `{}` {} (exit {}) in {} ms, {} sandbox, by {}{}",
        clean(&c.argv.join(" ")),
        c.outcome,
        c.exit_code.map_or("none".into(), |e| e.to_string()),
        c.duration_ms,
        c.sandbox,
        clean(&c.by),
        c.commit
            .as_deref()
            .map(|x| format!(", commit {}", short(x)))
            .unwrap_or_default()
    );
    if !c.blocked_hosts.is_empty() {
        outln!(
            "  the proxy refused: {}",
            clean(&c.blocked_hosts.join(", "))
        );
    }
    if !c.output.is_empty() {
        outln!("{}", quote(&c.output));
    }
}

/// `task_diff`.
pub(super) fn diff(d: &TaskDiff) {
    outln!(
        "task {}: {} → {}",
        d.task,
        short(&d.base),
        d.commit.as_deref().map_or("(folder)", short)
    );
    outln!("{}", clean_text(&d.stat));
    outln!("{}", clean_text(&d.diff));
    if d.truncated {
        outln!("(the diff was cut at 256 KiB)");
    }
}

/// `capacity`.
pub(super) fn capacity(c: &CapacityInfo) {
    outln!(
        "team {}: {}/{} workers",
        clean(&c.team),
        c.workers,
        c.max_workers
    );
    for m in &c.machines {
        outln!(
            "  {}: {} sandbox, {}/{} workers{}",
            clean(&m.name),
            m.sandbox,
            m.workers,
            m.max_workers,
            if m.local_models.is_empty() {
                String::new()
            } else {
                format!(", local models {}", m.local_models.join(", "))
            }
        );
        for s in &m.slots {
            outln!(
                "    {}/{} {}/{}{}",
                clean(&s.role),
                s.kind,
                s.used,
                s.max,
                s.unavailable
                    .as_deref()
                    .map(|u| format!(" (unavailable: {})", clean(u)))
                    .unwrap_or_default()
            );
        }
    }
}

/// `team_log`.
pub(super) fn log(entries: &[TeamLogEntry]) {
    for e in entries {
        outln!(
            "{} {:<18} {:<14} {:<18} {}{}",
            e.ts,
            clean(&e.actor),
            e.action,
            e.decision,
            e.task
                .as_deref()
                .map(|t| format!("task {t} "))
                .unwrap_or_default(),
            clean(&e.detail)
        );
    }
}

/// `antenna team watch` for humans: each worker's text after `<worker> › ` as it comes, a worker's start, tools and
/// end in brackets on lines of their own. The text is the worker's output: escaped like any agent's.
#[derive(Default)]
pub struct WatchView {
    /// The worker whose text line is open.
    open: Option<String>,
}

impl WatchView {
    /// What to print for one `worker_output` event.
    pub fn render(&mut self, w: &WorkerOutput) -> String {
        let who = clean(&w.worker);
        let on_task = w
            .task
            .as_deref()
            .map(|t| format!(" on task {}", clean(t)))
            .unwrap_or_default();
        match w.part.as_str() {
            "snapshot" => {
                let mut s = self.notice(&format!("{who} is in turn {}{on_task}; so far:", w.turn));
                s += &self.text(&w.worker, &w.text);
                s
            }
            "start" => self.notice(&format!("{who} started turn {}{on_task}", w.turn)),
            "text" => self.text(&w.worker, &w.text),
            "activity" => match w.text.strip_prefix("tool:") {
                Some(tool) => self.notice(&format!("{who} uses {}", clean(tool))),
                None => self.notice(&format!("{who} {}", clean(&w.text))),
            },
            "end" => self.notice(&format!("{who} finished: {}", clean(&w.text))),
            other => self.notice(&format!("{who}: {}", clean(other))),
        }
    }

    /// `lagged`: pieces were dropped.
    pub fn lagged(&mut self, missed: u64) -> String {
        self.notice(&format!(
            "missed {missed} pieces: watch again for the text so far"
        ))
    }

    fn notice(&mut self, s: &str) -> String {
        let mut out = self.close();
        out += &format!("[{s}]\n");
        out
    }

    fn close(&mut self) -> String {
        if self.open.take().is_some() {
            "\n".into()
        } else {
            String::new()
        }
    }

    fn text(&mut self, worker: &str, text: &str) -> String {
        let mut out = String::new();
        for (i, line) in clean_text(text).split('\n').enumerate() {
            if i > 0 {
                out.push('\n');
                self.open = None;
            }
            if line.is_empty() {
                continue;
            }
            if self.open.as_deref() != Some(worker) {
                out += &self.close();
                out += &format!("{} › ", clean(worker));
                self.open = Some(worker.into());
            }
            out.push_str(line);
        }
        out
    }
}

/// Task facts in `wait`.
pub(super) fn facts(fs: &[TaskFact]) {
    for f in fs {
        outln!(
            "team {}: task {} {} (now {}){}",
            clean(&f.team),
            f.task,
            f.change,
            f.state,
            f.assignee
                .as_deref()
                .map(|a| format!(", {}", clean(a)))
                .unwrap_or_default()
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn piece(worker: &str, part: &str, text: &str) -> WorkerOutput {
        WorkerOutput {
            team: "web".into(),
            worker: worker.into(),
            task: Some("0123456789abcdef".into()),
            turn: 2,
            part: part.into(),
            text: text.into(),
        }
    }

    /// Pieces of one worker continue its line; another worker's text and every notice start a line of their own; a
    /// worker's terminal sequences are escaped.
    #[test]
    fn a_watch_reads_as_lines_per_worker() {
        let mut v = WatchView::default();
        let out: String = [
            piece("web.coder-1", "start", ""),
            piece("web.coder-1", "text", "Reading "),
            piece("web.coder-1", "text", "the code.\nNext"),
            piece("web.docs-1", "text", "Docs \u{1b}[2J"),
            piece("web.coder-1", "activity", "tool:Bash"),
            piece("web.coder-1", "end", "done"),
        ]
        .iter()
        .map(|p| v.render(p))
        .collect();
        assert_eq!(
            out,
            "[web.coder-1 started turn 2 on task 0123456789abcdef]\n\
             web.coder-1 › Reading the code.\n\
             web.coder-1 › Next\n\
             web.docs-1 › Docs \\u{1b}[2J\n\
             [web.coder-1 uses Bash]\n\
             [web.coder-1 finished: done]\n"
        );
        let s = v.render(&piece("web.coder-1", "snapshot", "so far"));
        assert_eq!(
            s,
            "[web.coder-1 is in turn 2 on task 0123456789abcdef; so far:]\nweb.coder-1 › so far"
        );
        assert!(v.lagged(3).starts_with("\n[missed 3 pieces"));
    }
}
