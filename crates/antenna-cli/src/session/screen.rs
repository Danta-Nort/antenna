// SPDX-License-Identifier: AGPL-3.0-only
//! What a session's pane shows, read through tmux (`capture-pane -e` and the cursor's format variables), and the
//! screen checks of the wake: the same rules as the window's Code mode (`apps/antenna_desktop/lib/state/code_wake.dart`,
//! D-UI-23, D-UI-25), ported so that a session on a server is woken by exactly what wakes one in the window.
//!
//! Claude Code: its empty prompt is `❯` between two horizontal rules at the bottom of the screen, the cursor right
//! after `❯ ` and whatever follows on that row blank or drawn faint (the placeholder); a draft is drawn in normal
//! intensity and moves the cursor, so it cannot pass. A permission or trust dialog shows a numbered choice (`❯ 1. Yes`)
//! and hides the cursor. Codex (checked on 0.47 and later, `docs/TROUBLESHOOTING.md` "Codex wake"): its composer row
//! starts with `›`, the placeholder after it is faint, the footer says `? for shortcuts` or `… to send`, and a running
//! turn says `esc to interrupt`; its approval dialogs list numbered choices (`› 1. Yes, proceed`). Anything not
//! recognised is not idle: nothing is typed.

/// One cell row as read from tmux: the characters (wide ones once, as tmux prints them) and whether each is faint.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Row {
    /// The characters of the row (trailing blanks kept: `capture-pane -N`).
    pub chars: Vec<char>,
    /// Per character: drawn faint (SGR 2).
    pub faint: Vec<bool>,
}

impl Row {
    /// The row as text.
    pub fn text(&self) -> String {
        self.chars.iter().collect()
    }
}

/// The pane as the checks read it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Screen {
    /// The visible rows, top to bottom.
    pub rows: Vec<Row>,
    /// The cursor: row index and character index in that row (`None`: not on the screen).
    pub cursor: Option<(usize, usize)>,
    /// The program shows the cursor (Claude Code hides it while a dialog is up).
    pub cursor_visible: bool,
    /// The pane is in one of tmux's own modes (copy mode, a chooser): keys sent now would go to the mode, not to the
    /// program.
    pub in_mode: bool,
}

/// Terminal cells a character takes: 2 for East Asian wide and fullwidth characters and the common emoji blocks, 0
/// for combining marks, otherwise 1. Only used to map tmux's cursor column (in cells) to a character index; a wrong
/// guess makes the cursor check fail, so nothing is typed (fail closed).
fn cell_width(c: char) -> usize {
    let u = c as u32;
    let combining = matches!(u, 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F)
        || u == 0x200B
        || u == 0x200D;
    if combining {
        return 0;
    }
    let wide = matches!(u,
        0x1100..=0x115F | 0x2E80..=0x303E | 0x3041..=0x33FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xA000..=0xA4CF
        | 0xAC00..=0xD7A3 | 0xF900..=0xFAFF | 0xFE30..=0xFE4F | 0xFF00..=0xFF60 | 0xFFE0..=0xFFE6
        | 0x1F300..=0x1F64F | 0x1F900..=0x1F9FF | 0x20000..=0x3FFFD);
    if wide { 2 } else { 1 }
}

/// Parse one SGR parameter list (`2`, `0;1;2`, `38;5;246`, `38:2::1:2:3`) into the faint attribute.
fn apply_sgr(params: &str, faint: &mut bool) {
    if params.is_empty() {
        *faint = false;
        return;
    }
    let parts: Vec<&str> = params.split(';').collect();
    let mut i = 0;
    while i < parts.len() {
        // A colon sub-parameter list (`38:5:246`) is one parameter; its first number says what it is.
        let p = parts[i];
        let head = p.split(':').next().unwrap_or("");
        match head {
            "" | "0" => *faint = false,
            "2" => *faint = true,
            "22" => *faint = false,
            "38" | "48" | "58" if !p.contains(':') => {
                // 38;5;n or 38;2;r;g;b: skip the color's own parameters
                match parts.get(i + 1).copied() {
                    Some("5") => i += 2,
                    Some("2") => i += 4,
                    _ => {}
                }
            }
            _ => {}
        }
        i += 1;
    }
}

/// The rows of `tmux capture-pane -p -e -N` output: SGR sequences tracked for the faint attribute, other escape
/// sequences (OSC hyperlinks, any other CSI) skipped.
pub(crate) fn parse_capture(out: &str) -> Vec<Row> {
    let mut rows = Vec::new();
    let mut faint = false;
    for line in out.split('\n') {
        let mut row = Row::default();
        let mut it = line.chars().peekable();
        while let Some(c) = it.next() {
            if c == '\x1b' {
                match it.peek().copied() {
                    Some('[') => {
                        it.next();
                        let mut params = String::new();
                        let mut fin = None;
                        for d in it.by_ref() {
                            if ('\x40'..='\x7e').contains(&d) {
                                fin = Some(d);
                                break;
                            }
                            params.push(d);
                        }
                        if fin == Some('m') {
                            apply_sgr(&params, &mut faint);
                        }
                    }
                    Some(']') => {
                        // OSC … BEL or ST
                        it.next();
                        while let Some(d) = it.next() {
                            if d == '\x07' {
                                break;
                            }
                            if d == '\x1b' && it.peek() == Some(&'\\') {
                                it.next();
                                break;
                            }
                        }
                    }
                    Some(_) => {
                        it.next();
                    }
                    None => {}
                }
                continue;
            }
            if c == '\r' || (c as u32) < 0x20 && c != '\t' {
                continue;
            }
            row.chars.push(c);
            row.faint.push(faint);
        }
        rows.push(row);
    }
    // `capture-pane -p` ends its last row with a newline: no empty row after it
    if rows.last().is_some_and(|r| r.chars.is_empty()) && out.ends_with('\n') {
        rows.pop();
    }
    rows
}

impl Screen {
    /// A screen from tmux's output: the captured rows and the cursor in cells (`cursor_x`, `cursor_y`).
    pub fn from_tmux(
        capture: &str,
        cursor_x: usize,
        cursor_y: usize,
        cursor_visible: bool,
        in_mode: bool,
    ) -> Self {
        let rows = parse_capture(capture);
        let cursor = rows.get(cursor_y).map(|r| {
            let mut cells = 0;
            let mut index = r.chars.len();
            for (i, c) in r.chars.iter().enumerate() {
                if cells >= cursor_x {
                    index = i;
                    break;
                }
                cells += cell_width(*c);
            }
            if cells < cursor_x && index == r.chars.len() {
                // past the end of the text: blanks tmux did not print
                index = r.chars.len() + (cursor_x - cells);
            }
            (cursor_y, index)
        });
        Screen {
            rows,
            cursor,
            cursor_visible,
            in_mode,
        }
    }

    fn faint_at(&self, row: usize, index: usize) -> bool {
        self.rows
            .get(row)
            .and_then(|r| r.faint.get(index))
            .copied()
            .unwrap_or(false)
    }

    /// A hash of what is shown (rows, faint marks, cursor): the quiet check compares it between looks.
    pub fn fingerprint(&self) -> u64 {
        use std::hash::{Hash, Hasher};
        let mut h = std::collections::hash_map::DefaultHasher::new();
        self.hash(&mut h);
        h.finish()
    }
}

impl std::hash::Hash for Screen {
    fn hash<H: std::hash::Hasher>(&self, h: &mut H) {
        for r in &self.rows {
            r.chars.hash(h);
            r.faint.hash(h);
        }
        self.cursor.hash(h);
        self.cursor_visible.hash(h);
        self.in_mode.hash(h);
    }
}

fn is_rule(s: &str) -> bool {
    s.chars().count() >= 20 && s.chars().all(|c| c == '─')
}

/// A numbered choice of a dialog: `❯ 1. Yes` (Claude Code), `› 1. Yes, proceed (y)` or `> 1. Sign in with ChatGPT`
/// (Codex), possibly indented.
fn is_choice(s: &str) -> bool {
    let t = s.trim_start();
    let Some(rest) = t
        .strip_prefix('❯')
        .or_else(|| t.strip_prefix('›'))
        .or_else(|| t.strip_prefix('>'))
    else {
        return false;
    };
    let rest = rest.trim_start();
    let digits = rest.chars().take_while(char::is_ascii_digit).count();
    digits > 0 && rest[digits..].starts_with(". ")
}

/// The screen agrees that nothing modal is up: the cursor is shown, no numbered choice is visible and tmux is not in
/// one of its own modes. Defence in depth on top of the hooks (D-UI-25 item 4): an agent can write into its own hook
/// folder, but it cannot make the waker type into a dialog.
pub(crate) fn screen_guard(s: &Screen) -> bool {
    s.cursor_visible && !s.in_mode && !is_choice_on(s)
}

/// A numbered choice is on the screen: a permission, trust or hooks-review dialog (Enter or Escape would answer it).
pub(crate) fn is_choice_on(s: &Screen) -> bool {
    s.rows.iter().any(|r| is_choice(&r.text()))
}

/// Nothing is typed after the prompt mark at character `prompt` of row `row`: the cursor stands right after the mark
/// and one space, and the rest of the row is blank or faint. The separator right after the mark may be a no-break
/// space (Claude Code 2.1.289 and later after a turn); only in that one column.
fn empty_input(s: &Screen, row: usize, prompt: usize) -> bool {
    if s.cursor != Some((row, prompt + 2)) {
        return false;
    }
    let Some(r) = s.rows.get(row) else {
        return false;
    };
    for (c, ch) in r.chars.iter().enumerate().skip(prompt + 1) {
        if *ch == ' ' || (c == prompt + 1 && *ch == '\u{a0}') {
            continue;
        }
        if !s.faint_at(row, c) {
            return false;
        }
    }
    true
}

/// The rows as trimmed text, and the index after the last non-blank row.
fn lines(s: &Screen) -> (Vec<String>, usize) {
    let lines: Vec<String> = s
        .rows
        .iter()
        .map(|r| r.text().trim_end().to_string())
        .collect();
    let mut end = lines.len();
    while end > 0 && lines[end - 1].trim().is_empty() {
        end -= 1;
    }
    (lines, end)
}

/// The CLI's own screen says a turn runs and how to interrupt it: Claude Code and Codex both show "esc to interrupt"
/// while they work (PG-58: the interrupt is sent only then).
pub(crate) fn busy_hint(s: &Screen) -> bool {
    let (lines, end) = lines(s);
    lines[..end]
        .iter()
        .any(|l| l.to_lowercase().contains("esc to interrupt"))
}

/// Text the person typed stands in the CLI's input (Claude Code's `❯` between rules, Codex's `›` composer): any
/// character after the mark that is neither blank nor drawn faint (a placeholder). A screen without an input row has
/// no draft to protect, and the other checks decide.
pub(crate) fn input_draft(s: &Screen) -> bool {
    let (lines, _) = lines(s);
    for (i, l) in lines.iter().enumerate().rev() {
        let row = l.trim_start();
        let claude = row.starts_with('❯')
            && i > 0
            && i + 1 < lines.len()
            && is_rule(lines[i - 1].trim())
            && is_rule(lines[i + 1].trim());
        let codex = row.starts_with('›') && !is_choice(row);
        if !(claude || codex) {
            continue;
        }
        let indent = l.chars().count() - row.chars().count();
        let Some(r) = s.rows.get(i) else {
            return false;
        };
        return r
            .chars
            .iter()
            .enumerate()
            .skip(indent + 1)
            .any(|(c, ch)| !ch.is_whitespace() && *ch != '\u{a0}' && !s.faint_at(i, c));
    }
    false
}

/// Claude Code waits for input at an empty prompt (the window's `claudeCodeReady`).
pub(crate) fn claude_ready(s: &Screen) -> bool {
    let (lines, end) = lines(s);
    if end < 3 {
        return false;
    }
    for i in (1..=end - 2).rev() {
        let row = lines[i].trim_start();
        if !row.starts_with('❯') {
            continue;
        }
        if !is_rule(lines[i - 1].trim()) || !is_rule(lines[i + 1].trim()) {
            continue;
        }
        let below = &lines[i + 2..end];
        if below.iter().filter(|l| !l.trim().is_empty()).count() > 4 {
            return false;
        }
        let from = i.saturating_sub(6);
        if lines[from..end]
            .iter()
            .any(|l| l.to_lowercase().contains("esc to interrupt"))
        {
            return false;
        }
        let indent = lines[i].chars().count() - row.chars().count();
        return screen_guard(s) && empty_input(s, i, indent);
    }
    false
}

/// The screen shows a Claude Code layout the checks know (its prompt box, whatever is in it, or a dialog's choice).
pub(crate) fn claude_layout_known(s: &Screen) -> bool {
    let (lines, _) = lines(s);
    if lines.iter().any(|l| is_choice(l)) {
        return true;
    }
    (1..lines.len().saturating_sub(1)).any(|i| {
        lines[i].trim().starts_with('❯')
            && is_rule(lines[i - 1].trim())
            && is_rule(lines[i + 1].trim())
    })
}

/// The screen shows a Codex layout the checks know: its composer row (`›` at the start) or a dialog's choice.
pub(crate) fn codex_layout_known(s: &Screen) -> bool {
    let (lines, _) = lines(s);
    lines
        .iter()
        .any(|l| is_choice(l) || l.trim_start().starts_with('›'))
}

/// Codex waits for input at an empty composer: the last composer row (`›` at the start, possibly after spaces) near
/// the bottom, the cursor right after `› `, the rest of the row blank or faint (its placeholder), no `esc to
/// interrupt` anywhere below the conversation, and its footer under the composer (`? for shortcuts`, `… to send`,
/// `… context left`). A draft is drawn in normal intensity and moves the cursor; an approval dialog lists numbered
/// choices and is refused by [`screen_guard`].
pub(crate) fn codex_ready(s: &Screen) -> bool {
    let (lines, end) = lines(s);
    if end == 0 {
        return false;
    }
    for i in (0..end).rev() {
        let row = lines[i].trim_start();
        if !row.starts_with('›') {
            continue;
        }
        let below = &lines[i + 1..end];
        if below.iter().filter(|l| !l.trim().is_empty()).count() > 4 {
            return false;
        }
        let footer = below.iter().any(|l| {
            let l = l.to_lowercase();
            l.contains("for shortcuts") || l.contains("to send") || l.contains("context left")
        });
        if !footer {
            return false;
        }
        let from = i.saturating_sub(8);
        if lines[from..end]
            .iter()
            .any(|l| l.to_lowercase().contains("esc to interrupt"))
        {
            return false;
        }
        let indent = lines[i].chars().count() - row.chars().count();
        return screen_guard(s) && empty_input(s, i, indent);
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    const RULE: &str = "────────────────────────────────────────";

    fn faint(s: &str) -> String {
        format!("\x1b[2m{s}\x1b[22m")
    }

    /// A screen as `capture-pane -e -N` would print it, with the cursor in cells.
    fn screen(rows: &[String], cursor: Option<(usize, usize)>, hidden: bool) -> Screen {
        let text = rows.join("\n") + "\n";
        let (y, x) = cursor.unwrap_or((rows.len().saturating_sub(1), 0));
        Screen::from_tmux(&text, x, y, !hidden, false)
    }

    fn banner() -> Vec<String> {
        [
            " ▐▛███▛█   Claude Code v2.1.289",
            "▝▜██████▀  Opus · Claude Max",
            "  ▝▝   ▝▝   ~/projects/shop",
            "",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect()
    }

    fn with(mut rows: Vec<String>, more: &[&str]) -> Vec<String> {
        rows.extend(more.iter().map(|s| s.to_string()));
        rows
    }

    #[test]
    fn claude_idle_screens_are_ready() {
        let fresh = with(banner(), &[RULE]);
        let fresh = with(fresh, &[&format!("❯ {}", faint("Try \"fix lint errors\""))]);
        let fresh = with(
            fresh,
            &[
                RULE,
                "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents",
            ],
        );
        assert!(claude_ready(&screen(&fresh, Some((5, 2)), false)));
        let after = with(
            banner(),
            &[
                "❯ Reply with the single word: ok",
                "",
                "● ok",
                "",
                "✻ Worked for 3s",
                "",
                RULE,
                "❯",
                RULE,
                "  ⏸ manual mode on · ? for shortcuts",
            ],
        );
        assert!(claude_ready(&screen(&after, Some((11, 2)), false)));
        // ❯ and a no-break space (2.1.289 and later after a turn)
        let nbsp = with(
            banner(),
            &["● ok", "", RULE, "❯\u{a0}", RULE, "  ? for shortcuts"],
        );
        assert!(claude_ready(&screen(&nbsp, Some((7, 2)), false)));
    }

    #[test]
    fn claude_drafts_turns_and_dialogs_are_not_ready() {
        // a draft that reads like the placeholder, the cursor after it or moved back to its start
        let draft = with(
            banner(),
            &[RULE, "❯ Try \"fix lint errors\"", RULE, "  ⏵⏵ auto mode on"],
        );
        assert!(!claude_ready(&screen(&draft, Some((5, 23)), false)));
        assert!(!claude_ready(&screen(&draft, Some((5, 2)), false)));
        // faint text with the cursor elsewhere
        let away = with(
            banner(),
            &[
                RULE,
                &format!("❯ {}", faint("Try \"fix lint errors\"")),
                RULE,
                "  ⏵⏵ auto mode on",
            ],
        );
        assert!(!claude_ready(&screen(&away, Some((5, 23)), false)));
        // a no-break space typed into the prompt is a draft
        let nbsp2 = with(
            banner(),
            &[RULE, "❯\u{a0}\u{a0}", RULE, "  ? for shortcuts"],
        );
        assert!(!claude_ready(&screen(&nbsp2, Some((5, 2)), false)));
        // a running turn
        let busy = with(
            banner(),
            &[
                "✽ Computing… (1s · thinking)",
                "",
                RULE,
                "❯",
                RULE,
                "  ⏸ manual mode on · esc to interrupt",
            ],
        );
        assert!(!claude_ready(&screen(&busy, Some((7, 2)), false)));
        // a permission dialog: numbered choice, cursor hidden
        let dialog = with(
            banner(),
            &[
                RULE,
                " Do you want to proceed?",
                " ❯ 1. Yes",
                "   2. No",
                "",
                " Esc to cancel",
            ],
        );
        let s = screen(&dialog, None, true);
        assert!(!claude_ready(&s) && !screen_guard(&s) && claude_layout_known(&s));
        // 2.1.306's "Read outside the working directories" (recorded by the canary): Enter would allow such reads for good
        let outside = with(
            banner(),
            &[
                RULE,
                " Read outside the working directories",
                " Search(pattern: \"**/*\", path: \"/tmp/scratch-shop\")",
                "",
                " Allow this read outside the working directories?",
                " ❯ 1. Yes, and keep allowing any reads outside the working directories",
                "   2. No, and block reads outside the working directories from now on",
                "   3. No, and ask again next time",
                "   4. Yes, but ask again next time",
                "",
                " Esc to cancel · Tab to amend",
            ],
        );
        let s = screen(&outside, None, true);
        assert!(
            !claude_ready(&s) && !screen_guard(&s) && is_choice_on(&s) && claude_layout_known(&s)
        );
        assert!(!busy_hint(&s));
        // the same idle screen while tmux is in copy mode
        let idle = with(banner(), &[RULE, "❯", RULE, "  ? for shortcuts"]);
        let mut s = screen(&idle, Some((5, 2)), false);
        assert!(claude_ready(&s));
        s.in_mode = true;
        assert!(!claude_ready(&s), "keys would go to tmux's copy mode");
        // nothing recognisable
        assert!(!claude_ready(&screen(
            &["$ ".to_string()],
            Some((0, 2)),
            false
        )));
        assert!(!claude_layout_known(&screen(
            &["$ ".to_string()],
            Some((0, 2)),
            false
        )));
    }

    #[test]
    fn capture_parsing_tracks_faint_and_skips_other_sequences() {
        let rows = parse_capture(
            "a\x1b[2mb\x1b[0mc\x1b[1;2md\x1b[22me\x1b[38;5;2mf\x1b]8;;http://x\x07g\n",
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].text(), "abcdefg");
        assert_eq!(
            rows[0].faint,
            vec![false, true, false, true, false, false, false]
        );
        // a wide character before the cursor: cells → characters
        let s = Screen::from_tmux("東京❯ x\n", 5, 0, true, false);
        assert_eq!(s.cursor, Some((0, 3)));
        // the cursor past the printed text
        let s = Screen::from_tmux("❯\n", 2, 0, true, false);
        assert_eq!(s.cursor, Some((0, 2)));
    }

    #[test]
    fn codex_idle_and_not_idle() {
        let base = |composer: &str, footer: &str| -> Vec<String> {
            vec![
                "╭──────────────────────────────────────╮".into(),
                "│ >_ OpenAI Codex (v0.47.0)            │".into(),
                "╰──────────────────────────────────────╯".into(),
                "".into(),
                "• Ready.".into(),
                "".into(),
                composer.to_string(),
                "".into(),
                footer.to_string(),
            ]
        };
        let idle = base(
            &format!("› {}", faint("Ask Codex to do anything")),
            "  ⏎ send   ⌃J newline   ⌃T transcript   ⌃C quit   ? for shortcuts",
        );
        assert!(codex_ready(&screen(&idle, Some((6, 2)), false)));
        let draft = base("› fix the build", "  ⏎ send   ? for shortcuts");
        assert!(!codex_ready(&screen(&draft, Some((6, 15)), false)));
        assert!(!codex_ready(&screen(&draft, Some((6, 2)), false)));
        let busy = with(
            base(
                &format!("› {}", faint("Ask Codex to do anything")),
                "  ? for shortcuts",
            ),
            &[],
        );
        let mut busy = busy;
        busy.insert(5, "• Working (3s • esc to interrupt)".into());
        assert!(!codex_ready(&screen(&busy, Some((7, 2)), false)));
        let approval = base(
            "› 1. Yes, proceed",
            "  Press enter to confirm or esc to cancel",
        );
        assert!(!codex_ready(&screen(&approval, Some((6, 2)), true)));
        // no footer under the composer: not the layout the check knows
        let bare = vec!["› ".to_string()];
        assert!(!codex_ready(&screen(&bare, Some((0, 2)), false)));
    }
}
