// SPDX-License-Identifier: AGPL-3.0-only
//! The per-file guard of [`Quarantine`]: a decision waits out the daemon's own short operation on the file.

use std::time::Duration;

use super::Quarantine;
use crate::error::code;

fn quarantine(dir: &std::path::Path) -> Quarantine {
    Quarantine::open(dir.join("q"), [7; 32], dir.join("links")).expect("open")
}

/// The daemon holds the file for a moment (the end of its check, `set_held`): a decision made in that moment goes
/// through once it ends, instead of "another operation on this file is in progress".
#[tokio::test]
async fn a_decision_waits_for_a_short_operation_of_the_daemon() {
    let dir = tempfile::tempdir().expect("temp dir");
    let q = quarantine(dir.path());
    let link = [1; 32];
    let held = q.lock(&link, "f").expect("the daemon's operation");
    let (decided, ()) = tokio::join!(q.lock_waiting(&link, "f", Duration::from_secs(5)), async {
        tokio::time::sleep(Duration::from_millis(150)).await;
        drop(held);
    });
    assert!(
        decided.is_ok(),
        "the decision went through after the operation ended"
    );
}

/// The control: an operation that outlasts the wait still refuses the decision, and another file is never held up.
#[tokio::test]
async fn a_decision_still_refuses_after_the_wait() {
    let dir = tempfile::tempdir().expect("temp dir");
    let q = quarantine(dir.path());
    let link = [1; 32];
    let _held = q.lock(&link, "f").expect("the daemon's operation");
    let t = tokio::time::Instant::now();
    let Err(e) = q.lock_waiting(&link, "f", Duration::from_millis(200)).await else {
        panic!("a decision during a long operation went through");
    };
    assert_eq!(e.code, code::BAD_STATE, "{}", e.message);
    assert!(
        t.elapsed() >= Duration::from_millis(200),
        "{:?}",
        t.elapsed()
    );
    assert!(
        q.lock_waiting(&link, "g", Duration::ZERO).await.is_ok(),
        "another file"
    );
}
