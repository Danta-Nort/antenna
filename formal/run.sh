#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Runs every scenario of the pairing v1 formal model (ProVerif 2.05) and checks the results against expectations.
#   formal/run.sh               — all scenarios
#   formal/run.sh psk tls       — selected ones (run.log is then appended to rather than overwritten)
# Every query in *.pv is marked with a comment "EXPECT true|false [×N]"; the script checks ProVerif's final summary
# ("Verification summary") against these marks in order and writes formal/run.log. The full output, including traces
# of the attacks found, goes to formal/out/<scenario>.txt.
# Limits (the build machine may be shared): memory per process PV_MEM_KB (6 GB), time PV_TIMEOUT (3600 s), nice 10,
# PV_JOBS processes in parallel (3).
set -u
cd "$(dirname "$0")"
PROVERIF=${PROVERIF:-$(command -v proverif || echo "$HOME/.local/bin/proverif")}
export PROVERIF
export MEM_KB=${PV_MEM_KB:-6000000}
export TIMEOUT=${PV_TIMEOUT:-3600}
JOBS=${PV_JOBS:-3}
ALL=(pairing_v1 psk tls e2e_pq replay replay_tnull button_single neg_nocommit neg_nocheck neg_autoconfirm neg_nocode neg_nohdr neg_nopin neg_v0mac neg_classic_tls)
if [ $# -gt 0 ]; then SCEN=("$@"); else SCEN=("${ALL[@]}"); fi
mkdir -p out
LOG=run.log
[ $# -gt 0 ] || : > "$LOG"
{
  echo "# formal/run.sh — $(date -u +%Y-%m-%dT%H:%M:%SZ), $("$PROVERIF" --help 2>&1 | head -1 | cut -d, -f1)"
  echo "# host: $(uname -srm), $(nproc) CPU; per-process limits: ${MEM_KB} KB of memory, ${TIMEOUT} s; ${JOBS} in parallel"
} >> "$LOG"

one() {
  s=$1
  start=$(date +%s)
  ( ulimit -v "$MEM_KB"; timeout "$TIMEOUT" nice -n 10 "$PROVERIF" -lib pairing_v1 "$s.pv" ) > "out/$s.txt" 2>&1
  echo "EXIT=$? SECONDS=$(( $(date +%s) - start ))" > "out/$s.status"
}
export -f one
printf '%s\n' "${SCEN[@]}" | xargs -P "$JOBS" -I{} bash -c 'one {}'

fail=0
for s in "${SCEN[@]}"; do
  python3 - "$s" >> "$LOG" <<'PY' || fail=1
import re, sys
name = sys.argv[1]
st = dict(kv.split("=") for kv in open(f"out/{name}.status").read().split())
rc, secs = int(st["EXIT"]), st["SECONDS"]
src = open(f"{name}.pv", encoding="utf-8").read()
exp = []
for m in re.finditer(r"EXPECT (true|false)(?: ×(\d+))?", src):
    exp += [m.group(1)] * int(m.group(2) or 1)
out = open(f"out/{name}.txt", encoding="utf-8", errors="replace").read()
summ = out.split("Verification summary:")[-1] if "Verification summary:" in out else ""
got = []
for line in summ.splitlines():
    if line.startswith("Query "):
        l = line.rstrip()
        r = "true" if l.endswith("is true.") else "false" if l.endswith("is false.") else "cannot be proved"
        got.append((r, l[6:]))
print(f"\n== {name}.pv  (exit {rc}, {secs} s)")
ok = rc == 0 and len(got) == len(exp)
if rc != 0:
    print(f"   !! ProVerif exited with code {rc} (124: timeout, 137/2: out of memory)")
if len(got) != len(exp):
    print(f"   !! {len(got)} queries in the summary, {len(exp)} EXPECT marks")
for i, (r, q) in enumerate(got):
    e = exp[i] if i < len(exp) else "?"
    ok = ok and r == e
    print(f"   [{'ok' if r == e else 'MISMATCH'}] expected {e:5} · got {r:5} · {q}")
print(f"   result: {'matches expectations' if ok else 'MISMATCHES FOUND'}")
sys.exit(0 if ok else 1)
PY
done
echo >> "$LOG"
if [ $fail -eq 0 ]; then echo "# ALL SCENARIOS MATCH EXPECTATIONS" >> "$LOG"; else echo "# MISMATCHES FOUND: see above" >> "$LOG"; fi
grep -E "^==|MISMATCH|!!|result:|^# (ALL|MISMATCHES)" "$LOG"
exit $fail
