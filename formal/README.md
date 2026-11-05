<!-- SPDX-License-Identifier: Apache-2.0 -->
# Formal model of pairing v1 (ProVerif)

SPEC §15: "a formal model of pairing and the handshake in ProVerif or Tamarin, before the MVP release"; SPEC §18: "commit-then-reveal
is confirmed by a formal model and a test". The model is built from the text of `docs/PROTOCOL.md` (§3–§11, the combination points
§14 C1–C8, the goals §15 G1–G6) and checked against `crates/x-core/src/pairing.rs`. The tool is ProVerif 2.05 (a symbolic
Dolev–Yao model, an unbounded number of parallel sessions).

**The result in one line:** no attacks on pairing v1 as described in PROTOCOL.md were found, even against the strongest
attacker (TLS compromised, the link intercepted and substitutable, a weak SAS, owner A with many invites at once and a
voice that does not name the session); the model catches all nine negative controls, deliberately broken versions of the protocol, including both
weaknesses of v0 (F-3, F-4), so it does not "prove everything". The specification inaccuracies that
the modeling uncovered, and what was done about them, are in the section "Specification refinements". The run results are in `run.log` and the table below.

**v1 versus v0 (2026-10-02).** The first version of the model (commit `a981c11`) described pairing v0. Based on its findings the protocol
was changed (D-39, CONTROL §6): (1) `psk_mac` covers the whole body of M1: `v`, `suite`, `C_B`, `P_B`, `addrs` (F-3);
(2) owner A confirms the link with the code that was confirmed to them by voice, and the daemon accepts "yes" only for the
invite with that code (F-4). The model was updated: the body of M1 and `addrs` are in M1 and in `psk_mac`; the human channel is now
shared by all of the owner's invites (previously each pair had its own; that was an assumption); two new negative
controls, `neg_v0mac` (the v0 MAC) and `neg_nocode` ("yes" without a code), show exactly what the v1 changes closed.

## How to run

```bash
formal/run.sh                 # all 15 scenarios, checked against the EXPECT marks, the result in formal/run.log
formal/run.sh psk tls         # selected scenarios
proverif -lib formal/pairing_v1 formal/pairing_v1.pv   # one scenario by hand (from the formal/ directory, without the prefix)
```

`run.sh` runs each scenario under `ulimit -v` (6 GB), `timeout` (3600 s) and `nice -n 10`, 3 in parallel
(`PV_MEM_KB`, `PV_TIMEOUT`, `PV_JOBS`), checks ProVerif's final summary against the `EXPECT true|false` marks in the `.pv` files and
exits with code 1 on any mismatch. The full output with traces of the attacks found is in `formal/out/<scenario>.txt`
(not committed to git; it can be reproduced in minutes).

**Installing ProVerif without system packages** (details and gotchas: `docs/TROUBLESHOOTING.md`, the section "Formal model of pairing"):

```bash
curl -sSLo ~/.local/bin/opam https://github.com/ocaml/opam/releases/download/2.6.0/opam-2.6.0-x86_64-linux && chmod +x ~/.local/bin/opam
export OPAMROOTISOK=1 OPAMYES=1
opam init --bare --disable-sandboxing && opam switch create pv ocaml-base-compiler.4.14.2
eval $(opam env --switch=pv)
curl -sSLO https://bblanche.gitlabpages.inria.fr/proverif/proverif2.05.tar.gz   # sha256 4871f53c32ab4a04669a060c4886ba5d9080496963fb980a9a62d2c429ceabc4
mkdir -p ~/.local/opt && tar xzf proverif2.05.tar.gz -C ~/.local/opt && cd ~/.local/opt/proverif2.05 && ./build -nointeract
ln -sf ~/.local/opt/proverif2.05/proverif ~/.local/bin/proverif
```

(`opam install proverif` does not fit: it pulls in `lablgtk` → GTK2 → apt.)

## Files

| File | Contents |
| --- | --- |
| `pairing_v1.pvl` | The shared part: primitives, combination points C1–C8, events, processes A and B (the steps of §8), two transports |
| `pairing_v1.pv` | **The main scenario**: the strongest attacker, all properties 1–5 |
| `psk.pv` | The link secret has not leaked, TLS is compromised: PSK and key confirmation (property 3) |
| `tls.pv` | TLS intact, the link intercepted, a future quantum attacker: secrecy of X, K_A, K_B, link_id (properties 1, 6) |
| `e2e_pq.pv` | TLS broken, the link intercepted, a future quantum attacker: secrecy of the E2E key |
| `replay.pv`, `replay_tnull.pv` | One-time use of the link: what binding psk_mac to the exporter gives and what burning the invite gives |
| `button_single.pv` | D-95: owner A's confirmation without the code when one invite per owner shows a code at a time |
| `neg_*.pv` | Negative controls: the protocol is deliberately broken, and the model must find an attack |
| `run.sh`, `run.log` | The run and its result |

## Scenarios and the attacker

The Dolev–Yao attacker controls the network and the relay: it reads, delays, substitutes and inserts any messages, starts
any number of its own sessions, invites and joins by itself. Honest invites and joins are unbounded and run in
parallel.

| Scenario | TLS transport | Link | What is checked |
| --- | --- | --- | --- |
| `pairing_v1` | **compromised** (T-null) | **intercepted and substitutable** | SAS / commit-then-reveal, agreement, both owners, M5 over the network, E2E secrecy, downgrade, identity binding |
| `psk` | compromised (T-null) | reached only B | psk_mac, key confirmation before the SAS, secrecy of K_A, K_B, link_id |
| `tls` | intact (T-tls), PQ hybrid | intercepted and substitutable | secrecy of X, K_A, K_B, link_id, also against a future quantum attacker (truncated after key confirmation, see "Assumptions" item 12) |
| `e2e_pq` | compromised (T-null) | intercepted and substitutable | secrecy of the E2E key, including against a future quantum attacker |
| `replay` / `replay_tnull` | intact / compromised | reached only B | replay of M1 if A did not burn the invite |
| `button_single` | compromised (T-null) | intercepted and substitutable | both owners (Q4) with a confirmation without the code, one invite with a code per owner (D-95) |
| `neg_*` | compromised, or intact without PQ | intercepted | each protection is needed on its own |

### Choice of the TLS abstraction (property 6)

**Both** extreme abstractions are used, because they answer different questions:

- **T-null: the transport belongs to the attacker.** The attacker tells each side the exporter `X`, the peer's key and the TLS group
  (it can give both the same `X` and become a transparent intermediary, it can be a "server" with any key, including
  a stolen `ek_A`). This is stronger than "the attacker as a TLS server": it covers both a bug in TLS and a leak of endpoint keys.
  If a property holds here, it holds for any behavior of the transport. This is exactly where one sees what the application-level
  PSK and SAS are for: properties 1–4 are proven in T-null.
- **T-tls: TLS 1.3 intact.** A 1-RTT abstraction: `ClientHello{g^x, ek_kem}` → `ServerHello{g^y, ct}`, a `CertificateVerify`
  by the server with the key `E_A` and by the client with the key `E_B` over the transcript (iroh: mutual authentication by raw Ed25519 keys),
  the secret = X25519 ‖ ML-KEM-768, `X = Exporter(secret, transcript, E_A, E_B)`. Ephemeral X25519 is written as a KEM
  (DHKEM: `g^x` is the key, `g^y` the "ciphertext", `g^xy` the shared secret) without the Diffie–Hellman equation: with the equation
  the scenario produced no result in 4 minutes (2.4 GB, stopped); the only thing lost is the ability to forward someone else's
  `g^y` to another client, which gives nothing (the attacker does not know the secret anyway). The TLS records (M1…M4) in the model
  go in the clear; this only strengthens the attacker. It is needed for the secrecy of the pairing keys (G4): with an intercepted link,
  `K_A`, `K_B`, `link_id` rest only on `X`.

Agreement and the "both owners" rule are not checked separately with honest TLS: they follow from the main scenario.
A T-null attacker can reproduce any behavior of honest TLS (give both sides the same fresh `X`) while knowing
more, and the honest sides use `X` only as an opaque value in hashes, so any attack on
agreement with honest TLS would also be an attack in T-null. For secrecy this is not so (in T-null `X` is known), so
the secrecy of the pairing keys is checked in `tls.pv`.

TLS 1.3 itself is not proven (it has its own analyses: RFC 8446 Appendix E, the reftls/Tamarin TLS 1.3 models); the hybrid
`X25519MLKEM768` is modeled as "only someone who knows both the DH part and the KEM part knows the secret".

## Mapping between the model and PROTOCOL.md

| PROTOCOL.md | In the model (`pairing_v1.pvl`) |
| --- | --- |
| §3 the link `E_A.s.relay` | the scenario's main process: `out(c, (ea, s))` is the interception; B reads the link from `c` (substitution) or from the private `linkch` |
| §4 one session, burning after a correct psk_mac | an invite has exactly one session of A after the PSK check (see "Assumptions" item 6); without burning: `replay*.pv` |
| §5 the TLS group check, the exporter | `if grp = KX_PQ` (T-null); `hsHybrid`/`exporterF` (T-tls) |
| §6 messages M1…M8 | `in`/`out` in `A_core`, `A_after_confirm`, `B_core` with the same fields; `addrs` is an opaque fresh value of B (in M1 and in `psk_mac`, not in TH) |
| §7, §14 C1 `psk_mac` (v1) | `pskmac(kpsk(s), X, E_A, E_B, m1body(v, suite, C_B, party(P_B), addrs))`; v0: `pskmac0(kpsk(s), X, E_A, E_B)` (only the `neg_v0mac` control) |
| C2 `C_B` | `commitB(X, N_B)` |
| C3 `TH` | `th((hdr(v, SUITE, KX), E_A, E_B, X, C_B), N_A, N_B, (party(P_A), party(P_B)))` |
| C4, C5 `PRK`, `K_A`, `K_B`, `link_id` | `prk(X, s)`, `kA`, `kB`, `linkid` |
| C6 `kc_*`, `mac_A`, `mac_B` | `mac(K, label, TH)` with the labels `L_KC`, `L_CODE`, `L_OWNER` |
| C7 `SAS` | `sasOf(TH)`: a weak function with grinding (`forge_na`, `forge_nb`) |
| C8 libsignal | the M6 bundle (identity = `P_A.identity_key`, the SPK and KEM prekey signatures), M7 PreKeySignalMessage, M8; pinning the identity from TH |
| §8 A1…A13, B1…B10 | the comments `A3`…`A12`, `B1`…`B10` in the processes |
| §9 confirmation by the owners; CONTROL §6 `pairing_confirm` with a code | owner A's voice channels: `dictA` (reads out the code), `matchedA` ("it matched" about the code; the owner enters this code); A9 is `heard = code`; the events `B_CodeOK`, `OwnerA_Confirm` |
| §10 the libsignal session | `A_after_confirm` and the tail of `B_core` |
| §11–§13 pairwise endpoint, link format, accept-list | not modeled (after activation) |
| C9–C11 (message ID, padding, keystore) | not modeled (not part of pairing) |
| §15 G1–G6 | queries Q1–Q7, P1–P4, T1–T2 (the results table) |

## Assumptions and abstractions

1. **Perfect cryptography (a symbolic model).** SHA-256, HKDF, HMAC are free functions without inverses
   (one-way, collision-free). The different labels `x/pair/v0/…`, `x/pair/v1/psk-proof` are different functions: the labels differ, and the fields after them
   are fixed-length or in `lp()`, so the inputs of different combination points do not coincide (checked against §7).
2. **TLS**: the two abstractions above.
3. **The link** in the main scenario is intercepted and can be substituted (the attacker knows `E_A`, `s` and can give B its own
   link). In `psk`/`replay` it reached only B.
4. **The human channel (v1).** Owner A has many invites at once and talks by voice/in person to many people, and
   neither the voice nor the people tell sessions apart. The `dictA` channel: owner A reads out the code of **some** of their invites
   to **someone** they talk to; that person enters it into **some** join of their own. The `matchedA` channel: the person says
   "it matched" about the code read out to them, and owner A enters **that** code in `x pairing confirm`; the daemon accepts
   "yes" only for the invite with that code (CONTROL §6). The channels are shared by all invites and all the people one owner A
   talks to: only the code binds "it matched" to an invite. The channel is authentic (the attacker cannot insert
   its own word), but not secret (the attacker hears the code: `out(c, code)`), and asynchronous. In the v0 model each
   pair "A wants to link with B" had its own channel; that was an assumption; v1 removes it (the `neg_nocode` control shows that without
   the code in the confirmation, removing the assumption gives an attack).
5. **Weak SAS**: below, in a separate section.
6. **One session per invite.** In the code, after a correct `psk_mac` the invite burns on any outcome; failed
   attempts before that (a wrong psk_mac, a foreign version) get only `abort`. In the model an invite has one session of A;
   failed attempts are omitted: they give the attacker nothing but the constant `abort`, so any attack on the code
   carries over to the model (the attacker simply makes no failed attempts). What would happen without burning: `replay*.pv`.
   The 5-attempt counter, TTL and timeouts are not modeled: they protect against guessing and denial of service, and are not
   a security property of the symbolic model.
7. **Downgrade: A in the model is more lenient than the code.** The code accepts only `v = 0` and its own `SUITE`. In the model A also accepts
   a hypothetical `SUITE_LEGACY` and puts the received `v`/`SUITE` into TH (the code puts the constants; with a single allowed
   value this is the same thing). A lenient A gives the attacker more options, so what is proven also holds for the code, and
   it is also checked that TH protects a future choice among several suites.
8. **PQXDH is simplified to `SK = KDF(DH1 ‖ SS)`**, where `DH1 = DH(IK_B, SPK_A)` and `SS` is ML-KEM to the signed KEM prekey.
   DH2 = DH(EK_B, IK_A), DH3 = DH(EK_B, SPK_A), DH4 (the one-time prekey) are omitted. This coarsening **favors the
   attacker**: it chooses its own `EK` and computes DH2–DH4 for its own messages; for others' (the honest B's) they only
   add obstacles. So the secrecy of `SK` and the agreement proven for the simplified PQXDH also hold for the full one.
   The reason for the simplification is time: with DH1–DH3 the main scenario produced no result in 4.5 min, with DH1 + DH2 the query Q2
   did not finish in 10 min (2 GB), and with DH1 alone the whole scenario takes a minute and a half.
   The one-time prekey is not signed: substituting it only gives a denial of service (A will not decrypt M7).
9. **The side's keys.** `party(P) = (identity_key, the rest)`: the link-root Ed25519 + ML-DSA-65 and the pairwise endpoint in this
   slice are only part of TH (signatures come in the next slice), so they are modeled as one fresh value.
10. **The quantum attacker (phases).** In `tls.pv`, `e2e_pq.pv` and `neg_classic_tls.pv`, after phase 0 (an active
    classical attacker) comes phase 1: all X25519 scalars (TLS, identity, signed prekey, EK) and the Ed25519 keys
    of the honest sides are revealed; the ML-KEM secret keys never are. This is the "harvest now, decrypt later" model (G4).
11. **Precision.** `set preciseActions = trueWithoutArgsInNames`: each input of one session receives one message.
    Without it, ProVerif's abstraction lets one session of B "receive" two different M2s, learn `N_B` from the answer to the first
    and grind `N_A'` in the second, and commit-then-reveal "is not proven" (checked on a minimal prototype:
    `cannot be proved` without the setting, `true` with it, 0.02 s). The setting does not sacrifice soundness: if ProVerif says
    `true`, the property holds under any precision settings (the ProVerif manual, "Precision, performance, and termination
    settings").
12. **The `KCONLY` truncation in `tls`, `neg_classic_tls`, `replay`.** The protocol as is, but the sides stop after key
    confirmation (A sent M4, B checked it). The full model with honest TLS did not saturate within 10 minutes (50 thousand clauses,
    2 GB, stopped). The truncation is sound for the properties checked there: `X` and `link_id` are not used afterwards at all,
    `K_A`, `K_B` only as MAC keys over a fixed TH (M5, M6), and a MAC does not reveal its key; the `psk_mac` check event
    (`replay`) happens before the truncation. The cut-off steps would only add knowledge to the attacker unrelated to
    these keys.

## Weak SAS and commit-then-reveal (property 4)

**How it is modeled.** ProVerif does not compute probabilities, so "6 digits are weak" is written symbolically: the function
`sasOf(TH)` is a destructor with grinding rules. An attacker who knows all the other fields of TH computes
`forge_na(code, …)`, an `N_A` such that `SAS(TH) = code`, and likewise `forge_nb`. This is a symbolic rendering of an offline search over
10⁶ variants: whoever has the freedom of the last move can fit the code to anything. The code comparison is `code = sasOf(TH)`.

**Why grinding on `N_A` and `N_B` is enough.** Grinding on a field makes sense only if the attacker chooses it
already knowing all the other fields of TH. The attacker sends its fields as follows:
- an intermediary in the role of B (the session with A): `E_B'`, `X` (with broken TLS), `C_B'`, `P_B'` in M1 or earlier, while A
  generates `N_A` **after** M1; `N_B'` is revealed later, but it is bound by the commitment `C_B'` from M1;
- an intermediary in the role of A (the session with B): `E_A'`, `X`, `P_A'`, `N_A'` in M2 or earlier, while B reveals `N_B` **after** M2.

So grinding on any earlier field is no stronger than grinding on `N_A'` (in M2) or on `N_B'` (in M3), and these two are
given to the attacker. Grinding `C_B` is useless: A checks that `N_B` opens it.

**What is proven** (main scenario, `true`): if node B accepted the code read out to it, it is the code of **the same** TH that
node A showed (Q1), with a weak SAS, broken TLS and an intercepted link. From this follow agreement (Q2, Q3) and the
"both owners" rule (Q4). An attacker that fixed its values before seeing the last random contribution
of the honest side cannot fit the SAS.

**What the model catches** (negative controls, `false` with an attack trace):
- `neg_nocommit`: B reveals `N_B` in M1: the intermediary sees `N_B` and grinds `N_A'` to match the code from the session with A;
- `neg_nocheck`: A does not check the opening of `C_B`: the intermediary completes the session with B and grinds `N_B'` after `N_A`.

**What remains a probabilistic argument (not proven by ProVerif).** The symbolic model rules out guessing: in it the attacker cannot
hit the right code blindly. In reality it can, with probability:
- In the session with A the transcript TH₁ is fixed after M2 (`N_B'` is bound by the commitment); in the session with B the transcript TH₂ is fixed
  only after B has revealed `N_B`, that is, after all of the attacker's moves. With HKDF as a random oracle
  `SAS(TH₂)` is uniform and independent of `SAS(TH₁)` (for TH₁ ≠ TH₂).
- The probability of a match is at most the maximum probability of a single code: `⌈2³²/10⁶⌉/2³² = 4295/2³² ≈ 1.0000076·10⁻⁶`
  (the bias from `mod 10⁶` is a relative 7.6·10⁻⁶; the statistical distance from uniform is ≈ 2⁻¹⁷, but for a SAS what matters is
  precisely the maximum). Plus negligible terms for breaking the commitment (SHA-256) and HKDF.
- **One attempt per invite.** The protocol's "5 attempts" limit applies only to a wrong `psk_mac` (before
  the secret is checked); after a correct `psk_mac` any outcome, including a mismatched code, burns the invite, and B makes
  exactly one join. Over q invites the attacker wins with probability ≤ q·1.0000076·10⁻⁶, and every
  loss is visible to both owners ("the code didn't match"). Even to try, the attacker needs to intercept the link and either
  substitute it for B or break TLS.

## Negative controls

Each one is the same `pairing_v1.pvl` with one deliberately broken detail (the `variant` switch); the model must find
an attack, otherwise its "proofs" are worth nothing.

| File | What is broken | What must break |
| --- | --- | --- |
| `neg_nocommit.pv` | B reveals `N_B` already in M1 | SAS: B accepts the code of someone else's transcript; owner A confirms a link with the intermediary |
| `neg_nocheck.pv` | A does not check that `N_B` opens `C_B` | the same |
| `neg_autoconfirm.pv` | A does not wait for the spoken "it matched" (as `x invite --confirm`) | A is active although owner B never entered the code |
| `neg_nocode.pv` | owner A's "yes" without a code (as in v0) | F-4: A has two invites; an honest B entered the code for the first and said "it matched", but the "yes" went to the second, where the intermediary reached M5 by itself: A is active with the intermediary |
| `neg_v0mac.pv` | `psk_mac` as in v0 (without the body of M1) | F-3: with broken TLS and an undisclosed link the attacker changes the body of M1 (`C_B`, `P_B`, `addrs`), and A accepts the `psk_mac` |
| `neg_nohdr.pv` | the version and the suite are not part of TH | downgrade to `SUITE_LEGACY` |
| `neg_nopin.pv` | B does not check the bundle's identity against `P_A` from TH | B brings up E2E with the intermediary without owner A's decision |
| `neg_classic_tls.pv` | TLS with X25519 only, without ML-KEM | `X`, `K_A`, `link_id` are revealed to the quantum attacker (the E2E key is still held by ML-KEM in PQXDH: `e2e_pq`) |
| `replay_tnull.pv` | A does not burn the invite, TLS is broken | replay of an honest B's M1 **in full** (the v1 MAC does not catch it: both `X` and the body are replayed; only burning stops it; the replay does not get past M3) |

`neg_nocommit` and `neg_nocheck` are truncated after owner A's decision and after the code entry on B (libsignal does not take part in them):
their properties are decided earlier, and with `N_B` revealed, saturation of the full model did not finish in 7 minutes (25 thousand clauses and
growing, 1.5 GB; stopped), whereas the truncated one finds the attack in 0.3 s. The truncation removes only the steps after the checked events, so the attack found is an attack on the full model too.

## Specification refinements

No attacks on the protocol as described in PROTOCOL.md were found, in either v0 or v1. Modeling v0 uncovered
inaccuracies in the wording and two weaknesses, which are closed in v1; the code was not changed as part of the modeling.

- **F-1 · What holds "condition 2" of §9.** `mac_B` (M5) and `mac_A` (M6) are authentic as long as `PRK` is secret: TLS is intact **or**
  the link secret has not leaked. If both are broken, the attacker computes both (Q5 is `false` with a trace). Then for A,
  "owner B entered the code" is confirmed only by the spoken "it matched", and for B, "owner A confirmed" only by the bundle signed by
  the identity from TH (B8): A creates it only after the owner's decision. Without the B8 check there is an attack (`neg_nopin`). Recorded
  in PROTOCOL §15; in the v1 code the B8 check was moved into `check_bundle` with a unit test (D-39).
- **F-2 · The SAS bias (§14 C7).** It said "≈ 2⁻³²"; in fact the maximum code probability is `4295/2³² ≈ 1.0000076·10⁻⁶`,
  and the statistical distance is ≈ 2⁻¹⁷. The conclusion "negligible" is right; the number was corrected.
- **F-3 · `psk_mac` did not cover the body of M1: CLOSED in v1.** In v0, with broken TLS, an attacker without `s` changed the body of M1
  (`neg_v0mac` is `false`). In v1 `psk_mac` covers `v`, `suite`, `C_B`, `P_B`, `addrs`: substituting any field without `s` is
  impossible even with broken TLS (`psk`, P1 is `true`). **What remains:** the MAC does not catch a replay of M1 **in full** with broken TLS:
  the attacker replays both `X` and the body (`replay_tnull`, injectivity is `false`); it is stopped by the burning of the
  invite after the first correct `psk_mac` (mandatory, PROTOCOL §4, §15). The replay is harmless: without `s` it cannot get
  past M3 (`replay_tnull` is `true`). Catching the replay with the MAC is possible only with a fresh challenge from A before M1 (an extra half round),
  which is unnecessary given that the invite burns.
- **F-4 · "It matched" does not name the session: CLOSED in v1 for `x pairing confirm`.** In v0 owner A's "yes", with several
  invites waiting, could go to the wrong one (`neg_nocode` is `false`, the trace: two invites, "it matched" for the first
  activates the second with the intermediary). In v1 `pairing_confirm` carries the code entered by the owner, and the daemon accepts "yes"
  only for the invite with that code: the main scenario with a voice channel shared by all invites gives Q4 `true`.
  **Since D-95 (2026-10-05)** the owner confirms with one button once the joiner entered the code, but the daemon accepts a "yes"
  without the code only for an invite during whose life no other invite of the node showed a code; otherwise it answers
  `code_required` and the owner types the code. `button_single.pv` models exactly that (one invite with a code per owner, "yes"
  without a code): Q4 `true` ×2; `neg_nocode` stays the control that shows why two codes at once need the typed code
  (`crates/antenna-cli/tests/link.rs::two_invites_with_codes_at_once_need_the_typed_code`, with a negative control: without the
  daemon's check the test fails).
- **F-5 · What to put into TH with several versions (§15 G5).** TH currently takes the implementation's constants; with a second version
  or suite, the values each side saw; otherwise a downgrade (`neg_nohdr`). In v1 the `suite` field is in addition
  covered by `psk_mac`: with an undisclosed link it cannot be substituted even without TH.
- **F-6 · The code in the confirmation is not mandatory everywhere (new, v1; the code was not changed). Since then:** the
  follow mode required the code (x-control/2, `input_rejected`); since D-95 the daemon itself decides when a "yes" without a code is
  enough (F-4 above), and neither the CLI nor the window fills the code in. The original finding: `x pairing confirm` requires the code
  (`control.rs`, `code` is mandatory). But in the `x invite` dialog mode (follow) the daemon accepts `Input::Confirm` even without
  a code (`invites.rs::decide`: the check is only `if let Some(c) = code`), and the CLI itself fills in the current code of the same
  invite (`x-cli/src/main.rs`, `code: last_sas.clone()`). There the "yes" is bound to the invite by the terminal, not by
  the code: if the owner has two `x invite` sessions open and answers "yes" in the wrong one, the code check will notice nothing; this is
  exactly `neg_nocode`. It is mitigated by the fact that each terminal shows the code of its invite next to the question. CONTROL §6
  says plainly "the client does not fill in the current code by itself". Proposal: in follow mode ask the owner for the code in the same way
  as in `pairing confirm` (or always require `code` in `Input::Confirm`).

## Results

The full output is in `run.log`. Notation: **true**: the property is proven for an unbounded number of sessions; **false**:
an attack trace was found; the expectation is recorded in the `.pv` file before the run with an `EXPECT` mark.

The whole run takes about 9–11 minutes on the build server (16 CPUs, shared with other builds; 2 scenarios in parallel, 4 GB per process,
`nice -n 10`): the longest are `tls` (≈6 min), `neg_nopin` (≈4 min) and the main scenario (≈3 min); the rest take from fractions of a second to
a minute and a half; the exact seconds are in `run.log`. All 14 scenarios matched the expectations; `button_single` (D-95, added
2026-10-05) took 23 s and matched too.

| # | Property (property no. · PROTOCOL §15) | Query | Scenario: transport · link | Result |
| --- | --- | --- | --- | --- |
| — | An honest run reaches activation on A and on B (the model is not empty) | Q0 ×2 | `pairing_v1`: broken · leaked | reachable |
| 4 · G2 | **Commit-then-reveal:** the code accepted by node B is the SAS of the same TH that node A showed (weak SAS) | Q1 | `pairing_v1`: broken · leaked | **true** |
| 2 · G1 | Injective agreement A → B: TH, `v‖SUITE‖KX`, both identities, the E2E key | Q2 | `pairing_v1` | **true** |
| 2 · G1 | Injective agreement B → A | Q3 | `pairing_v1` | **true** |
| 2 · G3, F-4 | A's link and B's link are active only if owner B entered the correct code **and** owner A confirmed, with many invites at A and a voice that does not name the session (confirmation with a code, v1) | Q4 ×2 | `pairing_v1` | **true** |
| 2 · G3, D-95 | The same with a confirmation **without** a code, when one invite per owner shows a code at a time (the daemon's rule; two codes at once need the typed code) | Q4 ×2 | `button_single`: broken · leaked | **true** |
| 2 · §9 | The network "B entered the code" (M5) proves nothing by itself | Q5 | `pairing_v1` | false, as expected; the trace: an attacker with the intercepted link computes `mac_B` itself |
| 1 · C8 | Secrecy of the E2E key (PQXDH) of an activated link | Q6 ×2 | `pairing_v1` | **true** |
| 5 · G5 | Downgrade: A (which in the model also accepts `SUITE_LEGACY`) never activates a link with it | Q7 | `pairing_v1` | **true** |
| 3 · G6, F-3 | `psk_mac` v1: A accepted M1 for `(E_A, E_B, X)` and the body `(v, suite, C_B, P_B, addrs)` ⇒ B, who knows `s`, sent exactly that M1 | P1 | `psk`: broken · not leaked | **true** |
| 3 | Key confirmation catches the substitution of any field of TH before the SAS (both sides) | P2 ×2 | `psk` | **true** |
| 1 · G4 | Secrecy of `K_A`, `K_B`, `link_id` on both sides | P3 ×6 | `psk` | **true** |
| 3 | M5 cannot be forged without `s` | P4 | `psk` | **true** |
| 1, 6 · G4 | Secrecy of `X`, `K_A`, `K_B`, `link_id` of a session with the genuine A, also against a future quantum attacker | T1 ×4 | `tls`: intact (PQ) · leaked | **true** |
| 1 · G4 | Secrecy of the E2E key against a future quantum attacker | T2 ×2 | `e2e_pq`: broken · leaked | **true** |
| 3 | One-time use: replaying M1 is impossible even if A did not burn the invite | inj | `replay`: intact · not leaked | **true** |
| 3 | The same with broken TLS: a replay of M1 **in full** is stopped only by burning the invite | inj | `replay_tnull`: broken · not leaked | false, as expected (F-3) |
| 3 | …but even in a replay the body of M1 is exactly what B sent, and the replay does not get past M3 | P1, "A_KC ⇒ B_Reveal" | `replay_tnull` | **true** ×2 |
| control | B reveals `N_B` in M1 | Q1, "A confirmed ⇒ B entered" | `neg_nocommit` | false: attack found |
| control | A does not check the opening of `C_B` | the same | `neg_nocheck` | false: attack found |
| control | A does not wait for the spoken "it matched" | Q4, Q2 | `neg_autoconfirm` | false: attack found |
| control F-4 | Owner A's "yes" without a code (v0) | Q4 | `neg_nocode` | false: attack found |
| control F-3 | `psk_mac` v0 (without the body of M1) | P1 | `neg_v0mac` | false: attack found |
| control | The version and the suite are not in TH | Q7 | `neg_nohdr` | false: downgrade found |
| control | B does not check the bundle's identity | Q6, Q4 for B | `neg_nopin` | false: attack found |
| control | TLS without ML-KEM | T1 for `X`, `K_A`, `link_id` | `neg_classic_tls` | false: revealed in phase 1 |

The assumptions for all rows are in the section "Assumptions and abstractions"; for the SAS there is also the probabilistic remainder of 10⁻⁶ per invite.

## What is not proven and why

- **Probabilities.** 10⁻⁶ per invite is the argument above, not a ProVerif result. Computational soundness (the step from the
  symbolic model to security in bits) is not established; the next step is CryptoVerif, if needed.
- **TLS 1.3 and the X25519MLKEM768 hybrid** are an abstraction, not a proof; we rely on their own analyses.
- **libsignal**: PQXDH is simplified (item 8), Triple Ratchet and SPQR were not modeled (verified by Signal, SPEC §14).
- **The correspondence of the code to the model** was checked by reading `pairing.rs` (v1), `invites.rs`, `control.rs` against the model, not by
  extracting a model from the code. No discrepancies were found in pairing: `psk_mac` v1 over the fields of the received M1, A burns
  the invite after a correct `psk_mac`, checks the opening of `C_B`, waits for the owner's decision before M6; B checks the bundle's
  identity against `P_A.identity_key` (`check_bundle`). In the control layer: F-6 (in follow mode the client fills in the code).
- **The human factor.** Owner A confirming the link without hearing "it matched", or naming a code other than the one that was
  confirmed to them, is outside the model. Confusion between invites and the people one talks to (F-4) is now **inside** the model: the voice channel is shared,
  and only the code binds the link, or, for a confirmation without the code (D-95), the daemon's rule that only one invite
  shows a code at a time (`button_single`). Code entry on B (rather than a button) is what makes "it matched" meaningful, and that is in the model.
- **Denial of service, TTL, timeouts, the attempt counter, metadata** (IP, relay, `addrs`), side channels,
  constant-time comparisons are outside the symbolic model.
- **After activation** (§11–§13): the pairwise endpoint, the accept-list, the link format were not modeled.

## How the model was built

Difficulties: `docs/TROUBLESHOOTING.md`. In short: the first version ate
8 GB in 2 minutes (too many grinding fields and arguments); it was rewritten with the fields of TH grouped and a justification of why
two grinding functions are enough; PQXDH with even two DHs did not fit into 10 minutes, so DH1 + ML-KEM was kept, with
a justification that this coarsening favors the attacker; the model with honest TLS did not saturate as a whole, so X25519 in TLS
was written as a KEM, and secrecy is checked on a model truncated after key confirmation; without `preciseActions`
commit-then-reveal "was not proven", and the cause was found on a minimal prototype. The move to v1 took about an hour: the body of M1
became a structure in `psk_mac`, the human channel became shared per owner; the two new controls found the v0 attacks on the first
run, and the main scenario became twice as long (≈3 min instead of 1.5) because of the shared channel.
