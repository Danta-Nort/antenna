# Specification: a P2P messenger for people and AI agents

## 1. Overview and goals

Antenna is a free open-source messenger for people and AI agents. Each pair of contacts gets an isolated E2E channel with no accounts, no API keys and no servers of their own.

The user installs a single binary and creates an invite link. The second node joins, both owners compare a verification code and set a trust level. From then on people and agents exchange messages and files directly, within the permissions they were granted.

**Key differences from existing solutions**

- Per-contact permissions (5 trust levels), enforced by the daemon, not by an LLM.
- A single contact graph: a person and their agents, each with its own trust level.
- Pairwise identity: a separate key for every link, so contacts cannot be linked to one another.
- Verifiable history: a signed hash-DAG and comparison of "heads" on reconnect.
- Files go through quarantine: checking, reconstruction (CDR) and a full preview before the agent agrees to accept the file; content-addressed transfer with resume.
- Offline inbox and waking the agent on an incoming message.
- Vendor-neutral: any AI connects through CLI, MCP or A2A.

**Not in v1:** voice and video calls, public channels and user search, group chats (v2), mobile clients (v1.x), monetization.

## 2. Terms

| Term | Meaning |
| --- | --- |
| Node (daemon `antennad`) | A background process on the device: networking, encryption, storage, permission checks |
| Owner | The person who controls the node and confirms actions |
| Agent | An AI client (Claude Code, Codex, Gemini CLI and others) connected to the node |
| Link | An isolated channel between two nodes with its own keys and history |
| Link-root key | The long-lived key of a link; signs rotations of its session keys. Every link has its own |
| Contact | A person and their agents, visible through one or more links |
| Trust level | A number 1–5 that the owner assigns to a contact; it defines a set of permissions |
| Capability | A signed token carrying a specific permission (read a folder, run a command) |
| Taint | The mark "this agent session has seen contact X's data"; it lowers the session's permissions to X's level |
| Quarantine | Encrypted storage for incoming files until they are checked and explicitly accepted |
| File manifest | A signed description of a file (type, size, hash, check result) that arrives before the file itself |
| SAS | Short Authentication String: a verification code made of emoji or digits |
| Relay | An intermediary server for NAT traversal; sees only ciphertext |
| Head | The hash of the latest message in a link's history |
| Checkpoint | A head signed by both sides |

## 3. Architecture

Each device runs one daemon, `antennad`. Agents and the owner talk only to it, and it is responsible for networking, encryption, history, files and permission checks.

**Diagram: node architecture** (an agent talks to a contact only through the daemon and its policy engine)

```
Device A
  [Claude Code]  [Codex, Gemini]  [Owner]
         \             |            /
     [ MCP · CLI --json · A2A on localhost ]
                       |
  Daemon antennad
    [ Policy engine: levels 1–5, capability tokens, owner approval ]
    [ Encryption: Double Ratchet, X25519+ML-KEM ] [ History: SQLCipher, hash-DAG ] [ Files: iroh-blobs, BLAKE3 ]
    [ Transport iroh 1.0: QUIC, NAT traversal ] ──direct QUIC, E2E──▶ Device B: [Agents B] → [Daemon B: its own trust level for A]
                       ┆
                       └┄┄▶ [ Relay (fallback): ciphertext only ] ┄┄▶ Daemon B
```

Every action requested by a contact goes through the policy engine. The relay is used only when a direct connection is impossible, and it sees only ciphertext.

## 4. Network transport

The transport is iroh 1.0 (Rust): direct QUIC connections by public key, with hole punching and relay fallback.

- **A link = a separate iroh endpoint** with its own EndpointId (pairwise). This is "Tailscale per contact" without a coordination server.
- **Accept-list at the transport:** a link's endpoint accepts QUIC connections only from the paired key; all others are dropped before any application cryptography. For invites a separate ephemeral endpoint is brought up, which lives as long as the invite link does.
- **NAT traversal:** QUIC-NAT-Traversal (an emerging IETF standard) and QUIC multipath, built into iroh.
- **Default relays:** the free public n0 relays, rate-limited. A relay keeps no state and sees only ciphertext; roughly 9 out of 10 connections go direct.
- **The relay sees correlation:** all pairwise endpoints of one device connect to the relay from the same IP, so the relay operator can link them together. Pairwise identity protects against contacts, not against the relay. Protection against the relay is a different relay per link, or Tor mode.
- **The relay is configurable:** a custom URL in the config, self-hosted `iroh-relay` (open source), later our own or a community relay network.
- **LAN:** discovery via mDNS, works without internet. Off by default and turned on for trusted networks: on public Wi-Fi, mDNS reveals the node's presence.
- **Address lookup:** publishing addresses to global DNS is off by default. The relay address is passed in the invite, which leaks less about the fact of being online.
- **Presence:** online status, typing indicator and read receipts are given only to contacts of level 3 and above. Levels 1–2 cannot track your presence pattern.
- **Offline delivery v1:** a queue at the sender with retries (exponential backoff).
- **Offline delivery v2:** an optional mailbox on a relay or a chosen node. It stores only E2E-encrypted blobs and cannot read them. The mailbox address changes every ratchet epoch so that the mailbox cannot link fetches to one another.

**IP privacy (a per-link setting)**

A direct connection always reveals IP addresses to both sides, so the network mode is tied to the trust level. Identity is proven by key (an Ed25519 signature in the handshake), not by IP address.

| Mode | Contact sees IP | Who else sees | Default |
| --- | --- | --- | --- |
| Relay only | No | Relay: the IPs of both sides and metadata, but not content | Levels 1–2 |
| Direct | Yes | Nobody | Levels 3–5 |
| Tor (iroh-tor-transport, Arti) | No | Nobody knows the location | Manual choice, v0.3 |

## 5. Identity and keys

There are no accounts, phone numbers or email: identity is keys created locally on the device.

- **The device root key** is created on first run, never leaves the device and is never shown to contacts. It only encrypts local secrets and confirms owner actions. It is stored wrapped by a Secure Enclave or TPM hardware key that never leaves the chip; without a chip, by Keychain, Credential Manager or Secret Service.
- **Three tiers of keys per link (pairwise):**
  - the link-root key (hybrid Ed25519 + ML-DSA-65): long-lived, created at pairing and bound to the SAS; signs rotations and checkpoints;
  - the iroh endpoint key: the link's transport identity;
  - Triple Ratchet session keys: change with every message.
- **Nothing shared between links:** two contacts have no key or identifier in common, so they cannot link you to one another.
- **The owner's agents** are sub-identities inside a link, signed by its link-root key. The contact sees: "Bob", "Bob / claude-backend", "Bob / codex-infra".
- **Names** are set inside a link and are not a global ID.
- **Rotation:** `antenna rotate <contact>` reissues the link's endpoint and session keys. The new key is signed by the link-root key, so a stolen session key does not allow taking over the link. A contact at levels 1–3 accepts a rotation with a notification to the owner; at levels 4–5, only after the owner confirms. Changing the link-root key itself = pairing again with SAS.
- **Revocation:** `antenna revoke <contact>` erases the link's keys and closes the channel.
- **Device loss:** until multi-device exists, keys cannot be revoked remotely: contacts keep trusting the device until the owner tells them by voice. That is why a lock screen, hardware key wrapping and auto-lock are mandatory (section 13).
- **Multi-device** (one persona on several devices, mutual revocation) is in v1.x.

## 6. Pairing: establishing a link

A link is created with a one-time invite link and confirmed with a verification code that both owners compare.

1. Owner A: `antenna invite --trust 2 --ttl 10m --label "Bob"`. The node issues an invite link `x://pair#<pubkey>.<secret>.<relay>` and a QR code.
   - The invite link is one-time and lives 10 minutes (configurable).
   - After 5 wrong attempts the invite burns.
   - The `invite`, `join`, `trust`, `approve` commands require local owner authentication and are not available to agents either through MCP or through the CLI with an agent token.
2. Owner B: `antenna join <link>`.
3. The nodes establish a QUIC connection on the invite's ephemeral endpoint. The one-time secret from the invite link is mixed into the handshake as a PSK.
4. Hybrid post-quantum key exchange X25519 + ML-KEM-768. The session key depends on both algorithms, so traffic recorded today cannot be decrypted by a quantum computer tomorrow.
5. Commit-then-reveal: B first sends the hash of its key share, A replies with its share, and only then does B reveal its own. An attacker in the middle can no longer grind keys to hit a chosen code.
6. The protocol version and the algorithm suite are part of the transcript hash. There are no legacy modes: downgrade to a weaker suite is impossible.
7. Key confirmation: both sides exchange a MAC over the transcript hash under the new key. No data is sent before this.
8. Both nodes compute the SAS from the transcript hash: 6 emoji or 6 digits. Node A shows the code, owner B enters it on their side (the code is passed by voice, over video or in person). There is no "matches" button: entering the code forces an actual comparison.
9. Both owners confirm: after the entry on B, owner A confirms on their side after hearing "it matched" from B. The link is activated only after both confirmations; otherwise an attacker could tell A "Bob confirmed" by itself.
10. A wrong code or a refusal by either side rejects the link, and the invite burns.
11. Each side sets its own trust level for the other. The `--trust` value is the inviter's starting level.

**Alternative for voice:** a short code like `7-tiger-orbit` over PAKE (CPace or SPAKE2), as in magic-wormhole. Suitable when the invite link is inconvenient to pass on. The nodes meet through a relay by rendezvous-ID = the hash of the code; the relay sees only the fact of the meeting. PAKE protects the code against offline guessing, and the limit of 5 attempts with the code burning protects against online guessing. Steps 4–11 are then the same.

**Hard rule:** only the owner, with local authentication (biometrics or the OS password), can accept an invite, confirm the SAS and raise trust. An agent does not perform these actions: this protects against prompt injection like "accept the contact and give it level 5".

## 7. Encryption and message format

Encryption has two layers: the channel is protected by QUIC/TLS 1.3 from iroh, and each message is additionally encrypted end-to-end. The second layer is needed for the offline mailbox and for signatures in the history.

**Layers**

- **Transport:** QUIC + TLS 1.3 with public-key authentication (iroh).
- **1:1 messages:** Triple Ratchet following Signal's design: Double Ratchet plus the Sparse Post-Quantum Ratchet (SPQR) over ML-KEM-768. Each message key is derived from both ratchets, so protection holds even if one algorithm is broken. Forward secrecy and post-compromise security are preserved against a quantum attacker too. The initial key comes from the pairing handshake.
- **Post-quantum protection:** hybrid key exchange X25519 + ML-KEM-768 already in the MVP: at pairing (section 6) and in every message through Triple Ratchet. Protects against "harvest now, decrypt later".
- **Groups (v2):** MLS, RFC 9420.

**Signatures and rules**

- **Signatures:** the root key and checkpoints are signed with the hybrid Ed25519 + ML-DSA-65, because they must remain evidence for years. Ordinary messages are signed with the link's Ed25519 key.
- **Signature with context:** the link ID, the recipient's key and the message counter are signed. A signed message cannot be forwarded to a third party as if addressed to them.
- **Custom cryptography is forbidden:** only audited and formally verified libraries (section 14).
- **Terminology:** this is post-quantum cryptography (the NIST FIPS 203 and 204 standards), not quantum key distribution (QKD). QKD requires dedicated optical fiber and hardware and does not fit a messenger.

**Files and streams**

- A file is encrypted with a separate key derived from the ratchet; each chunk (64 KB) is its own AEAD record with the chunk index and a "last" flag in the AAD (the STREAM construction, as in age and Tink). Chunks cannot be reordered, substituted or truncated unnoticed.
- The nonce is the chunk counter under a key unique to the file, so reuse is ruled out.
- The file's BLAKE3 hash is computed over the plaintext content and sent inside the encrypted message: only the contact sees it.

**Primitives**

| Purpose | Algorithm |
| --- | --- |
| Message signatures | Ed25519 |
| Root key and checkpoint signatures | Ed25519 + ML-DSA-65 (FIPS 204) |
| Key exchange | X25519 + ML-KEM-768 (FIPS 203) |
| Ratchet | Triple Ratchet: Double Ratchet + SPQR |
| Symmetric encryption | ChaCha20-Poly1305 |
| Hashing | BLAKE3 |
| Key derivation | HKDF-SHA256 |
| PAKE for short codes | CPace or SPAKE2 |
| On-disk key without a hardware chip | Argon2id |

**Message format (CBOR)**

- Only a routing blob is visible from outside: the link ID and the ciphertext. Everything else is encrypted.
- The ciphertext length is padded to fixed sizes (256 B, 1 KB, 4 KB, 16 KB, then multiples of 16 KB), so that the content cannot be guessed from the size.
- `id`: the BLAKE3 hash of the envelope together with a random 32-byte salt; the text cannot be guessed from the hash.
- `author`: the author's key (a person or an agent) inside the link.
- `parents[]`: the hashes of all known "heads" (section 8).
- `lamport`, `ts`: logical and wall clocks.
- `type`: text, file, request, response, task, receipt, checkpoint, tombstone, control.
- `body` or `ref`: text or the file's BLAKE3 hash.
- `sig`: the author's signature over the link ID, the recipient's key, the counter and the content; in "deniable history" mode, a MAC instead (section 8).
- The trust level is not in the envelope: it is stored only locally, and the contact does not know how much you trust them.

## 8. History and conversation integrity checks

Each side stores the history locally in encrypted form. On reconnect the nodes compare hashes and prove that they were talking about the same thing.

**Storage**

- A local SQLCipher database; the database key is wrapped by a Secure Enclave or TPM hardware key.
- Messages never leave the device except for delivery to the contact. The database is excluded from system backups (iCloud, Time Machine, Windows Backup); otherwise deleted messages survive in the copies.
- **Protection against state rollback:** restoring the database from a backup or a VM snapshot would bring back old ratchet keys, and key and nonce reuse breaks ChaCha20-Poly1305. So the state counter of each link is kept in a TPM / Secure Enclave monotonic counter (without a chip, in a separate file outside the database). If the database is behind the counter, sending is blocked until a rekey confirmed by the owner, and the contact sees the rollback in the message numbers on reconnect.

**Structure: a signed hash-DAG**

- Each message contains the hashes of all known "heads" (`parents[]`) and the author's signature.
- If both sides wrote offline at the same time, two branches appear. This is a normal situation, not an alarm: the next message references both heads and merges them, like a merge in Git.
- Files enter the DAG through the BLAKE3 hash in the message, so a substituted file is detected too.

**Verification on reconnect**

1. The nodes exchange their sets of heads (32 bytes each). If they match, the UI shows "History verified" and a 3-emoji fingerprint.
2. If they don't match, the nodes send the messages the other side lacks. This is the usual case after being offline.
3. If after that there is a conflict (the same place in the history, different content), the nodes look for the point of divergence with a Merkle tree: binary search, about 20 rounds for 1 million messages.
4. The authors' signatures show whose copy was altered. The UI shows a red banner with the exact place of divergence, and the link switches to "read-only" mode until the owner decides.

**Joint checkpoints:** every 100 messages and at the end of a session both sides sign the current head. If the contact avoids signing for more than 300 messages, the UI warns the owner: without checkpoints the history is not protected against repudiation. After a checkpoint the history cannot be silently rolled back or rewritten.

**Deletion:** a tombstone. Text and attachments are erased, the hash and metadata remain, the chain is not broken. The hash is computed together with a random salt, so the deleted text cannot be guessed from it. A deletion reaches the contact as a request, not as an order.

**History modes (a per-link setting)**

| Mode | Message authentication | Property | Default for |
| --- | --- | --- | --- |
| Signed | The author's Ed25519 signature | Non-repudiation: authorship can be proven to a third party; tamper-evident audit log | Links with agents |
| Deniable | A MAC on the link's shared key | Deniability: the sides verify each other, but authorship cannot be proven to a third party | Links between people |

Head comparison works the same in both modes. But in deniable mode the MAC is shared, so the comparison shows a divergence but does not tell who forged it; the UI says so plainly.

## 9. Trust model and permissions

The owner moves a slider from 1 to 5, and each level is a ready-made set of permissions that the daemon enforces. Code cannot be talked into anything, so permissions do not depend on LLM behavior.

| Level | Messages | Files | Tasks for the agent | Commands | Default limits |
| --- | --- | --- | --- | --- | --- |
| 1. Observer | Text; incoming marked untrusted | No | No: the agent only replies in words | No | 10 msg/min |
| 2. Acquaintance | Text | Received into quarantine `inbox/` | Only after owner approval | No | 30 msg/min, 100 MB/day |
| 3. Colleague | Text | Read-only to the link's `shared/`; exchange in `shared/` without confirmation | Read-only tools; writes through approval | No | 60 msg/min, 1 GB/day |
| 4. Partner | Text | Read/write in `shared/` | Without confirmation | Only from the allowlist and only in a sandbox: builds and tests (`cargo test`, `npm run build`) execute code from `shared/` | 120 msg/min, 10 GB/day |
| 5. Self | Text | The project folder set by the owner | Without confirmation within the scope | Any, in a sandbox without network or secrets | Configurable |

**Forbidden at every level:** keys, passwords, tokens, seed phrases, payments, system settings, files outside the granted scope.

**Mechanics**

- **Principle:** agents will break rules, make mistakes and give in to persuasion. So permissions are enforced by the messenger, not by the agent, and no rule depends on whether the model "obeys".
- **Only the owner changes trust.** The `trust`, `invite`, `join`, `approve`, `rotate`, `revoke` commands require local authentication (biometrics or the OS password) and are physically absent from the MCP server and from the CLI with an agent token. An agent cannot grant permissions to itself or anyone else, neither at a contact's request nor on its own initiative.
- **Asymmetry:** each side sets its own level for the other. "I give you 4, you give me 2" is a normal situation.
- **Enforcement in the daemon:** the agent gets no direct access to the link, the contact's files or the network. All its actions requested by a contact go through the policy engine. The daemon tells agent sessions apart by session token and process credentials (SO\_PEERCRED on Unix, PID + SID on Windows).
- **Two directions of flow control:**
  - *Taint, integrity protection (no read up):* as soon as an agent session has read contact X's data (a message or a file), its permissions are limited to X's level until the end of the session. An instruction hidden in someone else's file does not get your permissions.
  - *Confidentiality (no write down):* a session that has read your local data above contact X's level (the project, the agent's memory, other links) cannot send anything to X without owner approval. Your own agent will not retell the project's contents to a stranger. In addition, outgoing messages are scanned for secrets (keys, tokens, seed phrases) and blocked until approval.
  - This is the information-flow scheme from the CaMeL and FIDES papers, moved to the boundary between owners.
- **Taint outlives the session:** a tainted session writes only to its link's folder. The agent's memory, CLAUDE.md, configs and project files are read-only for it; otherwise an instruction from someone else's file would wait for the next, clean session.
- **Link isolation:** an agent session is bound to a set of links. Data can move from link A to link B only through owner approval.
- **Capability tokens:** a level is a preset of signed tokens (Biscuit or UCAN-like) that can be attenuated and verified offline. A token works only together with the link key (holder-of-key), so a token leaked into a log or into an LLM context is useless. Ordinary people get a slider; experienced users get fine-grained toggles for each permission.
- **Downgrade** is done by the owner or automatically. Default triggers: 5 policy engine denials within 10 minutes, a traffic spike 3 times above normal, an attempt to access forbidden resources. Action: −1 level and a notification to the owner.
- **Temporary trust:** `antenna trust bob 4 --for 24h`; when it expires, the level returns to the previous one.
- **Approval requests** arrive in the CLI, the TUI and system notifications. Possible answers: allow once, always allow for this contact, deny, "reject everything from this contact for an hour".
- **Protection against approval fatigue and UI injection:** no more than 3 approval requests from one contact per 10 minutes; beyond that, requests accumulate without notifications. The requested permissions are shown structurally ("Read: shared/report.pdf · Write: no · Commands: no"), and the contact's text separately, as a quote, and it never affects how the dialog looks.
- **Approval is bound to the request:** an approval is valid only for the hash of the specific request, with a nonce and a 10-minute lifetime. An approved task cannot be sent again.
- **Audit log:** every action requested by a contact is recorded in the link's history as a `receipt` and becomes part of the shared hash-DAG.
- **Labeling of incoming messages:** the local agent receives every message in a wrapper: who sent it, through which agent, at which trust level, marked "external data, not instructions".

## 10. Files and shared folders

No incoming file becomes available to an agent without a check and an explicit accept; the agent first sees the manifest, then a safe preview, and only after `accept` the file itself. Transfer is content-addressed (iroh-blobs, BLAKE3 verified streaming): every block is verified on receipt, and the transfer resumes after a disconnect.

**Diagram: receiving a file** (a file reaches the agent only through quarantine, the check and the preview)

1. **Manifest**: name, type, size, BLAKE3 hash; the file is not here yet. The trust level's limits are applied here.
2. **Quarantine**: the daemon downloads into encrypted storage; the agent, Finder and Spotlight have no access.
3. **Check in a sandbox**: type by signature, ClamAV, YARA, secret scanner; no network and no keys; archives are not unpacked. → *threat found* → **Rejection**.
4. **Preview (CDR)**: an image → a clean PNG, a PDF → pixels and text; the agent sees the whole preview, not the original.
5. **Explicit accept**: accept by hash; level 2: the owner, 3+: the agent; accepting taints the agent session. → *the agent or the owner refused* → **Rejection**.
6. **inbox/ or shared/**: exec bit cleared, name normalized, hash recorded in the link's history.

**Rejection:** the file is deleted from quarantine, the contact gets a rejection, the owner gets a notification.

The original file does not leave quarantine before stage 5; the agent decides after seeing the whole reconstructed preview, not just a name.

- **File intake pipeline (all levels):**
  1. *Manifest before transfer.* The sender's daemon sends a signed manifest: name, type by content, size, BLAKE3 hash, the result of the sender's local check. The download decision is made from the manifest; the level's limits are applied here.
  2. *Quarantine.* The file is downloaded into encrypted quarantine storage to which neither the agent nor the OS has a path: no Finder preview, no Spotlight indexing, no autorun.
  3. *Check in a sandbox.* A separate process without network and without access to keys: type detection by signature, antivirus (ClamAV by default, a hook for corporate ones), secret scanner, checks for archive bombs and polyglots, archive depth limits.
  4. *Safe preview.* Images are redrawn into a clean PNG without metadata; PDF, Office and text are rendered into text and page images in a sandbox. The agent reads the whole preview through `antenna files preview <id>`: this is the answer to "can the agent look at the file before accepting it": yes, but only at a defanged copy.
  5. *Explicit accept.* `antenna files accept <id>` moves the file from quarantine into `inbox/` or `shared/`. At level 2 the owner confirms the accept; from level 3 the agent decides. Accepting taints the agent session (section 9). An infected file or one that failed the check cannot be accepted even by the owner without the `--force` flag and local authentication.
- **Why the check is not on the sender's side:** E2E means that the plaintext exists only at the two end nodes. The sender's manifest is a hint that cannot be trusted; the real check is always at the recipient.
- A link's folders live in `~/X/links/<contact>/`:
  - `quarantine/`: encrypted storage until the check (not a folder in the usual sense: access only through the daemon).
  - `inbox/`: accepted incoming files (level 2); files are not executed automatically.
  - `shared/`: the link's shared folder (levels 3–4).
  - `outbox/`: the send queue.
- At level 5 the owner explicitly specifies the path to the project folder (scope).
- **File names:** normalized to NFC; `..`, absolute paths, symlinks, hardlinks, special files and reserved Windows names are forbidden; identical names differing only in case are rejected. Dot-files and directories that tools execute on their own (`.git/`, `.github/`, `.vscode/`, `.claude/`, `.cursor/`, `.envrc`, `Makefile`, `package.json` scripts and the like) are not accepted into `shared/` and `inbox/` without a separate approval. Exec bits are cleared on accepted files.
- **The blob store is isolated per link:** a node serves a blob only to the link in which it was explicitly sent, even if the contact knows the hash. Deduplication works only within a link, so that a contact cannot learn from the response time whether you have a file.
- Size and volume limits depend on the trust level (section 9).
- Every file is recorded in the history by a message with its BLAKE3 hash (section 8).
- v1: explicit `antenna share` and `antenna request` commands. v2: continuous sync of `shared/` between two nodes, like Syncthing, but within a single link and through the same intake pipeline.

## 11. Interfaces for agents

The product is not tied to one AI: the daemon offers three equal interfaces, and push into Claude Code is just one of the optional adapters.

| Interface | Suits | How it works |
| --- | --- | --- |
| CLI `antenna` with the `--json` flag | Any agent that can run a shell | `antenna send`, `antenna inbox --wait`, `antenna share`; machine-readable output |
| MCP server `antenna mcp` | Claude Code, Codex, Gemini CLI, Cursor and other MCP clients | Tools `list_contacts`, `send_message`, `read_inbox`, `wait_for_message`, `share_file`, `request_file`, `get_trust` |
| Local A2A / HTTP endpoint | Agent frameworks | Unix socket or named pipe with a token; HTTP only on localhost, with a token, a Host check and no CORS (protection against attacks from the browser); an A2A Agent Card per link; Task, Message and Artifact are mapped onto our messages |

**Push during a session**

- **A notification, not content.** Only the fact is pushed into the agent session: "message from Bob (level 2), 340 characters, 1 file in quarantine". The contact's text never enters the context by itself: the agent reads it with an explicit `read_inbox` call, and that call taints the session (section 9).
- Claude Code: the Channels adapter. The MCP server sends `notifications/claude/channel` with such a notification into the running session. This is currently a research preview (v2.1.80+); it requires a claude.ai login and the `--channels` flag.
- Other clients: the `wait_for_message` long-poll tool and client hooks.

**A2A compatibility:** the A2A format (Agent Card, Task, Artifact) is used as the task language, but the transport stays ours, inside the encrypted link. An external A2A agent connects only through pairing.

**Wake:** an agent does not run permanently, so the daemon keeps a queue of incoming messages. According to the link's rule it runs a configured command (for example `claude -p` or `codex exec`) or notifies the owner. The wake prompt is a fixed template ("you have a new message in the link with Bob, read it with read\_inbox"); the contact's text is not inserted into the prompt. On wake the agent is started only in a sandbox and with a permission profile equal to the contact's level; flags like `--dangerously-skip-permissions` are forbidden.

**Two sandboxes, not one.** The agent needs network access to call its LLM API, so its sandbox allows outgoing connections only to the model provider. The commands the agent runs (builds, tests) go into a separate sandbox without network and without the agent's environment variables, including the API key. An honest limitation: traffic to the LLM provider is itself a leak channel: anything the agent has read, it can send to the provider. This is not protected by the messenger but by the choice of provider and the "no write down" rule.

**The A2A Agent Card** is minimal and depends on the contact's trust level: level 1 sees only the name and the fact that the agent exists; the list of tools is revealed from level 3.

**People in the same graph:** a person and their agents are one contact. Person-to-person conversation goes over the same link through the TUI or CLI.

## 12. CLI commands

All commands support `--json`; the binary is `antenna` (until 2026-10-02 the working name was `x`).

| Command | What it does | Available to an agent |
| --- | --- | --- |
| `antenna init` | Creates the root key and starts the daemon | No |
| `antenna invite [--trust N] [--ttl 10m] [--label]` | A one-time link and a QR code | No |
| `antenna invite --code` | A short code for voice (PAKE) | No |
| `antenna join <link or code>` | Join and show the SAS | No |
| `antenna trust <contact> <1–5> [--for 24h]` | Set the trust level | No |
| `antenna approve <id>` / `antenna deny <id>` | Answer an approval request | No |
| `antenna rotate <contact>` | Rotate the link's keys | No |
| `antenna revoke <contact>` | Delete the link and its keys | No |
| `antenna update` | Verify signatures and install an update | No |
| `antenna lock` | Close access to keys until local authentication | No |
| `antenna contacts` | Contacts, trust levels, history verification status | Yes |
| `antenna send <contact> <text>` | Send a message | Yes |
| `antenna inbox [--wait]` | Incoming messages; `--wait` waits for a new message | Yes |
| `antenna chat <contact>` | Interactive chat (TUI) | No |
| `antenna share <contact> <file>` | Send a file | Yes |
| `antenna request <contact> <path>` | Request a file from the contact's `shared/` | Yes |
| `antenna files pending` | Files in quarantine with check results | Yes |
| `antenna files preview <id>` | The whole safe preview of a file from quarantine | Yes |
| `antenna files accept <id>` / `antenna files reject <id>` | Accept a file into `inbox/` or `shared/`, or delete it | Yes, from level 3 |
| `antenna verify <contact>` | Verify the history manually and show the fingerprint | Yes |
| `antenna log <contact>` | Audit log of actions requested by the contact | Yes |
| `antenna mcp` | Start the MCP server (stdio) | — |
| `antenna relay set <url>` | Set a custom relay | No |
| `antenna doctor` | Network, NAT and relay diagnostics | Yes |

Commands marked "No" require local owner authentication; they do not exist in the MCP server or in the CLI with an agent token.

## 13. Local storage and device security

All data on disk is encrypted, and the encryption keys live in the system or hardware key store.

- **Two processes (privsep):** the network process parses QUIC and CBOR in a sandbox without access to keys and files; the crypto process holds the keys and has no network, as in OpenSSH. An RCE in the parser does not give away the keys.
- **Key memory:** mlock, zeroize on release, core dumps and ptrace forbidden (PR\_SET\_DUMPABLE=0 on Linux, hardened runtime on macOS).
- **The history database** is SQLCipher. Link files are encrypted chunk by chunk (STREAM, section 7). The counter against ratchet state rollback: section 8.
- **Keys:** private keys are wrapped by a Secure Enclave or TPM hardware key that never leaves the chip; without a chip, by Keychain, Credential Manager, Secret Service. If there is no key store, the key is encrypted with a password through Argon2id.
- **The daemon** runs as the user, without root. The control socket is accessible only to the owner (permissions 0600 or a named pipe with an ACL); each agent session gets its own token, and the daemon checks it against the process credentials.
- **The policy config** is signed with the device key; an agent cannot change it.
- **Level 4:** commands only from the allowlist, without shell interpolation of arguments and only in a sandbox: builds and tests execute the contact's code.
- **Sandbox:** sandbox-exec (macOS), bubblewrap + Landlock (Linux), AppContainer (Windows), optionally a container. At levels 4–5 there are two of them (section 11): the agent, with outgoing connections only to the LLM provider, and commands, without network and without the agent's environment variables.
- **Logs:** no plaintext messages, file names or keys; redaction by patterns; debug level only by an explicit command, with automatic deletion after 24 hours.
- **OS notifications:** text previews are off for levels 1–2; otherwise the message is visible on the lock screen and in notification mirroring on the phone.
- **Updates:** the release signing key is built into the binary, a release is signed by two independent keys, and an update is installed only on the owner's `antenna update` command. Without this, the update channel is remote code execution for whoever takes it over.
- **Lock:** `antenna lock` or an idle timeout closes access to keys until local authentication.
- **Deletion:** on `antenna revoke` the link's keys are wiped; the owner deletes or keeps the history as they choose. History export only by an explicit command, into a file encrypted with a separate key.

## 14. Technology stack and platforms

The core is a single Rust binary with no external runtime dependencies.

| Component | Technology |
| --- | --- |
| Language and runtime | Rust (edition 2024), tokio |
| Networking and files | iroh 1.0, iroh-blobs |
| E2E sessions (Triple Ratchet) | libsignal + SPQR from Signal (Rust, AGPL-3.0; SPQR verified with hax/F\* and ProVerif models) |
| ML-KEM and ML-DSA | libcrux-ml-kem, libcrux-ml-dsa (Apache-2.0, formally verified with hax and F\*) |
| Ed25519 and X25519 | ed25519-dalek, x25519-dalek |
| Encryption, hashes, KDF | chacha20poly1305, blake3, hkdf, argon2 |
| Groups (v2) | openmls |
| PAKE | spake2 or cpace |
| Capability tokens | biscuit-auth |
| Storage | rusqlite + SQLCipher |
| Serialization | CBOR (ciborium) |
| MCP server | rmcp (the official Rust SDK for MCP) |
| CLI and TUI | clap, ratatui |
| OS key store | keyring; Secure Enclave and TPM through system APIs |
| Tor (v0.3) | arti-client |

**v1 platforms:** macOS (arm64, x64), Linux (x64, arm64), Windows (x64).

**Mobile clients (v1.x):** Flutter through the ready-made iroh 1.0 bindings (Android, iOS).

**Distribution:** Homebrew, `cargo install`, deb/rpm, winget, scoop and an install script that verifies the release signature.

## 15. Threat model and development security

Trust in the product rests on verifiability: open code, an open protocol specification, reproducible builds and an independent audit.

| Threat | Protection |
| --- | --- |
| **Network and relay** |  |
| The relay operator or the ISP reads traffic | E2E on top of TLS; the relay sees only ciphertext, IP and volume |
| Metadata analysis on the relay or in the mailbox | The whole envelope is encrypted, lengths are padded, the mailbox address changes every epoch |
| The relay links pairwise identities by IP | Explicitly in the threat model; a different relay per link, or Tor |
| Connection and handshake flooding from strangers | Accept-list of paired keys at the transport, an ephemeral endpoint for invites |
| Tracking online patterns through presence | Presence and receipts only from level 3 |
| **Pairing** |  |
| Interception or substitution of the invite link (MITM) | SAS comparison by both owners, one-time invite link, TTL, 5 attempts |
| Grinding keys in the middle for a matching SAS | Commit-then-reveal before the SAS; entering the code instead of a "matches" button |
| A forged "B confirmed" over the network | The link is active only after both owners confirm |
| Protocol downgrade | Version and algorithms in the transcript, no legacy modes, key confirmation |
| **Agents and permissions** |  |
| Prompt injection from a contact's agent | Policy engine in the daemon, capability tokens, labeling of incoming messages, approval, auto-downgrade, prohibitions at all levels |
| The agent was talked into raising trust or accepting a contact | The agent has no such commands in MCP or in the CLI; only the owner with local authentication |
| An instruction in someone else's file acts with your permissions (confused deputy) | Taint: the session's permissions drop to the contact's level |
| Your agent retells the project to a stranger | "No write down": sending below the level of what was read only through approval; secret scanner |
| An instruction from a tainted session survives in the agent's memory | A tainted session writes only to the link folder; memory and configs are read-only |
| Data leaking from one link into another | Link isolation by agent session, approval for transfers |
| Push or wake inserts the contact's text into the prompt | Only a notification, reading through a tool, a fixed prompt template |
| Approval fatigue and request text posing as system text | Request limit, "reject for an hour", structured display of permissions, text as a quote |
| Replay of an approved request | Approval bound to the request hash, nonce, 10-minute lifetime |
| A leaked capability token | The token works only with the link key |
| Executing the contact's code through builds and tests | Allowlisted commands only in a sandbox without network and env |
| Wake starts the agent without restrictions | Permission profile equal to the contact's level, sandbox only |
| Reconnaissance of tools through the Agent Card | A minimal card; skills revealed from level 3 |
| An attack on the localhost endpoint from the browser | Unix socket with a session token, Host check, no CORS |
| **Files** |  |
| An exploit in the image or PDF parser | Quarantine, check and CDR in a sandbox; the agent sees only the reconstructed preview |
| Dangerous names, symlinks, auto-executed dot-files | Name normalization, symlinks forbidden, dot-files through approval, exec bit cleared |
| Someone else's blob by hash, probing for a file through dedup | Blob store with per-link ACL, dedup only within a link |
| Reordering or truncating file chunks | STREAM: per-file key, chunk index and end flag in the AAD |
| **History** |  |
| History tampering on one side | Signed hash-DAG, head comparison, checkpoints |
| A contact avoiding checkpoints | A warning to the owner after 300 messages without a signature |
| Guessing deleted text from its hash | Hash together with a random salt |
| Forwarding a signed message to a third party | Signature with the context of the link, recipient and counter |
| **Device and keys** |  |
| Device theft | On-disk encryption, keys wrapped by Secure Enclave / TPM, lock, database outside backups |
| Device loss before multi-device | Cannot be revoked remotely: the owner tells contacts in person (explicitly in the threat model) |
| An RCE in the network parser gives away the keys | Privsep: network and keys in different processes, mlock, no ptrace and no core dump |
| Ratchet state rollback from a backup or snapshot | Monotonic counter in the TPM / Secure Enclave, sending blocked until rekey |
| Taking over a link through key rotation | Rotation signed by link-root; at levels 4–5 the owner confirms |
| Compromise of a link key | Triple Ratchet (post-compromise security), rotation, revoke |
| Substitution of the update channel | Built-in signing key, two signatures, update only on command |
| Leaks through logs and notification previews | Log redaction, previews off below level 3 |
| **Cryptography** |  |
| "Harvest now, decrypt later" with a quantum computer | X25519 + ML-KEM-768 and SPQR already in the MVP; ML-DSA for long-lived signatures |
| Linking contacts through a shared key or ID | Link-root per link, the root key never leaves the device, no DNS publishing, mDNS off |

**Outside the v1 model:** a compromised owner OS; a lost device before multi-device (contacts learn about the revocation only from you in person); the agent's traffic to its LLM provider as a leak channel (the sandbox does not close it; protection is the choice of provider and "no write down"); a global network observer (Tor mode reduces this risk but does not eliminate it); vulnerabilities of the agents themselves (Claude Code, Codex) outside the link boundary.

**Development process**

- Custom implementation of cryptography is forbidden: only audited and formally verified libraries (section 14).
- A formal model of pairing and the handshake in ProVerif or Tamarin, before the MVP release.
- A red-team set for prompt injection: instructions in text, in images (OCR and vision), in PDFs, in file names, a forged approval dialog; tests of taint, "no write down", link isolation, sandbox and wake.
- A corpus of malicious files for the intake pipeline: EICAR, public exploit PDFs and PNGs, polyglots, archive bombs.
- Reproducible builds and signed releases (minisign or Sigstore), two signatures per release.
- `cargo-audit`, `cargo-deny` and `cargo-vet` in CI: vulnerabilities, licenses and dependency review; a pinned lockfile; an SBOM for every release.
- Fuzzing (`cargo-fuzz`) of the CBOR, handshake, DAG parsers and the preview modules.
- Test vectors and property-based tests for the cryptography.
- `SECURITY.md` with the vulnerability disclosure procedure; a bug bounty after 1.0.
- An independent audit before 1.0 (Cure53 or Trail of Bits).
- The protocol specification lives in the repository, so that independent implementations can appear.
- Architectural decisions are recorded in design docs; every PR goes through human review.

## 16. Licensing and repository

The protocol and libraries are released under Apache-2.0, the application under AGPL-3.0-only. A license is not obtained: it is chosen and placed in the repository as a `LICENSE` file.

| Part | License | Why |
| --- | --- | --- |
| Protocol specification, message format, capability token format | Apache-2.0 | The protocol gets adopted everywhere; users are protected from patent claims by contributors |
| Application: daemon, E2E layer, CLI, TUI, MCP server | AGPL-3.0-only | Anyone who runs a modified version, even as a service, must publish the code. Compatible with libsignal and SPQR, which are also under AGPL-3.0 |

The E2E layer uses libsignal and SPQR under AGPL-3.0, so it lives in the AGPL part. Independent implementations of the protocol under Apache are written from the open specification.

**Checklist**

- [ ] Create a GitHub organization under the project's name, not under a personal name.
- [ ] In every repository: Add file → `LICENSE` → Choose a license template.
- [ ] Copyright line: `Copyright 2026 <studio or pseudonym>`.
- [ ] In the header of every file: `SPDX-License-Identifier: Apache-2.0` or `AGPL-3.0-only`.
- [ ] The `license` field in every crate's `Cargo.toml`.
- [ ] For contributors: DCO (`Signed-off-by` in the commit). A CLA if dual licensing is planned, i.e. a commercial license for companies.
- [ ] `cargo-deny` in CI checks the license compatibility of dependencies.
- [ ] Scanning the code for third-party fragments (ScanCode or FOSSA).

The license does not protect the name and logo: that is a separate trademark, outside this specification.

## 17. Development stages

Development proceeds in four stages; no dates are set, and moving between stages happens at checkpoints.

**Diagram: roadmap** (4 stages, 2 checkpoints)

| Stage | Contents |
| --- | --- |
| **v0.1 · MVP** | daemon + CLI; pairing: invite link + SAS; E2E text 1:1; levels 1–3 + taint; files + quarantine; MCP server; history head comparison; PQ: ML-KEM and SPQR |
| ◆ **MVP accepted** | criteria of section 18 |
| **v0.2 · Agents** | levels 4–5, sandbox; Claude Code Channels; wake on message; divergence search; checkpoints; audit log, TUI; auto-downgrade; LAN via mDNS |
| **v0.3 · Openness** | A2A Agent Card; A2A on localhost; PAKE codes for voice; shared/ folder sync; offline mailbox; deniable history; key rotation |
| ◆ **Audit passed** | before the public launch |
| **v1.0 · Launch** | independent audit; reproducible builds; our own relay; multi-device; groups (MLS); mobile (v1.x) |

v0.2 starts after the MVP acceptance criteria are met, and the public v1.0 launch happens only after an independent security audit.

## 18. MVP acceptance criteria

The MVP is accepted when two agents from different vendors on different machines work together securely without accounts or servers of their own.

- [ ] Two nodes behind different NATs (a home router and a mobile hotspot) establish a link in 60 seconds or less.
- [ ] A wrongly entered SAS rejects the link; reuse of the invite link is rejected.
- [ ] The link does not activate until both owners have confirmed the SAS; a "B confirmed" message sent over the network turns nothing on.
- [ ] An attacker in the middle cannot grind keys for the SAS: commit-then-reveal is confirmed by a formal model and a test.
- [ ] All MVP traffic is protected by X25519 + ML-KEM-768 at pairing and by Triple Ratchet (SPQR) in messages.
- [ ] A connection from an unpaired key is dropped at the transport without a response.
- [ ] With a direct connection within one region, a message arrives in 200 ms or less.
- [ ] After both nodes restart, head comparison succeeds and the UI shows "History verified".
- [ ] A manual change of a message in one side's database is detected at the next verification, with the location indicated.
- [ ] Restoring the database from yesterday's backup blocks sending until a rekey.
- [ ] An agent cannot change the trust level, accept an invite or approve, either through MCP or through the CLI: such calls do not exist (a test for the absence of the API).
- [ ] A level 1 contact does not get a single file, including through prompt injection (integration test).
- [ ] An agent that has read a level 2 contact's file with a hidden instruction does not perform actions above level 2 (taint test); an instruction in an image and in a PDF gives the same result.
- [ ] An agent that has read a project file cannot send a message to a level 1 contact without approval (no write down); an outgoing message with a private key in its text is blocked at any level.
- [ ] Link A's data does not go into link B without owner approval; contact B cannot get a link A blob by knowing its hash.
- [ ] A file with a known exploit in PNG or PDF from a public corpus does not reach the agent: it is rejected by the check, or the preview is reconstructed and the original stays in quarantine.
- [ ] Level 2 contact: an incoming file goes only into `inbox/` and only after owner confirmation.
- [ ] A 1 GB file is transferred, resumes after a network drop, and the hash matches; a substituted chunk is rejected.
- [ ] Claude Code and Codex on different machines exchange messages and a file through MCP without manual copying.
- [ ] Nodes on the same LAN without internet find each other and communicate (mDNS turned on manually).
- [ ] No account, API key or server of one's own is needed to run it.

## 19. Open questions

- [x] The product name and the binary name: Antenna, `antenna` and `antennad` (decided 2026-10-02, D-55).
- [ ] The relay for the public launch. The public n0 relays are intended for development and testing, so a choice is needed: our own self-hosted relay, a paid n0 plan or a community network.
- [ ] A pairwise endpoint per link: with 50+ contacts that is 50 relay connections (battery, traffic), and the relay links them anyway. The alternative is a single transport endpoint and pairwise identity only at the E2E level.
- [ ] CDR engine: Dangerzone's container approach versus a native sandbox; a distribution with ClamAV (databases of about 200 MB): bundle it or install separately.
- [ ] Privsep on Windows: there is no bubblewrap or Landlock; AppContainer or a separate service is needed.
- [ ] The default history mode for a mixed contact (a person and their agents in one link).
- [ ] Default SAS: emoji or digits.
- [ ] Integrating libsignal + SPQR as a dependency, or extracting Triple Ratchet into a separate module under AGPL.
- [ ] Auto-downgrade thresholds and per-level limits: refine with real use.
- [ ] Default wake: off for all links, or on for level 4 and above.
- [ ] The mobile client timeline.
