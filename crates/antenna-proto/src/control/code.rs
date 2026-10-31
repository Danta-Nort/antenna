// SPDX-License-Identifier: Apache-2.0
//! Error codes of the control protocol (`docs/CONTROL.md` §10): the `code` of every `{"err":…}`. Clients match on
//! these, never on the message text.

/// Invalid request.
pub const BAD_REQUEST: &str = "bad_request";
/// No such command (the command does not exist for this role).
pub const UNKNOWN_COMMAND: &str = "unknown_command";
/// The keystore has not been created.
pub const NOT_INITIALIZED: &str = "not_initialized";
/// The keystore has already been created.
pub const ALREADY_INITIALIZED: &str = "already_initialized";
/// The keystore is locked.
pub const LOCKED: &str = "locked";
/// Wrong password.
pub const WRONG_PASSWORD: &str = "wrong_password";
/// No permission (role).
pub const FORBIDDEN: &str = "forbidden";
/// Not found.
pub const NOT_FOUND: &str = "not_found";
/// Pairing failed.
pub const PAIRING_FAILED: &str = "pairing_failed";
/// A wrong SAS code was entered.
pub const SAS_MISMATCH: &str = "sas_mismatch";
/// Pairing confirmation without the code is not accepted for this invite: another invite of this node showed a
/// code while it was open, so the owner types the code they read out (D-95, PROTOCOL §9).
pub const CODE_REQUIRED: &str = "code_required";
/// The owner refused.
pub const REJECTED: &str = "rejected";
/// The invite expired / burned / is unavailable.
pub const INVITE_UNAVAILABLE: &str = "invite_unavailable";
/// Network.
pub const NETWORK: &str = "network";
/// Timeout.
pub const TIMEOUT: &str = "timeout";
/// Not implemented in this slice.
pub const NOT_IMPLEMENTED: &str = "not_implemented";
/// Internal error.
pub const INTERNAL: &str = "internal";
/// The agent token is unknown or revoked.
pub const TOKEN_INVALID: &str = "token_invalid";
/// The token is bound to a different process (a different MCP host).
pub const TOKEN_BOUND: &str = "token_bound";
/// Policy: the owner's approval is needed (`antenna approve <id>`); details are in `approval`.
pub const APPROVAL_REQUIRED: &str = "approval_required";
/// Policy: forbidden at this level (approval will not help).
pub const DENIED: &str = "denied";
/// Level or attempt limit; retry later.
pub const RATE_LIMITED: &str = "rate_limited";
/// The approval has already been used (repeat).
pub const APPROVAL_USED: &str = "approval_used";
/// The approval has expired (10 minutes).
pub const APPROVAL_EXPIRED: &str = "approval_expired";
/// The approval was issued for a different request (hash mismatch).
pub const APPROVAL_MISMATCH: &str = "approval_mismatch";
/// The owner denied the request.
pub const APPROVAL_DENIED: &str = "approval_denied";
/// The owner has not answered yet.
pub const APPROVAL_PENDING: &str = "approval_pending";
/// An owner session is needed (`antenna login`, Q-14b).
pub const LOGIN_REQUIRED: &str = "login_required";
/// The link state rolled back: sending is blocked until a rekey (`antenna rekey`, SPEC §8).
pub const REKEY_REQUIRED: &str = "rekey_required";
/// History divergence: the link is read-only until the owner decides (`antenna verify --accept`, SPEC §8).
pub const READ_ONLY: &str = "read_only";
/// After a rekey, the history lost to the rollback is still being restored from the contact's copy: retry later.
pub const RECOVERING: &str = "recovering";
/// Another message from the same author with the same counter is already in the history (divergence, SPEC §8).
pub const HISTORY_CONFLICT: &str = "history_conflict";
/// The message author's signature is invalid (SPEC §7).
pub const BAD_SIGNATURE: &str = "bad_signature";
/// The message author is neither the side's link-root nor an agent it announced (v5, `docs/PROTOCOL.md` §21).
pub const UNKNOWN_AUTHOR: &str = "unknown_author";
/// There is no agent sandbox on this OS (v4, wake): the agent is not run without one.
pub const SANDBOX_UNAVAILABLE: &str = "sandbox_unavailable";
/// The declared size is above the daemon's limit (v5, `share_file_content`): the message names the limit.
pub const TOO_LARGE: &str = "too_large";
/// A message's text is longer than a message holds (`link::MAX_TEXT`, 64 KiB of UTF-8): send it as a file. Before
/// 0.2.0 this was `bad_request`; the message names the size and the limit.
pub const TEXT_TOO_LONG: &str = "text_too_long";
/// Owner proof (v7, `docs/CONTROL.md` §22): the challenge is unknown, used, expired or was issued to another client.
pub const CHALLENGE_INVALID: &str = "challenge_invalid";
/// Owner proof (v7): the signature does not verify (another key, another command, a malformed signature).
pub const PROOF_INVALID: &str = "proof_invalid";
/// Owner proof or unlock slot (v7): no such owner key (removed, or never enrolled here).
pub const OWNER_KEY_UNKNOWN: &str = "owner_key_unknown";
/// Owner key (v7): this build does not accept this key (the public test key outside a debug build that asked for it).
pub const OWNER_KEY_REFUSED: &str = "owner_key_refused";
/// v7: the password is needed: the command takes only the password, 14 days passed since the last password, or three
/// proofs failed in a row.
pub const PASSWORD_REQUIRED: &str = "password_required";
/// Unlock slot (v7): the slot key does not open the slot, or the slot was changed.
pub const SLOT_INVALID: &str = "slot_invalid";
/// Not enough free disk space for a model (v7, `docs/CONTROL.md` §24): the message says how much is needed and how
/// much is free.
pub const NO_SPACE: &str = "no_space";
/// A model file does not match the size and SHA-256 of this release (v7); it was deleted.
pub const HASH_MISMATCH: &str = "hash_mismatch";
/// A model download failed (v7): the network, the host, or the file is gone; it resumes on the next try.
pub const FETCH_FAILED: &str = "fetch_failed";
/// This build has no local model runtime, or this computer cannot run one (v7).
pub const RUNTIME_UNAVAILABLE: &str = "runtime_unavailable";
/// A local model does not fit the memory local models may use, even with nothing else loaded (v7): the message has
/// the numbers.
pub const NO_MEMORY: &str = "no_memory";
/// This installation cannot replace itself (v7, `update_auto_set`): a development build, the Linux window bundle.
pub const UNSUPPORTED_INSTALL: &str = "unsupported_install";
/// An automatic install is running now (v7, `update_auto_now` / `update_auto_later`).
pub const UPDATE_IN_PROGRESS: &str = "update_in_progress";
/// No worker can start for this request (v7, `worker_spawn`, D-111): the budget, the team's or the machine's limit,
/// a kind this machine cannot run, or "local only"; the message says which.
pub const NO_CAPACITY: &str = "no_capacity";
/// A task is not in a state that allows this (v7, D-111): the message names its state and what it needs.
pub const TASK_STATE: &str = "task_state";
/// Merging a result conflicts with the branch it goes into (v7, D-111): nothing was merged; the message lists the
/// files.
pub const MERGE_CONFLICT: &str = "merge_conflict";
/// A photo cannot be a profile picture (v7, `picture_set`, `docs/CONTROL.md` §28): it is not an image, it did not pass
/// the file check, or it is too large; the message says which.
pub const PICTURE_REFUSED: &str = "picture_refused";
/// A message between two agents of this computer would be one too many in a chain of such messages (v7, the local
/// route, `docs/CONTROL.md` §32, D-132): the daemon stops loops between agents; wait, or the owner steps in.
pub const HOP_LIMIT: &str = "hop_limit";
