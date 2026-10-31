// SPDX-License-Identifier: AGPL-3.0-only
//! File check worker in the sandbox, for the tests of the `antenna-files` crate. In the product the same code is
//! started by `antennad` as a hidden subcommand (SPEC §14: one binary). The secret scanner is
//! `antenna_files::secrets::scan_secrets` (the same one used for messages).
//!
//! `antenna-files-sandbox check`: frame protocol over stdin/stdout (`antenna_files::worker`); `antenna-files-sandbox
//! selftest <probe>`: isolation check on this machine; `antenna-files-sandbox av-exec …`: run an external antivirus
//! under isolation.

fn main() {
    let args: Vec<String> = std::env::args().collect();
    std::process::exit(antenna_files::worker::dispatch(&args[1..]).unwrap_or_else(|| {
        eprintln!("usage: antenna-files-sandbox check | selftest <probe> | av-exec …   (internal: started by the Antenna daemon)");
        2
    }));
}
