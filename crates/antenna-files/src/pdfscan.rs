// SPDX-License-Identifier: AGPL-3.0-only
//! Active PDF content by document structure (only inside the sandbox worker).
//!
//! YARA rules look for raw bytes, but a PDF name can be written with `#xx` (`/J#61vaScript`) or hidden in a compressed
//! object stream. Here the objects are parsed by `hayro-syntax` (the same parser that renders the preview): names are
//! already decoded, objects from object streams are included. YARA remains the second layer.

use std::collections::BTreeSet;

use hayro::hayro_syntax::Pdf;
use hayro::hayro_syntax::object::{Dict, MaybeRef, Object};

use crate::report::{Finding, Severity};

/// Traversal budget (objects × nesting), so that a malicious PDF cannot occupy the worker for long.
const BUDGET: usize = 2_000_000;
const MAX_DEPTH: usize = 64;
/// Limit on top-level objects. Parsing an object from an object stream in hayro-syntax 0.7 rereads the stream's offset
/// table, so with tens of thousands of objects the traversal is quadratic (60,000 objects took 101 s).
pub const MAX_OBJECTS: usize = 20_000;
/// Traversal time limit.
pub const DEADLINE: std::time::Duration = std::time::Duration::from_secs(5);

fn flag_for(name: &[u8]) -> Option<&'static str> {
    Some(match name {
        b"JavaScript" | b"JS" => "pdf_javascript",
        b"Launch" => "pdf_launch_action",
        b"EmbeddedFile" | b"EmbeddedFiles" => "pdf_embedded_file",
        b"OpenAction" | b"AA" => "pdf_auto_action",
        b"XFA" => "pdf_xfa",
        b"RichMedia" => "pdf_richmedia",
        b"SubmitForm" | b"ImportData" => "pdf_form_action",
        b"GoToR" | b"GoToE" => "pdf_remote_goto",
        _ => return None,
    })
}

struct Walk {
    flags: BTreeSet<&'static str>,
    budget: usize,
    until: std::time::Instant,
}

impl Walk {
    fn name(&mut self, n: &[u8]) {
        if let Some(f) = flag_for(n) {
            self.flags.insert(f);
        }
    }

    fn dict(&mut self, d: &Dict<'_>, depth: usize) {
        for (k, v) in d.entries() {
            if self.budget == 0 {
                return;
            }
            self.budget -= 1;
            self.name(&k);
            if let MaybeRef::NotRef(o) = v {
                self.obj(&o, depth + 1);
            }
        }
    }

    fn obj(&mut self, o: &Object<'_>, depth: usize) {
        if depth > MAX_DEPTH || self.budget == 0 {
            return;
        }
        if self.budget.is_multiple_of(4096) && std::time::Instant::now() > self.until {
            self.budget = 0;
            return;
        }
        self.budget -= 1;
        match o {
            Object::Name(n) => self.name(n),
            Object::Dict(d) => self.dict(d, depth),
            Object::Stream(s) => self.dict(s.dict(), depth),
            Object::Array(a) => {
                for item in a.raw_iter() {
                    if let MaybeRef::NotRef(o) = item {
                        self.obj(&o, depth + 1);
                    }
                }
            }
            _ => {}
        }
    }
}

/// Active PDF content findings; `Err` means the PDF did not parse (the caller decides).
pub fn scan(data: &[u8]) -> Result<Vec<Finding>, String> {
    scan_with(data, DEADLINE, MAX_OBJECTS)
}

/// The same with time and object count limits (exceeding them gives a `pdf_too_complex` finding, a risk).
pub fn scan_with(
    data: &[u8],
    deadline: std::time::Duration,
    max_objects: usize,
) -> Result<Vec<Finding>, String> {
    let pdf = Pdf::new(data.to_vec()).map_err(|e| format!("PDF cannot be read: {e:?}"))?;
    let mut w = Walk {
        flags: BTreeSet::new(),
        budget: BUDGET,
        until: std::time::Instant::now() + deadline,
    };
    let mut seen = 0usize;
    for o in pdf.objects() {
        seen += 1;
        if w.budget == 0 || seen > max_objects || std::time::Instant::now() > w.until {
            w.budget = 0;
            break;
        }
        w.obj(&o, 0);
    }
    let mut out: Vec<Finding> = w
        .flags
        .iter()
        .map(|f| {
            let (sev, detail) = match *f {
                "pdf_launch_action" => (
                    Severity::Threat,
                    "PDF with a /Launch action (runs a program)",
                ),
                "pdf_javascript" => (Severity::Warn, "PDF contains JavaScript"),
                "pdf_embedded_file" => (Severity::Warn, "PDF contains an embedded file"),
                "pdf_auto_action" => (
                    Severity::Warn,
                    "PDF runs an action on open (/OpenAction or /AA)",
                ),
                "pdf_xfa" => (Severity::Warn, "PDF contains an XFA form (scriptable)"),
                "pdf_richmedia" => (Severity::Warn, "PDF contains rich media (Flash/3D)"),
                "pdf_form_action" => (Severity::Warn, "PDF submits or imports form data"),
                _ => (Severity::Warn, "PDF links to a remote or embedded document"),
            };
            Finding::new(*f, sev, detail)
        })
        .collect();
    if w.budget == 0 {
        out.push(Finding::new(
            "pdf_too_complex",
            Severity::Warn,
            "PDF structure is too large to inspect completely",
        ));
    }
    Ok(out)
}
