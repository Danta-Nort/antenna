// SPDX-License-Identifier: AGPL-3.0-only
//! The pure rules of teams (D-111): the task state machine, a worker's grant (the intersection of the team's template,
//! the lead's ceiling and the machine's limits, which only ever narrows), the policy for a worker's commands and for
//! checks, and the choice of a slot. No I/O here, so every rule is unit-tested on its own.

use antenna_proto::control::{TeamSlot, TeamTemplate, task_state as st};

use crate::policy::{self, Action, Verdict};

/// Something that happens to a task.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Op {
    /// The lead or the owner gives it to a worker (also a reassignment).
    Assign,
    /// Its worker reports that it works on it.
    Working,
    /// Its worker asks the lead something.
    Blocked,
    /// Its worker submits a result.
    Submit,
    /// The daemon's check of a submitted result failed and the task goes back to the worker by itself.
    CheckFailed,
    /// The reviewer accepts the submitted result.
    Accept,
    /// The reviewer asks for changes (or answers a blocked worker).
    Changes,
    /// The owner's urgent changes (PG-58): the worker's turn is interrupted and the task returns to it now, also while
    /// it is being worked on.
    Redirect,
    /// The lead or the owner cancels it.
    Cancel,
    /// The accepted result is merged into the integration branch.
    Apply,
}

/// The state after `op`, or why `op` is not allowed in `state`.
pub(crate) fn next_state(state: &str, op: Op) -> Result<&'static str, String> {
    let ok = match (op, state) {
        (Op::Assign, st::OPEN | st::ASSIGNED | st::RETURNED | st::BLOCKED) => st::ASSIGNED,
        (Op::Working, st::ASSIGNED | st::WORKING | st::RETURNED | st::BLOCKED) => st::WORKING,
        (Op::Blocked, st::ASSIGNED | st::WORKING | st::RETURNED) => st::BLOCKED,
        (Op::Submit, st::ASSIGNED | st::WORKING | st::RETURNED | st::BLOCKED) => st::SUBMITTED,
        (Op::CheckFailed, st::SUBMITTED) => st::RETURNED,
        (Op::Accept, st::SUBMITTED) => st::ACCEPTED,
        // From `accepted` too: a result that no longer merges goes back to its worker.
        (Op::Changes, st::SUBMITTED | st::BLOCKED | st::ACCEPTED) => st::RETURNED,
        (
            Op::Redirect,
            st::ASSIGNED | st::WORKING | st::RETURNED | st::SUBMITTED | st::BLOCKED | st::ACCEPTED,
        ) => st::RETURNED,
        (
            Op::Cancel,
            st::OPEN
            | st::ASSIGNED
            | st::WORKING
            | st::BLOCKED
            | st::SUBMITTED
            | st::RETURNED
            | st::ACCEPTED,
        ) => st::CANCELLED,
        (Op::Apply, st::ACCEPTED) => st::DONE,
        _ => {
            return Err(format!(
                "the task is {state}: {} needs it {}",
                op_name(op),
                needs(op)
            ));
        }
    };
    Ok(ok)
}

fn op_name(op: Op) -> &'static str {
    match op {
        Op::Assign => "assigning",
        Op::Working => "a working report",
        Op::Blocked => "a blocked report",
        Op::Submit => "submitting",
        Op::CheckFailed => "returning after a check",
        Op::Accept => "accepting",
        Op::Changes => "asking for changes",
        Op::Redirect => "urgent changes",
        Op::Cancel => "cancelling",
        Op::Apply => "applying",
    }
}

fn needs(op: Op) -> &'static str {
    match op {
        Op::Assign => "open, assigned, returned or blocked",
        Op::Working | Op::Submit => "assigned, working, returned or blocked",
        Op::Blocked => "assigned, working or returned",
        Op::CheckFailed | Op::Accept => "submitted",
        Op::Changes => "submitted, blocked or accepted",
        Op::Redirect => "assigned, working, returned, submitted, blocked or accepted",
        Op::Cancel => "not done or cancelled yet",
        Op::Apply => "accepted",
    }
}

/// Whether a task in this state is finished (nothing changes it any more).
pub(crate) fn is_final(state: &str) -> bool {
    matches!(state, st::DONE | st::CANCELLED)
}

/// Whether a task in this state keeps its worker busy (the worker takes no other task meanwhile).
pub(crate) fn holds_worker(state: &str) -> bool {
    matches!(
        state,
        st::ASSIGNED | st::WORKING | st::BLOCKED | st::RETURNED | st::SUBMITTED
    )
}

/// The lower of two ceilings; `None` is no ceiling at all (a session that read no contact's data).
pub(crate) fn min_ceiling(a: Option<u8>, b: Option<u8>) -> Option<u8> {
    match (a, b) {
        (Some(x), Some(y)) => Some(x.min(y)),
        (x, None) => x,
        (None, y) => y,
    }
}

/// What this machine lends to teams: here the computer the daemon runs on. Remote machines (WP5) bring their own,
/// and the receiving daemon applies them again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Machine {
    /// Workers of all teams at once.
    pub max_workers: u32,
    /// Workers may run commands here at all.
    pub commands: bool,
    /// The longest turn this machine allows, seconds.
    pub max_turn_secs: u64,
    /// The longest check this machine allows, seconds.
    pub max_check_secs: u64,
}

/// The machine this daemon runs on: eight workers at once, commands allowed (each in its sandbox), at most an hour
/// per turn and per check.
pub(crate) const THIS_COMPUTER: Machine = Machine {
    max_workers: 8,
    commands: true,
    max_turn_secs: 3600,
    max_check_secs: 3600,
};

/// A worker's grant at spawn: the intersection of the team's template, the lead's session ceiling at that moment and
/// the machine's limits. Every input can only narrow it (SPEC §9, D-111 item 3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Grant {
    /// The worker may run commands in its sandbox (still subject to its ceiling at the time).
    pub commands: bool,
    /// The ceiling the worker starts with: the lead's ceiling when it spawned the worker.
    pub ceiling: Option<u8>,
    /// Time limit of a turn, seconds.
    pub turn_secs: u64,
    /// Time limit of a check, seconds.
    pub check_secs: u64,
}

/// [`Grant`] from its three sources.
pub(crate) fn grant(template: &TeamTemplate, lead_ceiling: Option<u8>, machine: &Machine) -> Grant {
    Grant {
        commands: template.commands && machine.commands,
        ceiling: lead_ceiling,
        turn_secs: template.turn_timeout_secs.clamp(10, machine.max_turn_secs),
        check_secs: template.check_timeout_secs.clamp(5, machine.max_check_secs),
    }
}

/// The verdict on a worker's tool call (the host hook's `check`): the template and the machine first (a worker of a
/// team without commands runs none, whatever its ceiling), then the session ceiling exactly as for any agent
/// (`policy::check_action_at`), and writes only inside its own folder.
pub(crate) fn worker_action(
    grant_commands: bool,
    ceiling: Option<u8>,
    action: Action,
    in_own_folder: bool,
    detail: &str,
) -> Verdict {
    match action {
        Action::Exec if !grant_commands => {
            Verdict::Deny("team:no_commands: the team's template allows workers no commands".into())
        }
        Action::Write if !in_own_folder => Verdict::Deny(
            "team:writes_outside_own_folder: a worker writes only in its own folder".into(),
        ),
        Action::Write if is_agent_config(detail) => Verdict::Deny(
            "team:agent_config: a worker does not change agent settings or hooks".into(),
        ),
        // Inside its own folder a worker's write is no write to the owner's data: the project changes only through
        // review and apply. The ceiling still decides (level 1: only words; 2–3: approval).
        Action::Write => policy::check_action_at(ceiling, action, detail, true),
        _ => policy::check_action_at(ceiling, action, detail, false),
    }
}

/// Agent settings and hooks a worker must not change, even in its own folder: they would change what the harness
/// enforces on its next turn.
fn is_agent_config(path: &str) -> bool {
    let p = path.replace('\\', "/");
    p.split('/')
        .any(|c| c == ".claude" || c == ".codex" || c == ".mcp.json")
}

/// Whether a check may run: its command is one of the template's, and the lowest ceiling of everything involved (the
/// caller's session, the task, the result) allows commands from an allowlist in a sandbox (SPEC §9: level 4 and up).
pub(crate) fn check_allowed(
    template: &TeamTemplate,
    argv: &[String],
    ceilings: &[Option<u8>],
) -> Result<(), String> {
    if argv.is_empty() {
        return Err("the task has no check command".into());
    }
    if !template.checks.iter().any(|c| c.as_slice() == argv) {
        return Err(format!(
            "team:check_not_allowed: {:?} is not one of the team's check commands",
            argv.join(" ")
        ));
    }
    let lowest = ceilings.iter().copied().fold(None, min_ceiling);
    match lowest {
        Some(l) if l < 4 => Err(format!(
            "tainted:level_{l}:no_commands_below_4: the task carries data read at trust level {l}, and checks run \
             code only from level 4 up"
        )),
        _ => Ok(()),
    }
}

/// Local model classes by size (D-104): S up to 5B parameters, M up to 12B,
/// L up to 40B.
pub(crate) fn class_of(params: &str) -> Option<char> {
    let n: f64 = params
        .trim()
        .trim_end_matches(['B', 'b'])
        .trim()
        .parse()
        .ok()?;
    Some(if n < 5.0 {
        'S'
    } else if n < 12.0 {
        'M'
    } else if n <= 40.0 {
        'L'
    } else {
        return None;
    })
}

/// The roles a local model of a class takes by default (§3.3): small models triage and summarize, medium ones also
/// draft and write docs; coding needs class L and tools, which local agents do not have yet (D-104), so no local
/// class codes in this release.
pub(crate) fn local_roles(class: char) -> &'static [&'static str] {
    match class {
        'S' => &["triage", "summaries"],
        'M' | 'L' => &["triage", "summaries", "docs", "drafts", "translation"],
        _ => &[],
    }
}

/// Why a slot cannot start a worker now, from facts the caller gathered.
pub(crate) struct SlotFacts {
    /// Workers of this slot now.
    pub used: u32,
    /// Why this machine cannot run the slot's kind (no sandbox, no program, no model), if it cannot.
    pub unavailable: Option<String>,
}

/// The counts and limits a spawn is checked against.
pub(crate) struct Limits {
    /// Workers of the team now.
    pub team_workers: u32,
    /// The team's limit.
    pub max_workers: u32,
    /// Workers of all teams on this machine now.
    pub machine_workers: u32,
    /// The machine's limits.
    pub machine: Machine,
    /// The team takes local models only.
    pub local_only: bool,
}

/// Choose a slot for a new worker of `role` (and `kind`, if given): the first slot of that role and kind with room,
/// within the team's limit and the machine's (§3.3 item 2). `Err` says why nothing fits (`no_capacity`).
pub(crate) fn choose_slot(
    slots: &[TeamSlot],
    role: &str,
    kind: Option<&str>,
    facts: &[SlotFacts],
    l: &Limits,
) -> Result<usize, String> {
    if l.team_workers >= l.max_workers {
        return Err(format!(
            "the team has {} workers, its limit is {}",
            l.team_workers, l.max_workers
        ));
    }
    if l.machine_workers >= l.machine.max_workers {
        return Err(format!(
            "this computer runs {} workers, its limit is {}",
            l.machine_workers, l.machine.max_workers
        ));
    }
    let local_only = l.local_only;
    let mut why = Vec::new();
    for (i, (slot, f)) in slots.iter().zip(facts).enumerate() {
        if slot.role != role || kind.is_some_and(|k| k != slot.kind) {
            continue;
        }
        if local_only && slot.kind != "local" {
            why.push(format!(
                "{}: the team is local only, and {} is not a local model",
                slot.kind, slot.kind
            ));
            continue;
        }
        if f.used >= slot.max {
            why.push(format!(
                "{}: all {} slots of {role}/{} are in use",
                slot.kind, slot.max, slot.kind
            ));
            continue;
        }
        if let Some(u) = &f.unavailable {
            why.push(format!("{}: {u}", slot.kind));
            continue;
        }
        return Ok(i);
    }
    if why.is_empty() {
        Err(format!(
            "the team's budget has no slot for the role {role:?}{}",
            kind.map(|k| format!(" of kind {k:?}")).unwrap_or_default()
        ))
    } else {
        Err(why.join("; "))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [&str; 9] = [
        st::OPEN,
        st::ASSIGNED,
        st::WORKING,
        st::BLOCKED,
        st::SUBMITTED,
        st::RETURNED,
        st::ACCEPTED,
        st::DONE,
        st::CANCELLED,
    ];

    /// The whole table: every (state, operation) pair is either the one transition listed here or refused.
    #[test]
    fn task_state_machine() {
        use Op::*;
        let allowed: &[(&str, Op, &str)] = &[
            (st::OPEN, Assign, st::ASSIGNED),
            (st::ASSIGNED, Assign, st::ASSIGNED),
            (st::RETURNED, Assign, st::ASSIGNED),
            (st::BLOCKED, Assign, st::ASSIGNED),
            (st::ASSIGNED, Working, st::WORKING),
            (st::WORKING, Working, st::WORKING),
            (st::RETURNED, Working, st::WORKING),
            (st::BLOCKED, Working, st::WORKING),
            (st::ASSIGNED, Blocked, st::BLOCKED),
            (st::WORKING, Blocked, st::BLOCKED),
            (st::RETURNED, Blocked, st::BLOCKED),
            (st::ASSIGNED, Submit, st::SUBMITTED),
            (st::WORKING, Submit, st::SUBMITTED),
            (st::RETURNED, Submit, st::SUBMITTED),
            (st::BLOCKED, Submit, st::SUBMITTED),
            (st::SUBMITTED, CheckFailed, st::RETURNED),
            (st::SUBMITTED, Accept, st::ACCEPTED),
            (st::SUBMITTED, Changes, st::RETURNED),
            (st::BLOCKED, Changes, st::RETURNED),
            (st::ACCEPTED, Changes, st::RETURNED),
            (st::ASSIGNED, Redirect, st::RETURNED),
            (st::WORKING, Redirect, st::RETURNED),
            (st::RETURNED, Redirect, st::RETURNED),
            (st::SUBMITTED, Redirect, st::RETURNED),
            (st::BLOCKED, Redirect, st::RETURNED),
            (st::ACCEPTED, Redirect, st::RETURNED),
            (st::OPEN, Cancel, st::CANCELLED),
            (st::ASSIGNED, Cancel, st::CANCELLED),
            (st::WORKING, Cancel, st::CANCELLED),
            (st::BLOCKED, Cancel, st::CANCELLED),
            (st::SUBMITTED, Cancel, st::CANCELLED),
            (st::RETURNED, Cancel, st::CANCELLED),
            (st::ACCEPTED, Cancel, st::CANCELLED),
            (st::ACCEPTED, Apply, st::DONE),
        ];
        let ops = [
            Assign,
            Working,
            Blocked,
            Submit,
            CheckFailed,
            Accept,
            Changes,
            Redirect,
            Cancel,
            Apply,
        ];
        let mut n = 0;
        for s in ALL {
            for op in ops {
                let want = allowed
                    .iter()
                    .find(|(a, o, _)| *a == s && *o == op)
                    .map(|(_, _, b)| *b);
                match (next_state(s, op), want) {
                    (Ok(got), Some(w)) => {
                        assert_eq!(got, w, "{s} {op:?}");
                        n += 1;
                    }
                    (Err(e), None) => {
                        assert!(e.contains(s), "{e}");
                    }
                    (got, want) => panic!("{s} {op:?}: got {got:?}, want {want:?}"),
                }
            }
        }
        assert_eq!(n, allowed.len());
        // Nothing leaves a final state; an accepted result cannot be submitted over.
        for s in [st::DONE, st::CANCELLED] {
            assert!(is_final(s));
            assert!(ops.iter().all(|op| next_state(s, *op).is_err()), "{s}");
        }
        assert!(next_state(st::ACCEPTED, Submit).is_err());
        assert!(holds_worker(st::SUBMITTED) && !holds_worker(st::ACCEPTED));
    }

    fn template(commands: bool) -> TeamTemplate {
        TeamTemplate {
            commands,
            checks: vec![vec!["cargo".into(), "test".into()]],
            ..Default::default()
        }
    }

    /// Attenuation only: each of the three sources narrows the grant and none widens it.
    #[test]
    fn a_grant_is_the_intersection_and_only_narrows() {
        let t = template(true);
        let g = grant(&t, None, &THIS_COMPUTER);
        assert!(g.commands);
        assert_eq!(g.ceiling, None);
        // The template says no commands: the machine cannot add them back.
        let g = grant(&template(false), None, &THIS_COMPUTER);
        assert!(!g.commands);
        // The machine says no commands: the template cannot add them back.
        let strict = Machine {
            commands: false,
            ..THIS_COMPUTER
        };
        assert!(!grant(&t, None, &strict).commands);
        // The lead's ceiling travels into the worker as it is.
        assert_eq!(grant(&t, Some(2), &THIS_COMPUTER).ceiling, Some(2));
        // Limits are the lower of the template's and the machine's.
        let long = TeamTemplate {
            turn_timeout_secs: 100_000,
            check_timeout_secs: 100_000,
            ..t.clone()
        };
        let g = grant(&long, None, &THIS_COMPUTER);
        assert_eq!(
            (g.turn_secs, g.check_secs),
            (THIS_COMPUTER.max_turn_secs, THIS_COMPUTER.max_check_secs)
        );
        assert_eq!(min_ceiling(Some(5), Some(2)), Some(2));
        assert_eq!(min_ceiling(None, Some(3)), Some(3));
        assert_eq!(min_ceiling(Some(4), None), Some(4));
        assert_eq!(min_ceiling(None, None), None);
    }

    /// A worker's commands: no commands at all without the template's permission; below level 4 none; at 4 the
    /// owner approves each; at 5 or clean they run (and are logged by the caller). Writes only in its own folder and
    /// never to agent settings.
    #[test]
    fn worker_commands_follow_the_template_and_the_ceiling() {
        let deny = |v: &Verdict| matches!(v, Verdict::Deny(_));
        for c in [None, Some(5), Some(4), Some(3), Some(1)] {
            assert!(
                deny(&worker_action(false, c, Action::Exec, true, "make")),
                "{c:?}"
            );
        }
        assert!(deny(&worker_action(
            true,
            Some(3),
            Action::Exec,
            true,
            "make"
        )));
        assert!(deny(&worker_action(
            true,
            Some(2),
            Action::Exec,
            true,
            "make"
        )));
        assert!(matches!(
            worker_action(true, Some(4), Action::Exec, true, "make"),
            Verdict::Approve(_)
        ));
        assert_eq!(
            worker_action(true, Some(5), Action::Exec, true, "make"),
            Verdict::Allow
        );
        assert_eq!(
            worker_action(true, None, Action::Exec, true, "make"),
            Verdict::Allow
        );
        assert!(deny(&worker_action(
            true,
            None,
            Action::Write,
            false,
            "/home/o/.ssh/config"
        )));
        assert!(deny(&worker_action(
            true,
            None,
            Action::Write,
            true,
            "/w/tree/.claude/settings.json"
        )));
        assert_eq!(
            worker_action(true, Some(5), Action::Write, true, "/w/tree/src/lib.rs"),
            Verdict::Allow
        );
        assert!(matches!(
            worker_action(true, Some(3), Action::Write, true, "/w/tree/src/lib.rs"),
            Verdict::Approve(_)
        ));
        assert!(deny(&worker_action(
            true,
            Some(1),
            Action::Write,
            true,
            "/w/tree/src/lib.rs"
        )));
    }

    /// A check runs only a command of the template's list, and only when nothing involved carries a ceiling below 4.
    #[test]
    fn checks_need_the_allowlist_and_level_4() {
        let t = template(true);
        let ct = vec!["cargo".to_string(), "test".to_string()];
        assert!(check_allowed(&t, &ct, &[None, None]).is_ok());
        assert!(check_allowed(&t, &ct, &[Some(5), Some(4)]).is_ok());
        let e = check_allowed(&t, &ct, &[None, Some(3)]).unwrap_err();
        assert!(e.contains("no_commands_below_4"), "{e}");
        let e =
            check_allowed(&t, &["sh".into(), "-c".into(), "curl x".into()], &[None]).unwrap_err();
        assert!(e.contains("check_not_allowed"), "{e}");
        // A longer command is not the allowlisted one.
        let longer = vec!["cargo".into(), "test".into(), "--config".into(), "x".into()];
        assert!(check_allowed(&t, &longer, &[None]).is_err());
        assert!(check_allowed(&t, &[], &[None]).is_err());
    }

    fn slot(role: &str, kind: &str, max: u32) -> TeamSlot {
        TeamSlot {
            role: role.into(),
            kind: kind.into(),
            model: None,
            max,
            argv: vec![],
            hosts: vec![],
        }
    }

    fn free(used: u32) -> SlotFacts {
        SlotFacts {
            used,
            unavailable: None,
        }
    }

    /// The budget decides: a role without a slot, a full slot, the team's limit, the machine's limit, an unavailable
    /// kind, and "local only" each refuse with the reason; otherwise the first fitting slot.
    #[test]
    fn a_spawn_stays_within_the_budget() {
        let slots = vec![
            slot("coder", "claude", 2),
            slot("coder", "local", 1),
            slot("docs", "local", 1),
        ];
        let m = THIS_COMPUTER;
        let limits = |team: u32, machine: Machine, local_only: bool| Limits {
            team_workers: team,
            max_workers: 3,
            machine_workers: team,
            machine,
            local_only,
        };
        let pick =
            |facts: &[SlotFacts], role: &str, kind: Option<&str>, team: u32, local_only: bool| {
                choose_slot(&slots, role, kind, facts, &limits(team, m, local_only))
            };
        let facts = [free(0), free(0), free(0)];
        assert_eq!(pick(&facts, "coder", None, 0, false), Ok(0));
        assert_eq!(pick(&facts, "coder", Some("local"), 0, false), Ok(1));
        assert!(
            pick(&facts, "reviewer", None, 0, false)
                .unwrap_err()
                .contains("no slot for the role")
        );
        // The claude slot is full: the next coder slot fits.
        let facts = [free(2), free(0), free(0)];
        assert_eq!(pick(&facts, "coder", None, 2, false), Ok(1));
        let e = pick(&facts, "coder", Some("claude"), 2, false).unwrap_err();
        assert!(e.contains("all 2 slots"), "{e}");
        // The team's limit.
        let e = pick(&[free(0), free(0), free(0)], "coder", None, 3, false).unwrap_err();
        assert!(e.contains("its limit is 3"), "{e}");
        // The machine's limit.
        let busy = Machine {
            max_workers: 1,
            ..m
        };
        let mut l = limits(0, busy, false);
        l.machine_workers = 1;
        let e = choose_slot(&slots, "coder", None, &[free(0), free(0), free(0)], &l).unwrap_err();
        assert!(e.contains("this computer runs 1"), "{e}");
        // A kind this machine cannot run.
        let facts = [
            SlotFacts {
                used: 0,
                unavailable: Some("no sandbox".into()),
            },
            SlotFacts {
                used: 0,
                unavailable: Some("qwen3.5-9b is not installed".into()),
            },
            free(0),
        ];
        let e = pick(&facts, "coder", None, 0, false).unwrap_err();
        assert!(
            e.contains("no sandbox") && e.contains("not installed"),
            "{e}"
        );
        // Local only: the cloud slot is refused, the local one fits.
        let facts = [free(0), free(0), free(0)];
        assert_eq!(pick(&facts, "coder", None, 0, true), Ok(1));
        let e = pick(&facts, "coder", Some("claude"), 0, true).unwrap_err();
        assert!(e.contains("local only"), "{e}");
    }

    #[test]
    fn local_model_classes_and_their_roles() {
        assert_eq!(class_of("2.27B"), Some('S'));
        assert_eq!(class_of("4.2B"), Some('S'));
        assert_eq!(class_of("9.65B"), Some('M'));
        assert_eq!(class_of("20B"), Some('L'));
        assert_eq!(class_of("32.8B"), Some('L'));
        assert_eq!(class_of("120B"), None);
        assert_eq!(class_of("x"), None);
        assert!(!local_roles('S').contains(&"coder"));
        assert!(!local_roles('M').contains(&"coder"));
        assert!(local_roles('M').contains(&"docs"));
        assert!(!local_roles('S').contains(&"docs"));
        assert!(local_roles('?').is_empty());
    }
}
