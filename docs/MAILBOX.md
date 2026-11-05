<!-- SPDX-License-Identifier: Apache-2.0 -->
# Offline mailbox, content-free push and our own relay: specification

Status: **draft v1 for decision and review**, 2026-10-02. No code yet. License: Apache-2.0 (SPEC §16): this
document is enough to write the server, the client in the daemon and a formal model (ProVerif) independently of the reference implementation.

Basis: the requirement of a server at least for users to reach each other, with notifications and delivery even
when a user is offline, on a par with what Signal offers, and the decision that followed (DECISIONS "Server for mass adoption");
SPEC §4 (offline delivery v2: the mailbox stores only E2E blobs, the address changes every ratchet epoch; our own relay is v1.0),
§5, §7, §8, §13, §15, §19. Link format, envelope, padding, history verification, rekey: `docs/PROTOCOL.md` §12, §16–§19;
streams: PROTOCOL §20 (written in parallel; only referenced here). Notation: PROTOCOL §0 (`HKDF`, `HMAC`, `H` = SHA-256,
`lp`, `u8`, `u32be`, `u64be`, `rand`, `ct_eq`). New domain separation labels are in the `x/…` family (D-57).

This document does not change pairing or the link format unless explicitly marked; everything that changes PROTOCOL is collected in §9 and will go there
as a separate section once it is decided.

---

## 1. In short

**Architecture (7 points).**
1. **A mailbox is per link and direction, not per device and not per person.** Messages B→A on a link wait in a mailbox that
   the **recipient** A creates on **its own** server. Mailboxes of different links share no identifier; there are no per-device mailboxes
   and no "accounts" at all (SPEC §1, §5).
2. **An address = random capabilities, not a name.** The recipient creates a mailbox under a fresh random epoch
   `seed` and gives the contact **only the write right** (the write `seed`) **inside Triple Ratchet**, as a service
   message of the link. The server knows only hashes of capabilities. A new epoch = a new random `seed` in the ratchet: the server cannot
   link one link's mailboxes by identifiers, and a leaked capability "heals" together with the ratchet (PCS).
3. **The mailbox holds only `ct` under the mailbox's outer AEAD**: no `link_id` and no cleartext libsignal header (the ratchet
   key and counters in it are not encrypted and would link epochs). Sizes: the padding buckets of SPEC §7 + 49 bytes.
4. **"Sealed sender" without certificates:** a write to a mailbox does not name the sender (there are no accounts); only the
   write capability authorizes it; the sender's IP is hidden from someone else's server by **forwarding through one's own server** (mandatory for
   contacts at levels 1–2, like the relay rule D-26) or by Tor (v0.3).
5. **Anti-spam without accounts:** spam from strangers is structurally impossible (there are no public addresses; only someone
   to whom the recipient issued a capability inside E2E can write); creating mailboxes costs an adaptive proof-of-work + quotas (like the PoW of
   Tor onion services: almost free when idle). Anonymous credentials come later and only for a paid tier:
   there is no audited Rust implementation (§5.3).
6. **Push without content:** the mailbox wakes the device through a **push gateway** using a **handle sealed by the gateway**, unique to
   each mailbox. The mailbox server does not see the device token and cannot link mailboxes by push; the gateway sees the token but not the mailboxes or
   the links; the gateway is stateless (there is no token database). Apple/Google see only "the Antenna app was woken at t".
   Computers do not need push: an online daemon long-polls its mailboxes.
7. **The server is an accelerator, not a source of reliability.** The sender's outbox (D-21) keeps the blob until it is confirmed by history
   verification (§16) or by `parents`; loss, delay or tampering with data on the server loses no messages. Our own
   `antenna-server` is a single binary with the roles `mailbox`, `push`, `relay` (iroh-relay), `forward`; self-hosting and
   a managed "Antenna Cloud".

**What the mailbox server sees and does not see** (in detail: §8.2):

| Sees | Does not see |
| --- | --- |
| The IP and time of every access (for writes, if not forwarded), the size (bucket + 49 B), how many mailboxes are read from one IP/connection, the "wake" flag, that a mailbox has push (the device is mobile) | The content; libsignal headers; `link_id`; who writes and who reads (names, keys); the trust level; the push token; that two mailboxes belong to one link (except by correlation of IP and time) |

**Why not "like Signal" literally.** Signal is an account-based system: the server knows the recipient (the account), sealed sender
hides only the sender's name, and access is authorized by a delivery token from the profile key ("The service requires clients to
prove knowledge of the delivery token for a user in order to transmit 'sealed sender' messages to that user",
signal.org/blog/sealed-sender). We have no accounts, so we take a model closer to SimpleX (a queue per connection,
separate write and read IDs, a sender key) and strengthen it: rotation by epochs with PCS, an outer layer without cleartext
headers, a push gateway without a token database, a server that is not needed for reliability.

---

## 2. What we take from others and how we differ

| | Signal | SimpleX (SMP) | Session | **Antenna (this document)** |
| --- | --- | --- | --- | --- |
| The recipient's address on the server | An account (number/name) | A queue per connection: `RID` for the recipient and `SID` for the sender, "unique for the router" | Session ID (a key); stored by the recipient's swarm of nodes | A mailbox per link × direction × epoch × server; on the server, only the capability hashes `rid`/`wid` |
| Who can write | Whoever knows the delivery token (from the profile key) | The sender with the key `SK` after `SKEY` | Anyone who knows the Session ID | Only whoever received the write `seed` inside E2E |
| The sender from the server | Hidden (sealed sender), IP visible | Hidden; the IP is hidden by a proxy router (SMP v8 `PFWD`) | Hidden; onion requests through 3 nodes | Hidden; the IP is hidden by one's own forwarding server (§4.10) or Tor |
| Address change | No (account) | Can move to new queues ("negotiate using other SMP queue(s)") | No | Every epoch is a fresh random `seed` inside the ratchet |
| Who knows the push token | The Signal server (by account) | Notification router: the token, the number of queues and notifications per queue (`push-notifications.md`) | — (not checked) | Only the gateway, in transit; the mailbox sees a sealed handle, unique per mailbox |
| Undelivered messages when server data is lost | The only copy is on the server | The only copy is on the server | The request goes to 3 nodes of the recipient's swarm at once | Not lost: the sender's outbox + history verification (PROTOCOL §16) |
| Anti-spam | Token + account limits | Queues + a server password on `NEW` (at the operator's option) | PoW (older documentation) | The write capability + adaptive PoW and quotas on creation |

We take: separate read and write IDs and a notification flag in the write (SimpleX); forwarding through the sender's server
(SimpleX v8, Session's onion requests, in spirit); empty push and fetching by the app (Signal, SimpleX); adaptive PoW
(Tor 0.4.8). Our own: epochs with PCS, an outer mailbox layer without `link_id` and libsignal headers, sealed gateway handles,
a server that is not on the reliability path. All of it is assembled from known building blocks; we do not call it an invention.

---

## 3. Roles and components

```
 Sender S (daemon/app)                                              Recipient R (daemon/app)
   outbox ──① directly (iroh, pairwise endpoint) ───────────────────────────────▶ (as today, PROTOCOL §12)
     │                                                                       ▲
     └─② put(wcap, blob) ──[③ through one's own forward, if needed]──▶ ┌──────────────────┐  ⑤ get/ack(rcap)
                                                                 │ mailbox  (server │◀──────────────────── R
                                                                 │  chosen by R)    │
                                                                 └────────┬─────────┘
                                                                ④ wake(handle_box)  (only if the mailbox has push)
                                                                          ▼
                                                                 ┌──────────────────┐   APNs / FCM / UnifiedPush
                                                                 │ push gateway     │──────────────────────────▶ device R
                                                                 └──────────────────┘   (an empty "you have mail")
 relay (iroh-relay): NAT traversal for ①, the same binary, a different path/host name.
```

| Role | What it does | Who runs it | Keys and state |
| --- | --- | --- | --- |
| `mailbox` | Stores mailbox blobs, serves them for a read capability, wakes the gateway | Anyone: Antenna Cloud, a company, the user themselves | SQLite: capability hashes, blobs until fetched/TTL, the mailbox's push target; the PoW key |
| `push` | Accepts `wake(handle)`, wakes the device through APNs/FCM/UnifiedPush | For APNs and FCM of the official app, **only the app's publisher** (its APNs key and Firebase project are needed); for UnifiedPush, anyone | The handle sealing keys `K_G`, the verification code key `K_V`, APNs/FCM credentials. **No token database** |
| `relay` | iroh-relay 1.3 (NAT traversal, fallback, QUIC address) | Anyone | Stateless (SPEC §4) |
| `forward` | An HTTP CONNECT tunnel to someone else's mailbox server: that server sees the forwarder's IP, not the client's | The user's or the company's own server | Stateless |

A single binary `antenna-server`, roles are enabled in the config; one port 443 (TLS 1.3, `X25519MLKEM768` through rustls +
aws-lc-rs, as in D-5), different paths (`/mbx/v1/`, `/push/v1/`, `/relay`) and, optionally, different host names. The mailbox
protocol is HTTPS + CBOR, not iroh QUIC: HTTPS passes through corporate networks without UDP, is available to the iOS notification extension
(URLSession, strict memory and time limits), can be proxied, and in v0.3 goes through Tor without an experimental transport.

---

## 4. Offline mailbox

### 4.1. Who creates mailboxes and how many

- A mailbox is created by the **recipient** of a direction (R for messages S→R) on the server that **R** chose for this link
  (the node's default config, a per-link override: `antenna invite|join --mailbox <url|cloud|none>`, later
  `antenna mailbox servers set <contact> …`, an owner command).
- For each active link, R has one mailbox on each server in the list (1–3) for the **current epoch** + the mailboxes of the previous epoch
  during the grace period. 50 links → 50–150 mailboxes, each with its own random capabilities.
- There are no "per-device" or "per-person" mailboxes: such a mailbox would link all contacts (SPEC §5 "nothing shared between links").
- A computer with the mailbox enabled creates mailboxes too: this gives asynchronous delivery between laptops that are rarely online
  at the same time. Without a server (`--mailbox none`) everything works as now (outbox, SPEC §4 v1; SPEC §18 "without a server of one's own").
- Multi-device (v1.x) and MLS groups (v2) are outside this document: a mailbox per (link, device) or per group member is
  decided in their specifications; the capability format allows it (server index, epoch).

### 4.2. Capabilities and address derivation

Recipient R, for epoch `e` (`e = 0, 1, 2…`, separate for each direction of the link) and the server with index `i` (the position in the
announcement's list, 0…2):

| Value | Definition | Who has it |
| --- | --- | --- |
| `bs` | `rand(32)`: the epoch's mailbox seed | only R |
| `ws` | `HKDF(salt = "x/mbx/v1", ikm = bs, info = "x/mbx/v1/write-seed" ‖ link_id ‖ u32be(e), 32)` | R and S (S receives it in the announcement) |
| `rcap_i` | `HKDF(salt = "x/mbx/v1", ikm = bs, info = "x/mbx/v1/read-cap" ‖ link_id ‖ u32be(e) ‖ u8(i), 32)` | only R |
| `wcap_i` | `HKDF(salt = "x/mbx/v1", ikm = ws, info = "x/mbx/v1/write-cap" ‖ link_id ‖ u32be(e) ‖ u8(i), 32)` | R and S |
| `kbox` | `HKDF(salt = "x/mbx/v1", ikm = ws, info = "x/mbx/v1/payload-key" ‖ link_id ‖ u32be(e), 32)` | R and S |
| `rid_i` | `H("x/mbx/v1/read-id" ‖ rcap_i)` | server i (read index) |
| `wid_i` | `H("x/mbx/v1/write-id" ‖ wcap_i)` | server i (write index) |

The properties this is designed for:
- **The sides derive the same values synchronously and deterministically** (only HKDF-SHA256 and SHA-256 with domain separation):
  S receives `ws`, R keeps `bs` and restores everything from it (for future backups and multi-device).
- **The write right ≠ the read right.** `rcap` is derived only from `bs`, which S does not have: S cannot read or delete the mailbox.
- **The server stores only the hashes** `rid`, `wid`: a leak of its DB allows neither reading nor writing. The server sees raw `rcap`/`wcap`
  only in requests under TLS (this is unavoidable and harmless: the server stores the blobs anyway).
- **The indexes of different servers are independent** (`u8(i)` in `info`): two servers in one list cannot recognize each other by ID.
- **`link_id` and `e` in `info`** bind the capabilities to the link and the epoch: an announcement from one link cannot be substituted into another
  (it travels inside this link's E2E anyway; this is the second line of defense).

### 4.3. Epochs and rotation

**Why not a schedule from a static key.** The variant "both derive `addr_t = HKDF(k_link, t)` from time or from
the counter `n`" needs no exchange, but (1) gives no PCS: whoever once stole `k_link` knows all future addresses;
(2) the server would have to accept writes to a mailbox that has not been created yet, an open store for anyone who enumerates addresses;
(3) libsignal does not expose ratchet epochs (D-8), and an epoch of our own based on the counter `n` falls apart with TTL and direct
delivery. So **an epoch is the announcement of a fresh random `seed` inside Triple Ratchet**: the address of epoch `e+1` is known
only to whoever decrypted the ratchet message; a leaked epoch `e` does not reveal `e+1` after the ratchet recovers
(post-compromise security is inherited). In substance this is exactly "the address changes every ratchet epoch" of SPEC §4: a new
announcement goes out when R writes to S, that is, at a DH-ratchet step.

**When R starts a new epoch** (client policy; the numbers are defaults):
- the current epoch's mailbox is older than 7 days **and** R is sending S a message anyway: the announcement goes along with it (does not wake:
  `notify = false`);
- ≥ 1000 blobs have arrived in the mailbox;
- immediately: `antenna rotate`, rekey (PROTOCOL §17), a change in the server list, a suspected leak, an `unknown` error from
  one's own server (the mailbox is gone);
- no more than once an hour per link (protection against an announcement storm).

**Order.** R: create the mailboxes of epoch `e+1` (§4.6 `create`) → send the announcement (§4.4) → read **both** sets of mailboxes.
S: on receiving an announcement with an `epoch` greater than the current one, new writes go only to the new mailboxes; a lesser or equal one is ignored.
R deletes the mailboxes of epoch `e` (`delete`) when (a) there has already been a blob from S in the `e+1` mailboxes **and** the `e` mailboxes are empty, or
(b) `grace_until` has arrived (+30 days by default = the blob TTL). A write to a deleted mailbox → `unknown` → the blob stays in
S's outbox (as in SPEC §4 v1) until a direct connection; there, verification (§16) also resends the last announcement (it is a history message).

**Breaking off without revoking the link** ("block"): R announces an epoch with `seed = null` or simply deletes the mailboxes; S can no longer
write, and only the direct path remains. **Revocation** (`antenna revoke`): R deletes all of its mailboxes for the link before wiping the keys.

### 4.4. Mailbox announcement (a link message)

An announcement is an ordinary signed history envelope (PROTOCOL §12) of a new type `control`: it is delivered by the same paths
(directly, outbox, S's mailbox), is part of the DAG and verification (a lost announcement is resent with `resend`), and is not shown in the UI,
to agents, in `inbox` or `history`. There are no receipts for it.

```cddl
; extension of envelope-core (PROTOCOL §12):
;   the "type" field gets the value "control";
;   the "body" field gets the variant control-body; "type": "control" ⇔ body = control-body
control-body = { "mailbox": mbx-cap }

mbx-cap = {
  "v": 1,                                   ; announcement version
  "epoch": uint,                            ; 0, 1, 2… strictly increasing at R in this link (≤ 2^32 − 1)
  "seed": bstr .size 32 / null,             ; the epoch's ws (§4.2); null: R has no mailbox, write only directly
  "servers": [* mbx-server],                ; 0…3; order = preference, position = i in §4.2; empty ⇔ seed = null
  "grace_until": uint,                      ; Unix ms: until this moment R reads the mailboxes of epoch epoch − 1
}
mbx-server = {
  "url": tstr,                              ; "https://host[:port]/": the API base (≤ 256 bytes, https only)
  ? "pin": [1*2 bstr .size 32],             ; SHA-256 of the SubjectPublicKeyInfo, only for self-signed servers
}
```

Checks at S (if any fails: `rejected{"bad_request"}` on the direct path; from the mailbox: drop it and write to the log):
`v = 1`; `epoch` within bounds; `seed = null ⇔ servers = []`; 0…3 servers; the URL is `https`, ASCII, ≤ 256 bytes, without
userinfo/fragment; `pin` ≤ 2. Announcements from one contact: no more than 10 per day (beyond that they are dropped; this limit does not
consume the level's message limit).

**Feature negotiation** (nodes without this document would reject the `control` type as `bad_request`, and 5 rejections make
a message `failed`). A new link request:

```cddl
link-request  /= { "features": { "mbx": [* uint] } }    ; the mailbox versions the sender knows: [1]
link-response /= { "features": { "mbx": [* uint] } }    ; the answer: its own
```

An old node answers `rejected` (an unknown request, as for `stream_open` in §20) → "no mailbox", retried no more than once
a day. Announcements are sent only to a contact that confirmed `mbx: [1]`. Right after the link is activated (pairing does not change,
§9.1) both nodes exchange `features` and their first `epoch = 0` announcements over the still-open link connection.

### 4.5. Blob format in the mailbox

A `routing-blob` **must not** be put into the mailbox as is: the `link` field (= `link_id`) is the same in all epochs, and the
libsignal message (`SignalMessage`) carries the sender's DH-ratchet key and counters in the clear; the same ratchet key in the
mailboxes of `e` and `e+1` would link the epochs (S sends on the old chain until it gets R's answer). So:

```
ct      = routing-blob.ct                                  ; pad(e2e-frame), the length is a bucket of SPEC §7 (PROTOCOL §12)
salt    = rand(32)
k       = HKDF(salt = salt, ikm = kbox, info = "x/mbx/v1/blob-key", 32)
aad     = "x/mbx/v1/blob" ‖ link_id ‖ u32be(e)
blob    = u8(1) ‖ salt ‖ ChaCha20-Poly1305-Seal(k, nonce = 0¹², aad, ct)       ; 1 + 32 + len(ct) + 16 bytes
```

- A per-blob key from a random salt and a zero nonce: the same technique as for `xfile/0` files (D-F-2) and streams (§20):
  reuse of a (key, nonce) pair is ruled out without a counter at the sender. No custom cryptography (RFC 8439 + RFC 5869).
- The visible size is the padding bucket + 49 bytes: 305, 1073, 4145, 16433, then 16384·k + 49. The libsignal type, the message
  length and the ratchet header are inside.
- Recipient: length ≥ 49, first byte 1, open the AEAD with its mailbox's key; if it does not open, it was planted (the server does not know `kbox`)
  → `ack` and log `mbx_garbage`; the ratchet is not touched. If it opens, assemble `routing-blob{v: 1, link:
  the mailbox's link_id, ct}` and process it **exactly as `deliver`** (PROTOCOL §12: PreKey is rejected, ID, signature, limits,
  a transaction with the ratchet and the counter of §17).
- What does **not** go through the mailbox: `resend`, `sync`, `chain`, `conflict`, `want`, `rekey_*`, `stream_open`, file blobs:
  they are interactive or large and go only directly (asynchronous verification and attachments are stage M4, §11).

### 4.6. Mailbox server API (`/mbx/v1/`)

HTTPS (TLS 1.3, `X25519MLKEM768` preferred), HTTP/2 or HTTP/1.1, bodies are CBOR (`application/cbor`), strict parsing
(unknown fields and trailing bytes are `bad_request`, as in D-12/TROUBLESHOOTING "Formats, serde, CBOR"). Capabilities are passed **in the body**, not
in the URL and not in headers, which end up in proxy logs. All error responses are `{ "error": tstr }` with an HTTP code.

```cddl
; GET /mbx/v1/info
server-info = {
  "v": [+ uint],                       ; mailbox protocol versions: [1]
  "roles": [+ ("mailbox" / "push" / "relay" / "forward")],
  "limits": {
    "blob_max": uint,                  ; blob bytes, default 98304 (64 KiB text → bucket 81920 + 49)
    "box_blobs": uint,                 ; blobs per mailbox, default 1000
    "box_bytes": uint,                 ; bytes per mailbox, default 33554432 (32 MiB)
    "ttl_days": uint,                  ; blob lifetime, default 30
    "idle_days": uint,                 ; a mailbox without reads is deleted, default 60
    "wait_max": uint,                  ; long-poll seconds, ≤ 30
    "get_max": uint,                   ; blobs in a get response, ≤ 256
    "get_boxes": uint,                 ; mailboxes in one get, ≤ 64
  },
  "pow": { "bits": uint, "challenge": bstr .size 32, "valid_s": uint },   ; §5.2
  ? "relay": tstr,                     ; URL of this node's iroh-relay
  ? "policy": tstr,                    ; URL of the operator's privacy policy
}

; POST /mbx/v1/create — R creates a mailbox (PoW is mandatory; §5.2)
create-req  = { "req": bstr, "pow": pow }            ; req = CBOR(create-body); the transmitted bytes are hashed (as in D-19)
create-body = {
  "v": 1,
  "rid": bstr .size 32,                ; H("x/mbx/v1/read-id" ‖ rcap)
  "wid": bstr .size 32,                ; H("x/mbx/v1/write-id" ‖ wcap)
  ? "push": push-target,               ; only for a mobile recipient, §6
}
pow = { "challenge": bstr .size 32, "nonce": uint }
; response: { "created": { "ttl_days": uint, "idle_days": uint } }; rid or wid already exists → 409 "exists" (R takes a new bs)

; POST /mbx/v1/put — S writes
put-req = { "v": 1, "wcap": bstr .size 32, "blob": bstr, "notify": bool }
; response: { "stored": { "exp_day": uint } }          ; the Unix day after which the blob is deleted

; POST /mbx/v1/get — R reads (one or several of its mailboxes; long poll)
get-req = { "v": 1, "boxes": [1*64 { "rcap": bstr .size 32, ? "after": uint }], ? "max": uint, ? "wait": uint }
get-resp = { "boxes": [* { "i": uint,                      ; position in the request
                           "items": [* { "seq": uint, "blob": bstr }],   ; ascending seq, without ack
                           "more": bool } / { "i": uint, "gone": true } ] }
; wait > 0 and all mailboxes empty: the server holds the response until the first blob or for wait seconds

; POST /mbx/v1/ack — R deletes what it has read (only after committing locally, §4.8)
ack-req = { "v": 1, "rcap": bstr .size 32, "through": uint }       ; delete all blobs with seq ≤ through

; POST /mbx/v1/delete — R deletes the whole mailbox (with its blobs and push target)
delete-req = { "v": 1, "rcap": bstr .size 32 }

; POST /mbx/v1/push — R sets/removes the mailbox's push target (a device token change, opting out of push)
push-req = { "v": 1, "rcap": bstr .size 32, "target": push-target / null }
push-target = { "gateway": tstr, "handle": bstr .size (49..1024) }    ; gateway https URL; handle: §6.3
```

Errors: 400 `bad_request`; 404 `unknown`: no such mailbox **or** a wrong capability (not distinguished); 403
`pow_required` / `pow_invalid`; 409 `exists`; 413 `too_large`; 429 `rate_limited` (+ `Retry-After`); 507 `quota` (the mailbox
is full); 503 `busy` (the server is overloaded, storage is full). On any write error S keeps the blob in the outbox, so nothing is lost.

`seq` is the mailbox counter (increasing, not random); only R sees it. The server stores only `exp_day` (a day) for a blob, not
the exact arrival time; the server's time is not given to the recipient (the envelope has its own `ts`).

### 4.7. TTL, quotas, limits (server defaults; announced in `info`)

| What | Default | Why |
| --- | --- | --- |
| Blob lifetime | 30 days (`exp_day`); deleted even if unread | Offline for a long time: verification resends on reconnect; the mailbox is not an archive |
| A mailbox without reads | 60 days → deleted | Abandoned mailboxes (a deleted app) do not pile up |
| Mailbox | 1000 blobs **and** 32 MiB; full → `quota` | Limits the damage from one contact; **the same for all mailboxes**: the server never learns the trust level |
| Blob | ≤ 98,304 bytes | The largest text (64 KiB) with margin; files do not go through the mailbox |
| `create` | PoW (§5.2); ≤ 10/min and ≤ 200/day per IP prefix (/24 IPv4, /56 IPv6) | Mass creation costs work |
| `put` | ≤ 120/min per mailbox, ≤ 1200/min per IP prefix | Flooding by one contact; general flooding |
| `get` | ≤ 600/min per prefix; ≤ 64 concurrent long polls per IP | Polling does not eat the server |
| `wake` from a mailbox | ≤ 1 per 2 s per mailbox, extras are merged | A push storm from one contact |
| Server storage | the operator's threshold → `busy` | The server does not fall over; clients fall back to the outbox |

The recipient applies the level's limits **itself** (SPEC §9: 10/30/60/120 messages per minute): it takes no more than the limit from the mailbox
and does not acknowledge the rest (it stays in the mailbox until the next fetch). The server knows nothing about levels.

### 4.8. Fetching, acknowledgement, deletion, ordering

1. R calls `get` (on push, at startup/unlock, on a network change, every N minutes with jitter; an online daemon
   keeps a long poll with `wait = 25`).
2. Each blob: outer AEAD (§4.5) → `deliver` processing in **one transaction** with the ratchet and the counter of §17 (D-21).
3. **`ack` only after commit.** A crash between the commit and the `ack` → the blob arrives again → libsignal "old counter" / the same
   `id` → `duplicate` → `ack`. No duplicate messages, no losses.
4. Ordering is by `seq`; libsignal accepts out-of-order messages within its limits; the DAG and `lamport` order
   the history (SPEC §8: parallel branches are normal).
5. A permanent rejection (`bad_signature`, `history_conflict`, garbage): `ack` + local log; the sender learns about the
   divergence during verification (§16). A temporary one (`rekey_required`, `read_only`, `recovering`, the level's limit, keys
   locked): stop reading this mailbox and do not acknowledge.
6. After a rekey (§17), blobs encrypted with the state lost in the rollback will not decrypt → `ack` and discard:
   they will be returned by a `resend` after verification (PROTOCOL §17 item 6 already re-encrypts the queue).

### 4.9. Fault tolerance

- **Several servers** (up to 3 in an announcement). S writes to the first one that answers within 5 s; error/timeout → the next one. R reads
  all of them. "Mirror" mode (write to two) is R's choice for important links: duplicates are safe (item 3 of §4.8), at the cost of double the space and
  push.
- **The server is unreachable** → outbox (SPEC §4 v1). **The server lost data** → R does not get the blobs, S does not get
  confirmation → on a direct connection verification (§16) shows what is missing, and `resend` sends it; S, having had no confirmation by
  `exp_day`, moves the blob into the current mailbox once (a duplicate is safe).
- **Changing server / moving**: a new epoch with a list of new servers; the old mailboxes are read until the grace period ends.
- **A malicious server** (drops, delays, replays, plants): E2E protects content and authenticity;
  drops/delays are caught by verification; planted blobs do not open the outer AEAD; a replay is `duplicate`.

### 4.10. Forwarding through one's own server and the rule for levels 1–2

Whoever writes to a mailbox reveals their IP to the mailbox server. If the server is run by the **contact** (self-hosting), it learns the IP, the same
as "the contact's relay" (D-26, PROTOCOL §13 item 4). The rule mirrors that:

| My level for contact C | C's mailbox server | How I write |
| --- | --- | --- |
| 3–5 (direct mode, C sees the IP anyway) | any | directly |
| 1–2 (relay only) | in my `mailbox.trusted` list (my own servers + Antenna Cloud, unless the owner removed it) | directly |
| 1–2 | someone else's | only through my own `forward` (HTTP CONNECT over TLS to my own server, with TLS to C's server inside); if I have none → I do not use the mailbox, only the outbox |

`forward`: `CONNECT host:443` is allowed only to hosts whose `GET /mbx/v1/info` (cached for an hour) answers with the
`mailbox` role, only port 443, a limit per client IP, no record of "who goes where" (only counters). The forwarder sees the client's IP,
the destination server's name, the time and the volume; it does not see capabilities or blobs (TLS to the destination is end-to-end). If the forwarder and
the mailbox server are the same operator, forwarding does not protect against them (honestly, §8). The alternative, Oblivious HTTP (RFC 9458,
HPKE), is rejected for now: one more crypto library for the same property that an ordinary TLS tunnel gives.

**Connection isolation.** By default the client uses one HTTP/2 connection per server (the IP links it all anyway).
`mailbox.isolation = link` mode: a separate connection per link, **without TLS session resumption** (session tickets
would link the connections) and without HTTP/2 connection coalescing between groups; it makes sense together with Tor (v0.3), where each
group has its own circuit.

---

## 5. Sender anonymity and spam protection without accounts

### 5.1. Options and their cost

| Option | How it works | What it gives | Cost | Decision |
| --- | --- | --- | --- | --- |
| **A. A write capability from the recipient** (SimpleX: `SID` + a sender key; Signal: delivery token) | `ws` only inside the link's E2E; the server checks `wid = H(…wcap)` | Only the contact can write; the server does not know the sender; **spam from strangers is structurally impossible**: there are no public addresses | A leak of `ws` = the right to write until a new epoch/mailbox deletion (damage ≤ the mailbox quota) | **The foundation** |
| **B. Anonymous credentials** (Privacy Pass RFC 9576–9578; Signal's KVAC zkgroup) | An issuer hands out untraceable single-use tokens, the server redeems them | A quota "per subscription/device" without linking mailboxes | A scarce entry point for issuance is needed (payment or device attestation); there is no audited Rust implementation (§5.3); a new integration and audit | **Later**: the paid Cloud tier and creating mailboxes beyond the free quota |
| **C. Proof-of-work** | A hash puzzle on `create` and on push registration | A price tag on mass creation without identity | Weak against GPUs and botnets; phone battery | **Yes, on creation**, adaptively: ~0.1 s on a phone when idle, more expensive under load (the Tor 0.4.8 approach: "suggested-effort 0 … dormant until it notices signs of overload") |
| **D. Quotas and limits** | Per mailbox, per IP prefix, per server; TTL | Limits the damage | IP limits hit CGNAT | **Yes** |
| E. Accounts, phone, email | — | — | Contradicts SPEC §1, §5 | No |
| F. Device attestation (App Attest, Play Integrity) | Apple/Google confirm "a genuine app on a genuine device" | Cuts off bots | Apple/Google learn about the request; not available for Linux and Android without Google | Only as an entry point for B and only by maintainer decision |

**Choice: A + C + D now, B when an audited implementation appears or we commission an audit.** Why this is enough:
an Antenna user has no address anyone can write to until they themselves issue a capability inside E2E. What remains is
to protect **server resources** (mass creation of mailboxes), which is PoW and quotas; and to limit **a malicious contact**: the mailbox quota,
the level's limit at the recipient, ≤ 3 notifications from a contact per 10 minutes (D-30), rotating or deleting the mailbox (= blocking).

### 5.2. Proof-of-work on creation

```
challenge = HMAC(K_P, "x/mbx/v1/pow-challenge" ‖ u64be(⌊unix_s / 600⌋))      ; given out in info, stateless, 10 minutes
digest    = H("x/mbx/v1/pow" ‖ challenge ‖ H(req) ‖ u64be(nonce))             ; req is the transmitted bytes of create-body
accepted  ⇔ challenge is the current or the previous one  ∧  the number of leading zero bits of digest ≥ bits
            ∧ the pair (challenge, H(req)) has not been seen before (cached for the challenge's lifetime)
```

`bits` is 18 by default (≈ 2.6·10⁵ SHA-256: fractions of a second on a phone with the ARMv8 SHA extensions); under load the operator
raises it up to 24. The PoW is bound to the request body (it cannot be solved once for many mailboxes) and to a time window (it cannot be accumulated
in advance). A bug in the PoW is a DoS of the server, not a leak: it is a price tag, not data protection. The fallback against GPUs is Equi-X
(crate `equix` 0.8.0, Tor Project/Arti, LGPL-3.0-only, "Asymmetric function for client puzzle protocols"; in Tor it has
protected onion services since 0.4.8): HashX generates code internally, JIT is forbidden on iOS, so an interpreter is needed; adopt it only
if SHA-256 stops being enough of a deterrent.

### 5.3. Libraries (no custom cryptography)

| Purpose | Construction | Crate | License | Status (checked 2026-10-02) |
| --- | --- | --- | --- | --- |
| Deriving capabilities, IDs, PoW, codes | HKDF-SHA256, HMAC-SHA256, SHA-256 | `hkdf` 0.13, `hmac` 0.13, `sha2` 0.11 | MIT / Apache-2.0 | Already in the core (PROTOCOL §2) |
| The blob's outer layer, gateway handles | ChaCha20-Poly1305 (RFC 8439) | `chacha20poly1305` 0.11 | Apache-2.0 / MIT | README: "received one security audit by NCC Group, with no significant findings"; already in the core |
| TLS to the servers | TLS 1.3, `X25519MLKEM768` | `rustls` 0.23 + `aws-lc-rs` | Apache-2.0 / MIT / ISC | Already in the core (D-5) |
| Server certificates | ACME | `tokio-rustls-acme` (used by iroh-relay) or `rustls-acme` 0.15.4 | Apache-2.0 / MIT | Not data cryptography |
| Relay | iroh-relay 1.3.0, the `server` feature | `iroh-relay` | MIT / Apache-2.0 | Already a dev dependency (D-36) |
| UnifiedPush / Web Push | RFC 8291 (aes128gcm), mandatory in UnifiedPush ("It MUST be an encrypted content that follows RFC8291") | `ece` 2.4.2 (Mozilla) | MPL-2.0 | Not checked for an audit: the payload is a constant byte without a secret; this is a formality of the protocol |
| APNs | HTTP/2 + JWT ES256 (the publisher's authentication with Apple) | our own thin wrapper over `hyper` + signing with `aws-lc-rs` (the `a2` 0.10.0 crate has not been updated since 2024-05) | — | Does not protect user data |
| FCM HTTP v1 | Service account OAuth2 | `gcp_auth` 0.12.7 | MIT | Does not protect user data |
| Anonymous credentials (option B) | Privacy Pass RFC 9578 (VOPRF / Blind RSA) | `privacypass` 0.2 | MIT | README: "**This library has not been independently audited.** It should not be used in production without a professional security review" |
| | RSA Blind Signatures RFC 9474 | `blind-rsa-signatures` 0.15.2 (F. Denis, a co-author of the RFC) | MIT | No information about an audit was found |
| | VOPRF (RFC 9497) | `voprf` (Meta) | MIT / Apache-2.0 | Reviewed by NCC Group as part of the `opaque-ke` audit (2021), but it is a building block, not a token system |
| | KVAC (Chase–Perrin–Zaverucha, "The Signal Private Group System") | `zkgroup` / `zkcredential` from libsignal (our rev `e8cc2dd`); it includes `DonationPermit`: "a single-use, unlinkable bearer token used to rate-limit access to unauthenticated donation endpoints" | AGPL-3.0-only | In production at Signal, but no public independent audit was found; "use outside of Signal is unsupported" (like all of libsignal, D-4) |

**Conclusion on anonymous credentials: there is no audited Rust implementation.** The closest to ready is `zkgroup` (already in
our dependency tree, in production at Signal for the same "rate limiting without linking" tasks), but without a public audit and with
Signal's caveat. A candidate for `docs/WATCHLIST.md`: "an audit of Privacy Pass in Rust, or
a public audit of zkgroup".

---

## 6. Push without content

### 6.1. Who knows what

| Party | Knows | Does not know |
| --- | --- | --- |
| Mailbox server | That the mailbox has a push target (so the reader is a mobile device), the gateway URL, an opaque handle, **unique per mailbox**; when it woke it | The device token; that two mailboxes belong to one device (by handle) |
| Push gateway | The token (in transit, on every `wake`), how many times and when this device was woken, the IPs of the mailbox servers that wake it | Mailboxes, links, contacts, content; how many mailboxes the device has (except the number of handles requested) |
| Apple / Google | Device ↔ Apple ID / Google account; that Antenna is installed (bundle id / project); the time and number of wakes (after collapsing) | Senders, mailboxes, content: the payload is empty and constant |
| Contact | Nothing about the recipient's push | — |

### 6.2. Which schemes were rejected and why

| Scheme | Why not |
| --- | --- |
| The device token is stored by the mailbox server (as at Signal) | One global ID for all of the device's mailboxes: the server links all of the user's links and knows their identity at Apple/Google |
| The token is encrypted for the gateway and given to **contacts** as part of the delivery address; the sender wakes the device | The gateway sees the IP of **every** sender next to the recipient's token, which is an edge of the social graph; a former contact can wake the device until the handle expires (battery); waking is possible without writing to the mailbox. When the mailbox wakes the device, it does so only when data has arrived, within the quota |
| A SimpleX-style notification router (knows the token and the queue subscriptions) | It knows the number of queues and notifications for each (their own threat analysis); our gateway does not know about mailboxes at all and does not store tokens |
| Silent (background) push on iOS | Apple: "doesn't guarantee their delivery … don't try to send more than two or three per hour"; they are not delivered after the app is force-quit |

### 6.3. The chosen scheme: sealed gateway handles

```
webpush-keys = { "p256dh": bstr .size 65, "auth": bstr .size 16 }  ; the app's Web Push keys (RFC 8291), only "up"
target = CBOR({ "p": "apns" / "fcm" / "up",
                "t": tstr,                          ; APNs/FCM token or UnifiedPush endpoint URL (≤ 512 bytes)
                ? "k": webpush-keys,
                "app": tstr,                        ; bundle id / package
                "exp": uint })                      ; Unix day: the handle is invalid after it
salt   = rand(32)
k      = HKDF(salt = salt, ikm = K_G[kid], info = "x/push/v1/handle-key", 32)
handle = u8(kid) ‖ salt ‖ ChaCha20-Poly1305-Seal(k, 0¹², aad = "x/push/v1/handle" ‖ u8(kid), target)
```

- The gateway seals **for itself** (like stateless TLS tickets): there is no token database; capturing the gateway without the key gives nothing,
  and with the key, only the tokens of the handles stored on the mailbox servers.
- Each handle has a fresh salt: handles of different mailboxes of one device look independent to the mailbox server.
- `K_G` changes every 30 days (`kid`); the old one is kept until the `exp` of the handles it issued (≤ 90 days). The device refreshes
  handles together with the mailbox epochs and when its token changes (`/mbx/v1/push`).

**Gateway API (`/push/v1/`, CBOR):**

```cddl
; POST /push/v1/verify — the gateway sends a verification push with a code to the token (protection against registering someone else's token)
verify-req = { "req": bstr, "pow": pow }        ; req = CBOR({ "v": 1, "p": tstr, "t": tstr, ? "k": webpush-keys, "app": tstr })
; code: code = HMAC(K_V, "x/push/v1/verify" ‖ lp(p) ‖ lp(t) ‖ u32be(Unix day))[0..16], valid for this day and the next;
; it travels in the push itself: APNs, the key "c" next to "aps" (base64url); FCM, data "c"; UnifiedPush, the 16 code bytes as
; the message plaintext (RFC 8291 encryption on top, as for any UnifiedPush message)

; POST /push/v1/handles — issues a batch of handles for the code
handles-req  = { "v": 1, "p": tstr, "t": tstr, ? "k": webpush-keys, "app": tstr, "code": bstr .size 16, "count": uint }  ; count ≤ 64
handles-resp = { "handles": [* bstr], "exp": uint }

; POST /push/v1/wake — called by the mailbox server
wake-req  = { "v": 1, "handle": bstr }
; response: "ok" / { "error": "gone" } (the token was revoked: APNs 410 and so on; the mailbox server removes the push target) / "rate_limited"
```

Registration on the device: `verify` → a push with the code (on iOS, a visible "Antenna notifications are on" unless the
filtering entitlement is available, §6.5) → `handles` → a handle in `create`/`push` of each mailbox. The gateway counts wakes by
`H(t)` **in memory** (limits) and writes no logs with tokens or handles.

### 6.4. Waking: frequency, collapsing, silent messages

- **The `notify` flag is set by the sender** in `put`: `true` for what a person will see (`text`, `file`, `request`);
  `false` for receipts, mailbox announcements, service messages. The server sees 1 bit "wake" (like the `T/F` flag of SimpleX `SEND`); without
  it, every service message would draw a notification on iOS (without the filtering entitlement), and on Android FCM deprioritizes
  high-priority messages that do not lead to a visible notification ("FCM uses 7 days of
  message behavior when determining whether to deprioritize or proxy messages", Firebase).
- Collapsing: the mailbox server sends no more than 1 `wake` per 2 s per mailbox; the gateway sends no more than 1 push per 2 s per device and ≤ 2000 per
  day; extras are collapsed (`apns-collapse-id: m`, FCM `collapse_key: m`, Web Push `Topic: m`).
- The payload is constant and empty in meaning:
  - APNs: `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration: +1 day`, `apns-collapse-id: m`, body
    `{"aps":{"alert":{"loc-key":"NEW_MESSAGE"},"mutable-content":1}}` (≤ 4096 bytes, the APNs limit);
  - FCM HTTP v1: `data: {"m": "1"}`, `android.priority: HIGH`, `collapse_key: "m"`, `ttl: 86400s`;
  - UnifiedPush: POST to the endpoint, `TTL: 86400`, `Urgency: high`, `Topic: m`, the body is RFC 8291 over one byte `0x01`
    (UnifiedPush requires 1…4096 bytes and RFC 8291 encryption).
- On waking, the recipient makes one `get` with all of its mailboxes on this server (`wait = 0`): the push does not say which
  mailbox; otherwise Apple/Google would see a permanent mailbox label, that is, the rhythm of conversation with a particular contact.

### 6.5. Platforms

- **iOS.** APNs only. A visible push with `mutable-content: 1` starts the Notification Service Extension: "That method has a
  limited amount of time … If you don't update the notification content before time expires, the system displays the
  original content"; that is why the original text is always neutral ("New message"). Stage M3a: the extension does a `get`
  and puts the blobs (already under the outer AEAD) into the shared App Group directory, and **after fsync** sends `ack` (the on-disk spool is
  the commit of receipt; the ratchet is not touched; a lost spool, for example when the app is deleted, is recovered by verification, §16);
  the app processes the spool when opened; the notification is generic. Stage M3b: decryption in the extension by the Rust core (through a C ABI)
  needs a DB key available to the extension after the device's first unlock (a mobile client decision), and previews
  only for levels 3+ (SPEC §13). Apply for `com.apple.developer.usernotifications.filtering` ("allows a
  notification service extension to receive remote notifications without displaying the notification to the user"):
  with it, the verification push and wakes without new messages can be suppressed.
- **Android with Google.** FCM, a high-priority data message → `onMessageReceived` ("several seconds") → an expedited
  WorkManager job: `get`, processing by the core, notification.
- **Android without Google.** UnifiedPush: the user chooses the distributor (ntfy and others); "The distributor MUST be able to
  handle many registrations with a single application", so a separate endpoint can be kept per group of mailboxes. Anyone can run the
  `push` gateway for UnifiedPush (no Apple/Google keys are needed), including on their own mailbox server.
- **Without push** (by the owner's choice or if push is unavailable): iOS, background fetch at the system's discretion; Android, a
  periodic job (≥ 15 min); an honest delay, but neither Apple/Google nor the gateway knows anything.
- **Computers.** Push is not needed: an online `antennad` keeps a long poll (`wait = 25`) of its mailboxes on each server;
  after sleep, a network change and `unlock`, an immediate `get`. A locked node (`antenna lock`, or after a reboot until `unlock`,
  Q-4) does not read: the read capabilities are in the encrypted DB.

---

## 7. Our own relay

- **Role.** iroh-relay 1.3 (the `server` feature): relaying QUIC packets between pairwise endpoints when the direct path did not
  get through, and help with hole punching (QUIC address: `enable_quic_addr_discovery`). It keeps no state (SPEC §4).
  The public n0 relays are for development (since June 2026 managed n0 relays require an API token); for the public
  launch (SPEC §19), our own.
- **Placement.** The same `antenna-server`, its own path and host name (`relay.<region>.…`), so that it can be split out as it grows; the regions are
  the same as for the mailboxes (EU, US, Asia: a maintainer decision). The node's default relay map switches from n0 to ours.
- **Access.** iroh-relay's built-in options: `everyone`, `allowlist`/`denylist` by EndpointId, an HTTP callback, `shared_token`
  (client: `RelayConfig::with_auth_token`). For the public Cloud: `everyone` + a per-client rate limit
  (`limits.client.rx.bytes_per_second`). A per-user token **must not** be issued: all of a device's pairwise endpoints
  would present the same token, a shared identifier of the links (SPEC §5). A token for the whole app or for a company is fine.
  Paid priority only with anonymous tokens (§5.1 B) through our own `AccessControl`.
- **What it sees.** IP ↔ EndpointId (all of a device's pairwise endpoints from one IP can be linked; SPEC §4 acknowledges this), which
  pairs of EndpointIds exchange packets, volume and time; it does not see content (QUIC/TLS) or names. An operator running both the relay and the mailbox
  can match IPs across both logs; honestly stated (§8).
- **Sleeping endpoints (Q-1, option B) become possible.** Today each link keeps its own relay connection with a ping
  every 15 s (Q-1). At scale this is the main cost: 100 thousand users × 50 links × 30 % online = 1.5 million
  connections. With a mailbox, the endpoint of a link with no traffic need not hold the relay: incoming messages go to the mailbox, and the
  endpoint comes up when there is something to send or verify. For levels 1–2 this is also privacy (§9.5). The decision is a
  maintainer decision, after measurement (§11, Q-M8).

---

## 8. Server threat model

### 8.1. Threat → protection

| Threat | Protection | What remains |
| --- | --- | --- |
| The server operator reads messages | Triple Ratchet (PQXDH + SPQR) + the mailbox's outer AEAD; the server has no keys | — |
| The server links one link's mailboxes across epochs | A fresh random epoch `seed` inside the ratchet; no `link_id` in the blob; the libsignal header under the outer AEAD; identical quotas | Correlation by IP, time, connection: R reads the old and the new mailbox from one IP → forwarding, connection isolation, Tor v0.3 |
| The server links one user's links | No shared IDs, keys, tokens; the push handle is unique per mailbox | The same: IP and time. Cannot be eliminated against the operator without Tor |
| The server learns the sender | No accounts; a write is authorized by the mailbox capability, not by identity | The sender's IP → forwarding (mandatory for 1–2 to other people's servers), Tor |
| The server learns the trust level | Quotas are identical; level limits are applied at the recipient | Indirectly: "incoming only through the mailbox" and the fetch rhythm for links at 1–2 |
| Spam from strangers | There are no public addresses; the write capability exists only inside E2E | — |
| Flooding by a contact (including a compromised one) | The mailbox quota; the level limit at the recipient; ≤ 3 notifications per 10 min (D-30); push collapsing; rotating/deleting the mailbox | The contact uses up the quota of its mailbox and wakes the device no more than once every 2 s |
| Mass creation of mailboxes (storage DoS) | Adaptive PoW, limits per IP prefix, GC of abandoned mailboxes, storage threshold → `busy` | A botnet with GPUs → Equi-X, anonymous tokens (later) |
| The server loses, delays, drops | Outbox until confirmed by verification; `resend`; several servers | A delay until the direct connection |
| The server plants or replays blobs | A planted blob does not open the outer AEAD; a replay is `duplicate` (libsignal + `id`) | — |
| A leak of `ws` (a copy of the sender's DB without its ratchet) | Write ≠ read: without `rcap` one can neither read nor delete; a blob without a libsignal session is rejected (`deliver`); a new epoch inside the ratchet (PCS) and revocation cut off access | Until a new epoch: writing garbage within the mailbox quota (a DoS of one link) |
| Full compromise of the sender's device | Outside the server: this is a compromise of the link (SPEC §15), healed by the ratchet's PCS, rotation, `revoke` | Until healed, the attacker writes in S's name, just as without a mailbox |
| The contact's self-hosted server learns my IP | The rule of §4.10 (levels 1–2: only through one's own `forward` or a trusted server) | Levels 3+: the IP is visible in direct mode anyway |
| Compelled disclosure by the operator (a court) | We store: capability hashes, ciphertext until fetched/TTL, sealed handles, `exp_day`; deletion after `ack`; no IP logs (maintainer decision, Q-M5) | IP and time if logs are kept after all; data at that moment |
| The push gateway builds a graph | The gateway sees handles from mailbox servers, not mailboxes; no token database | The time and number of the device's wakes; colluding with a mailbox server, correlation by time |
| Apple/Google | An empty constant payload, collapsing | The fact that Antenna is on the device, the time and number of wakes; UnifiedPush or "no push" |
| Registering someone else's token (to wake the victim) | A verification push with a code; PoW on `verify` | — |
| Server impersonation (TLS MITM) | WebPKI, TLS 1.3 + `X25519MLKEM768`, `pin` for self-signed servers | A compromised CA learns capabilities → can write garbage and see metadata, not content |
| "Harvest now, decrypt later" of metadata | A PQ group in TLS to the servers; content: SPQR | — |
| Prompt injection through push / wake | Push contains no text; wake is a fixed template (SPEC §11) | — |
| Mailbox protocol downgrade | Versions in `info`, `v` in every request and announcement; no legacy modes | — |

### 8.2. The honest list: what each party sees

| Who | Sees | How we mitigate |
| --- | --- | --- |
| Mailbox server | IP and time of writes and reads; size (bucket + 49); how many mailboxes in one request/connection/from one IP; the `notify` flag; whether there is a push target; mailbox lifetimes; the recipient's online rhythm (polls) | SPEC §7 padding; the outer AEAD; rotation; forwarding; connection isolation; `exp_day` instead of time; deletion after `ack`; TTL; no logs; Tor (v0.3) |
| Forwarder (`forward`) | The client's IP, the destination server's name, time, volume | One's own server; different operators; Tor |
| Push gateway | Device tokens and wake rhythm; the IPs of mailbox servers | No token database; collapsing; "no push" |
| Apple / Google | The fact that the app is on the device; the time and number of wakes | An empty payload; UnifiedPush; "no push" |
| Relay | IP ↔ EndpointId; endpoint pairs, volume, time | Sleeping endpoints; different relays; Tor |
| Network provider | Which servers the device talks to (the name in SNI; no ECH), time, volume | Tor (v0.3) |

**What we do not do, and why we say so honestly:** against an operator who sees writes, reads and push, the timing
correlation "S wrote → R was woken → R read" cannot be eliminated without mixers and delays. Artificial delays
hurt the main measure, the user's convenience (§11, goals); so by default there are none, and the protection is different operators,
forwarding and Tor (SPEC §15: "a global observer is outside the v1 model").

---

## 9. Impact on the existing protocol

### 9.1. Pairing does not change

Mailbox addresses, write capabilities and push are **not** part of the transcript (`TH`) or of messages M1–M8:
1. `TH` fixes identities and keys, not routes (like `addrs`, PROTOCOL §7); mailboxes rotate, so an in-link
   mechanism is needed anyway.
2. Inside Triple Ratchet secrecy is stronger than in M1/M2: those are under TLS, while the E2E key holds even with broken TLS
   (ML-KEM in PQXDH, PROTOCOL §15 G4); authenticity comes from the identities pinned in `TH` (C8).
3. The formal model of pairing (`formal/`) is not re-run; the ProVerif work goes into separate mailbox models (§11).

Risk window: the link is active, but the announcements have not arrived yet (the app went to the background within ~1 s). The cost: the first messages wait in
the outbox until the next connection. If measurements on phones show losses, the fallback is an announcement inside M7/M8
(`L_INIT ‖ TH ‖ CBOR(mbx-cap)`), which is pairing v2 with a model run.

### 9.2. Delivery: path choice and statuses

```
path(m → C):
  1. there is a live link connection, or presence(C) = online  → deliver directly (D-21); no ok within T_direct = 3 s → step 2
  2. C has a write capability (mbx: [1], announcement)          → put into C's mailbox per the rule of §4.10; stored → status in_mailbox
  3. otherwise / the server refused                             → outbox as now (backoff, SPEC §4 v1)
  on any new connection with C: verification (§16); an in_mailbox blob that C does not have is delivered directly (a duplicate is safe)
```

Message statuses for the window and the CLI: `queued` → `in_mailbox` ("on the server", one check mark) → `delivered` → (`read`, levels
3+). `delivered` is set on a direct `ok`, from the verification summary (the contact's `count` ≥ `n`) or from the `parents` of the contact's next
message; there are no separate delivery receipts through the mailbox: they would reveal to a contact at levels 1–2 when the recipient
was online (SPEC §4).

### 9.3. History, verification, rollback

- The mailbox is one more `deliver` path; the checks and the transaction are the same (§12, D-21). Verification (§16) and resend happen only directly;
  they also cover everything the server lost or TTL deleted.
- The new envelope type `control` (the mailbox announcement) counts toward the counter `n`, the chains and the DAG; there is no one to show it to.
- Rollback (§17): a link in `rolled_back` does not read the mailbox; after a rekey, old blobs that cannot be decrypted are `ack`ed and discarded,
  and the resend returns them.
- Asynchronous verification through the mailbox (a summary inside the ratchet for "phone–phone" pairs that never meet directly) is
  stage M4.

### 9.4. Files, streams, receipts

- A file offer (`file`, §19) is an ordinary envelope and also goes through the mailbox; the content still comes from the sender's endpoint
  (served for 14 days). Offline attachments on the server (`xfile/0` ciphertext with a separate capability, TTL) are stage M4.
- Streams (§20) do not go through the mailbox: a stream = presence (3+ only, both online); the final message goes into the mailbox.
- Receipts (§18, Q-22) are ordinary envelopes, `notify = false`.

### 9.5. Presence (Q-8, D-33) and level permissions

- **The D-33 limitation is closed.** Today a contact at level 1–2 learns that the node is online by trying to deliver (the connection
  is accepted). With a mailbox: if **my** level for the contact is ≤ 2 and I have a mailbox, this link's endpoint **sleeps** (does not hold the
  relay, no incoming connections) and wakes only on my initiative (sending, verification, downloading a file after approval). Everything
  incoming from such a contact goes through the mailbox; the time of my fetches is not visible to them. The exception is serving my file to this
  contact (§19: until the receipt or 14 days): while that is going on, the endpoint accepts their connections (only the blob ALPN), and
  presence is visible during that time; this is a consequence of my own action "send a file".
- Levels 3–5: presence as now (online → directly, otherwise the mailbox).
- The server does not know levels (identical quotas); the recipient applies level limits when fetching (§4.7).
- Agents: incoming messages from the mailbox are ordinary incoming messages (labeling, taint, wake per SPEC §11 unchanged). Mailbox settings are
  **owner commands** (`antenna mailbox servers set`, `disable`, `rotate`, the `--mailbox` flags of `invite/join`): they
  decide where metadata leaks to, so they are absent from MCP and from the CLI with an agent token (SPEC §9). The agent can only
  read the status.

### 9.6. Control protocol and versions

- x-control (the next version after the current one): the `in_mailbox` status; `mailbox: {servers, epoch, state}` in contacts
  (without capabilities); `mailbox` events (server unreachable, quota, `gone`); the owner commands above; `antenna doctor`
  checks the servers (`info`, TLS, PoW, latency).

| What | Version | How it is negotiated |
| --- | --- | --- |
| Mailbox protocol | `mbx/1`, paths `/mbx/v1/`, the `v` field in requests | `GET info` → `v: [1]`; an incompatible change gets a new path; the server keeps N and N−1 for half a year |
| Announcement | `mbx-cap.v = 1` | Inside E2E; an unknown version is dropped |
| Link feature | the request `features {mbx: [1]}` | An old node answers `rejected` → no mailbox |
| Envelope type `control` | an extension of link format v1 (like `file`/`request` in §19) | Sent only after `features` |
| Push gateway | `push/1`, paths `/push/v1/` | `GET /push/v1/info` |
| Labels | `x/mbx/v1/…`, `x/push/v1/…` | The `x/` family (D-57) |

---

## 10. Self-hosting and "Antenna Cloud"

### 10.1. One binary

- `antenna-server` (crate `crates/antenna-server`; license: Q-M10): the roles `mailbox`, `push`, `relay`, `forward`
  are enabled in `server.toml`; data is SQLite in one directory; TLS via ACME (Let's Encrypt) or one's own certificates;
  Prometheus metrics **without** identifiers (counters, latency histograms).
- A container image (a statically built binary) and a systemd unit; `antenna-server doctor` (ports, certificate, PoW, disk).
- The minimum for 1 thousand users is 1 vCPU / 1–2 GB / 20 GB of disk.
- **Self-hosting limitation:** push for the official iOS/Android apps goes through the publisher's gateway (the APNs key and the
  Firebase project belong to the publisher); a self-hosted mailbox server calls our gateway with a handle and gives it nothing
  but the handle. A gateway of one's own is possible for UnifiedPush or for one's own build of the app.

### 10.2. Free and paid

| | Free | Paid (later) |
| --- | --- | --- |
| Self-hosting | The whole server, all roles, no restrictions | Support and SLA |
| Antenna Cloud, people | Mailboxes with the quotas of §4.7, push on all platforms, a shared relay with a rate limit | A larger quota and lifetime, offline attachments, relay priority, **only with anonymous tokens** (§5.1 B); otherwise a subscription would link the mailboxes |
| Companies | — | A dedicated managed server in the chosen region (own domain, SLA 99.9 %, `shared_token` on the relay, an operator console), or self-hosting + support. The company itself is the operator of its employees' metadata, like a mail server |

Price reference points: n0: Pro $19/month, a dedicated relay from $199/month per region.

### 10.3. Infrastructure cost (order of magnitude)

Assumptions (to be checked by measurement at stage M1): daily active, 60 % of users; incoming messages per active user, 60 per day
(of which ~30 % are service messages); through the mailbox, 50 % (a mix with phones); average blob 1.3 KiB; mobile, 70 %; push after
collapsing, 20 per day; online at the same time, 30 %; relay connections per online user, 5 with sleeping endpoints and
50 without; relay memory per connection, 30–60 KiB (**an assumption**); a relay ping every 15 s ≈ 150 bytes; P2P traffic,
20 MB per active user per day (files), of which 10 % through the relay (SPEC §4).

| | 1 thousand users | 100 thousand users |
| --- | --- | --- |
| Mailbox writes | ~18 thousand/day (0.2/s) | ~1.8 million/day (~21/s, peak ~200/s) |
| Mailbox traffic | ~23 MB/day in each direction | ~2.3 GB/day in each direction (~70 GB/month) |
| Storage (worst case: 10 % offline for the whole TTL) | ~120 MB | ~12 GB |
| Push | ~8 thousand/day | ~0.84 million/day (~10/s); APNs and FCM are free |
| Relay connections | ~1.5 thousand | **150 thousand with sleeping endpoints** (RAM 4.5–9 GB, pings ~4 TB/month); **1.5 million without** (RAM 45–90 GB, pings ~39 TB/month) |
| Traffic through the relay | ~36 GB/month | ~3.6 TB/month |
| Hardware | 1 small VPS (1–2 vCPU, 2 GB): all roles | Per region: 2 × (8 vCPU, 32 GB) relay+mailbox (fault tolerance) + 2 small gateways; 1–3 regions |
| Money (budget hosting in the EU; prices not verified: the pricing pages are rendered by a script) | ≈ €5–10/month + Apple Developer $99/year | ≈ €250–600/month for 1–3 regions (≈ $0.003–0.006 per user); on AWS/GCP 3–5 times more expensive + egress ~$0.05–0.09/GB |

Conclusion: money for hardware is not the bottleneck; the bottlenecks are **the number of relay connections due to pairwise endpoints** (solved by
sleeping endpoints, §7) and people: on-call duty, support requests, abuse, legal requests.

---

## 11. Implementation and verification plan

**Goals for the user (the measure is convenience, not "like everyone else"; measured at every stage):**
- computer → a phone in a pocket (the app is closed): a notification on screen, p50 ≤ 3 s, p95 ≤ 10 s (depends on
  APNs/FCM; measure on real devices);
- the recipient is an online computer and the direct path did not get through: a message from the mailbox, p50 ≤ 300 ms from `put`;
- the server DB is wiped in the middle of a conversation: after the nodes meet, all messages are in place, without duplicates;
- a level 1 contact cannot tell "the recipient is online" from "offline" (identical responses and timings on its side).

| Stage | What | Checks |
| --- | --- | --- |
| **M0 · specification** (now) | This document; maintainer decisions (§12); an independent review of the specification | ProVerif before code: `formal/mailbox_caps.pv`: secrecy of `rcap` (from S and the server), `wcap`/`kbox` (from the server and the network), the correspondence "a write under `wcap_e` ⇒ R issued epoch `e` to this S"; `formal/mailbox_unlink.pv`: observational equivalence (`choice`): "two mailboxes of one link" ≡ "mailboxes of different links" for the server (without IP and time) and "handles of one device" ≡ "of different devices"; **negative controls**: a blob with `link_id` (`NEG_LINKID`), without the outer AEAD with a cleartext ratchet key (`NEG_NOOUTER`), a deterministic handle (`NEG_DETHANDLE`): the model must tell them apart |
| **M1 · server** | `antenna-server`: the roles `mailbox` + `relay` (+ `forward`), SQLite, the API of §4.6, the PoW of §5.2, the quotas and GC of §4.7, metrics, image, systemd | Unit tests + fuzzing (`cargo-fuzz`) of CBOR parsing and PoW; API integration tests; a load run on a VPS to confirm the table in §10.3; a DB dump: no `link_id`, no cleartext capabilities, no tokens |
| **M2 · client in the daemon** | A `mailbox` module in `antenna-core`: `features`, `control` announcements, epochs, the path of §9.2, long polling, `ack` after commit, the rule of §4.10, sleeping endpoints for levels ≤ 2, revocation; x-control, the CLI `antenna mailbox …` | Two `antennad` + a local `antenna-server` (like the local relay, D-36): offline delivery in both directions; wiping the server → recovery through verification; rotation (the old mailbox is deleted, the new one works); level 1 through the mailbox and a presence probe; level limits when fetching; a delivery model in `stateright` 0.31 (MIT): "no duplicates in the history", "`ack` only after commit", "no message is ever forgotten" under crashes, server loss and TTL; liveness under fair fetching or a meeting |
| **M3 · push and mobile** | The `push` role (APNs, FCM, UnifiedPush), the handles of §6.3; the mobile client: a spool in the NSE (M3a), decryption in the NSE (M3b), FCM/UnifiedPush, a no-push mode. **Account steps:** Apple Developer Program, a Firebase project, the application for the filtering entitlement | Real devices: the latencies of §11; no token logs (a configuration check); negative tests: someone else's token without a code, an expired handle, `gone` |
| **M4 · Cloud and extensions** | Regions, monitoring, abuse handling, a status page, a privacy policy; switching the relay away from n0; then: anonymous tokens (the paid tier), offline attachments, asynchronous verification through the mailbox, Tor (v0.3), multi-device mailboxes (v1.x) | ProVerif for attachments and tokens; an audit before v1.0 (SPEC §17) together with the rest of the protocol |

**Not** formally verified (and this is stated in the reports): timing and IP correlation, which is statistics rather than a symbolic model;
the behavior of Apple/Google, which is outside the model.

---

## 12. Open questions for the maintainer

| # | Question | Options (the recommended one first) |
| --- | --- | --- |
| Q-M1 | Mailbox by default | a) on, the server is Antenna Cloud (like the n0 relay now), "no server" via a toggle; b) on only on phones; c) off, the owner turns it on |
| Q-M2 | Cloud jurisdiction and hosting | a) EU (Germany/Finland, budget hosting; GDPR: an IP is personal data, a policy and a DPA are needed); b) Switzerland; c) US (CLOUD Act); avoid countries with mandatory interception/retention for messengers. Check with a lawyer (including the status of the EU regulation on scanning private messages, not confirmed) |
| Q-M3 | Blob retention period | a) 30 days (as APNs keeps a notification ≤ 30 days); b) 14 days (as Session); c) 7 days |
| Q-M4 | Who signs the apps and runs the push gateway | a) a company (Apple Developer and Firebase require a real name or a legal entity); b) an individual developer account; without this there will be no push on iOS |
| Q-M5 | Cloud logs | a) no IPs and no capabilities, counters in memory, errors without identifiers; b) IPs for 24 h for abuse investigation; c) according to the jurisdiction's requirements |
| Q-M6 | Anonymous tokens for the paid tier | a) wait for an audited Privacy Pass implementation; no paid tier for people until then; b) `zkgroup` from libsignal + commission an audit of the integration; c) a paid subscription without anonymity (links the mailboxes; not recommended) |
| Q-M7 | Device attestation (App Attest / Play Integrity) as the entry point for generous quotas | a) no; b) only as the entry point for tokens (Apple/Google learn about the request) |
| Q-M8 | Sleeping endpoints (Q-1, option B) | a) yes: for links ≤ 2 right away (this is also privacy), for 3+ after measurement; b) only ≤ 2; c) no |
| Q-M9 | Incoming messages from levels 1–2 only through the mailbox (closes the D-33 limitation at the cost of a delay of seconds) | a) yes, when there is a mailbox; b) by choice per link |
| Q-M10 | Server license | a) AGPL-3.0-only, like the daemon, Signal-Server and SimpleX (modified hosting must publish the code); b) Apache-2.0 (broader for hosters); c) AGPL + commercial (needs a CLA; the server does not depend on libsignal, so this is possible, unlike the core) |
| Q-M11 | Push on iOS without the filtering entitlement | a) apply right away; until approval, the sender's `notify` flag; b) only the flag |
| Q-M12 | Regions at launch | a) one (EU) + a second on demand; b) three at once |
| Q-M13 | Order of work | a) M1–M2 right after the desktop beta (asynchronous delivery between laptops), M3 together with the mobile client (as already decided); b) everything together with mobile |

---

## 13. Places where primitives are combined (formal model input)

| # | Where | What is combined | Why |
| --- | --- | --- | --- |
| MB1 | Capabilities (§4.2) | HKDF-SHA256 of `bs`/`ws` with labels, `link_id`, the epoch and the server index | The same deterministic derivation on both sides; write ≠ read; independence of servers and epochs |
| MB2 | IDs on the server | SHA-256 with a label over the capability | The server stores only hashes; a DB leak gives no access |
| MB3 | Announcement (§4.4) | Capabilities inside Triple Ratchet, the envelope signed by the Ed25519 link-root (C12) | Secrecy and authenticity from the ratchet bound to `TH` (C8); PCS for addresses |
| MB4 | The blob's outer layer (§4.5) | HKDF(salt, `kbox`) → ChaCha20-Poly1305, nonce 0, AAD with `link_id` and the epoch | Hide the libsignal header and `link_id` from the server; drop planted blobs without touching the ratchet |
| MB5 | Gateway handle (§6.3) | HKDF(salt, `K_G`) → ChaCha20-Poly1305 over the push target | A stateless gateway; handles of different mailboxes are unlinkable |
| MB6 | Token verification code | HMAC-SHA256(`K_V`) over the platform, the token and the day | A handle cannot be obtained for someone else's token |
| MB7 | PoW (§5.2) | SHA-256 over the time-based HMAC challenge and the hash of the transmitted request | A price tag on creation; binding to the request and the window |

---

## 14. Sources (opened 2026-10-02)

- Signal, "Technology preview: Sealed sender for Signal": https://signal.org/blog/sealed-sender/
- SimpleX, `simplexmq/protocol/simplex-messaging.md` and `push-notifications.md` (via the GitHub API, the `stable` branch):
  https://github.com/simplex-chat/simplexmq/tree/stable/protocol
- Apple: UNNotificationServiceExtension; the entitlement `com.apple.developer.usernotifications.filtering`; "Pushing
  background updates to your App"; "Sending notification requests to APNs": https://developer.apple.com/documentation/usernotifications
  (the texts were taken from the JSON versions of the pages `developer.apple.com/tutorials/data/documentation/…`)
- Firebase, "Android message priority": https://firebase.google.com/docs/cloud-messaging/android/message-priority
- UnifiedPush: https://unifiedpush.org/developers/spec/definitions/ , https://unifiedpush.org/developers/spec/android/
- Privacy Pass in Rust: https://github.com/raphaelrobert/privacypass ; RSA blind signatures:
  https://github.com/jedisct1/rust-blind-rsa-signatures ; the `opaque-ke` audit (NCC Group, 2021): from search results
  (the report https://www.nccgroup.com/media/0uspzge5/_ncc_group_whatsappllc_opaque_report_2021-12-10_v13.pdf was not opened)
- A review of Signal's cryptography, part 3 (on zkcredential): https://soatok.blog/signal-crypto-review-2025-part-3/
- libsignal `rust/zkgroup` (`api/donations/donation_permit.rs`, `api/backups/auth_credential.rs`): a local copy
  of the pinned rev `e8cc2dd` (D-4)
- Tor, Proof of Work for onion services: https://onionservices.torproject.org/technology/security/pow/ ; the crates
  `equix`, `hashx`, `stateright`, `ece`, `a2`, `rustls-acme`, `gcp_auth`, `web-push`: the crates.io API
- Oxen, Session message routing: https://docs.oxen.io/oxen-docs/products-built-on-oxen/session/message-routing
  (an old page: it mentions PoW on every message)
- iroh-relay 1.3.0 (`src/main.rs`: `AccessConfig`, limits) and iroh 1.3.0 (`RelayConfig::with_auth_token`): the local
  cargo registry
- Hetzner Cloud prices: the page was opened, but the prices are rendered by a script and did not make it into the text: the estimates in §10.3 are orders of magnitude
