#!/usr/bin/env bash
# Runs the three variants of the combined stack build. Prints the result of each variant.
set -u
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-../target}
BIN=$CARGO_TARGET_DIR/debug/spike-combined
cp Cargo.toml Cargo.toml.orig
unpatch() { cp Cargo.toml.orig Cargo.toml; }
echo "=== A: iroh+iroh-blobs+libsignal(SPQR)+libcrux-ml-dsa+rmcp+biscuit+rusqlite/sqlcipher (without libcrux-kem)"
unpatch; nice -n 10 cargo build 2>&1 | grep -E "^error|Finished" | sort -u; "$BIN"
echo "=== B: + libcrux-kem 0.0.9 (X-Wing), crates.io"
unpatch; nice -n 10 cargo build --features xwing 2>&1 | grep -E "^error|Finished|^\s+--> .*libcrux" | sort -u
echo "=== C: + [patch] libcrux-ml-kem and libcrux-kem from git cryspen/libcrux@c938b46 (main, not a release)"
sed -i 's/^# \[patch.crates-io\]/[patch.crates-io]/; s/^# libcrux-ml-kem = { git/libcrux-ml-kem = { git/; s/^# libcrux-kem = { git/libcrux-kem = { git/' Cargo.toml
nice -n 10 cargo build --features xwing 2>&1 | grep -E "^error|Finished" | sort -u; "$BIN"
echo "duplicated libcrux crates in C:"; cargo tree --features xwing -d 2>/dev/null | grep -E "^libcrux" | sort -u | sed 's/^/  /'
unpatch; rm -f Cargo.toml.orig; cargo generate-lockfile -q 2>/dev/null || true
