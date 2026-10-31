// SPDX-License-Identifier: AGPL-3.0-only
// The daemon interface used by the UI. Implementations: [XControlClient] (the `antennad` unix socket, desktop),
// a fake for tests and golden screenshots; later, the embedded Rust core via flutter_rust_bridge (phones, v1.x).

import 'models.dart';
import 'requests.dart';

/// A dialog: pairing (events, owner input, result) or a subscription (events only).
abstract interface class XDialog {
  /// Events as they happen (`invite_created`, `sas`, `need_input`, …). Single subscriber; events are buffered.
  Stream<XEvent> get events;

  /// Result: [LinkedReply] or an [XControlException] (`sas_mismatch`, `rejected`, `invite_unavailable`…).
  Future<Reply> get result;

  /// Owner input (`confirm` on A, `sas_code` on B).
  void input(XInput input);

  /// Close the connection: on B (join) this is a refusal; A's invite lives in the daemon until its TTL (to burn it, use
  /// `pairing_cancel`).
  Future<void> cancel();
}

/// Everything the owner's UI can ask of the daemon (x-control/1, docs/CONTROL.md).
abstract interface class XDaemon {
  /// Where we connect (shown to the owner).
  String get socketPath;

  /// Owner session token (v2): from the `session` event of the [login] connection; sent in `hello.session`.
  String? get sessionToken;
  set sessionToken(String? token);

  /// Hello only: daemon version, protocol, keystore state, effective role.
  Future<HelloOk> hello();

  /// Any non-dialog request.
  Future<Reply> call(XRequest request);

  /// A dialog request (invite with follow / join / subscribe).
  XDialog open(XRequest request);

  Future<StatusReply> status();
  Future<DaemonState> init(String password);
  Future<DaemonState> unlock(String password);
  Future<DaemonState> lock();
  Future<List<ContactInfo>> contacts();
  /// Send text. [address] (v6) names who it is for and its topic; only for a daemon that speaks `x-control/6`.
  /// [approvalId] is an approved approval request for this same text (the secret scanner held it). [urgent] (v7,
  /// CONTROL §33): interrupt the addressed agent of an own computer now; only with an agent address.
  Future<SentReply> send(String contact, String text,
      {Duration wait, MessageAddress? address, String? approvalId, bool urgent});

  /// Unread incoming messages; the daemon marks them read (for all clients, including `antenna inbox`).
  Future<List<InboxMessage>> inbox({bool wait, Duration? timeout});

  /// Link history: one page, newest first (`before` is the `next_before` cursor).
  /// [chat] (v7, CONTROL §26): only that chat of the link; only for a daemon that answers `chats`.
  Future<HistoryReply> history(String contact, {int? before, int? limit, ChatRef? chat});

  /// Subscription: events until closed ([XDialog.cancel]); `antenna lock` ends it with a `locked` error.
  XDialog subscribe();

  /// Trust level (owner password). Returns the updated contact.
  Future<ContactInfo> trust(String contact, int level, String password);

  /// Invites held by the daemon; the link and code only with the owner's [password] (otherwise `link` is empty and
  /// `sas` is null).
  Future<List<InviteInfo>> pairings({String? password});
  /// Confirm on A. [code] is what the owner typed in (the code they read out and the other side confirmed); without
  /// it (D-95) only when the invite says [InviteInfo.confirmWithoutCode]: the daemon then answers `code_required`
  /// if another invite showed a code at the same time, and a daemon older than D-95 answers `bad_request`.
  Future<LinkedReply> pairingConfirm(String id, String password, {String? code});
  Future<List<InviteInfo>> pairingCancel(String id, String password);

  Future<ApprovalsReply> approvals({bool all});
  Future<ApprovalInfo> approve(String id, String password);
  /// Deny (no password since D-84; [password] only for an older daemon that answers `bad_request` without it).
  Future<ApprovalInfo> deny(String id, {bool hour, String? password});

  /// Open an owner session held by this connection (v2): a [SessionEvent] carries the token; the result is only ever
  /// an error (`locked`, disconnect), meaning the session is closed. [XDialog.cancel] logs out.
  XDialog login(String password);

  /// Close our own owner session.
  Future<void> logout();

  /// Mark incoming messages read up to [upToSeq]; with [ids] (v6), also exactly these (pass 0 to mark only them).
  /// The reply is the contact with the new `unread`.
  /// With [chat] (v7), [upToSeq] marks only that chat's incoming messages.
  Future<ContactInfo> markRead(String contact, int upToSeq, {List<String>? ids, ChatRef? chat});

  /// Approve several requests with one password (v6): one result per item; a wrong password fails the whole call.
  Future<List<ApprovalResult>> approveMany(List<ApproveItem> items, String password);

  /// Deny several requests (v6), no password: one result per item.
  Future<List<ApprovalResult>> denyMany(List<String> ids, {bool hour});

  /// What an agent reads (v6): [everyone] on needs the owner [password], off does not. Returns the agent list.
  Future<List<AgentInfo>> agentSet(String name, {required bool everyone, String? password});

  /// The link's topics, most recent first (v6).
  Future<TopicsReply> topics(String contact);

  /// The chats of every link, or of one contact (v7, CONTROL §26): the person chat and one per agent of the contact,
  /// with unread counts, the latest message and the owner's local settings. A v7 daemon from before chats answers
  /// `unknown_command`.
  Future<List<ChatInfo>> chats({String? contact});

  /// The owner's local settings of a chat (v7; an owner session, no password): [name] (`""` removes it), [notify]
  /// ([ChatNotify]), [archived]. With none of them, the chat with a known agent of the contact is created.
  Future<ChatInfo> chatSet(String contact, {String? agent, String? name, String? notify, bool? archived});

  /// The agents' questions (v7, CONTROL §29): open ones, or all with [all]. A daemon from before them answers
  /// `unknown_command`.
  Future<List<EscalationInfo>> escalations({bool all = false});

  /// Answer an agent's question, or set it aside with [dismiss] (v7; an owner session).
  Future<EscalationInfo> escalationAnswer(String id, {String? answer, bool dismiss = false});

  /// Where an agent's questions go (v7): [to] a contact among its links, `null` the owner. Owner password.
  Future<List<AgentInfo>> agentEscalate(String name, String password, {String? to});

  /// Every picture the window may draw (v7, CONTROL §28): the owner's, their agents', each contact's. A v7 daemon
  /// from before pictures answers `unknown_command`.
  Future<List<PictureEntry>> pictures();

  /// Set the picture of the owner, or of the owner's [agent] (v7; an owner session): exactly one of [drawn] (an id
  /// such as `set1/fox`), [photo] (an absolute path the daemon reads and rebuilds) or [remove]. Returns the full list
  /// after the change.
  Future<List<PictureEntry>> pictureSet({String? agent, String? drawn, String? photo, bool remove});

  /// The daemon's rebuilt photo by its id (the owner's or a contact's): a JPEG it encoded itself.
  Future<PicturePhotoReply> picturePhoto(String id);

  /// History verification state.
  Future<HistoryStatusReply> historyStatus(String contact);

  /// Verify now; [accept] (with password) accepts a divergence; [repair] restores our copy from the contact's copy.
  Future<HistoryStatusReply> verify(String contact, {bool accept, bool repair, String? password});

  /// Delete a link (owner password).
  Future<RevokedReply> revoke(String contact, String password, {bool deleteHistory});

  /// Rename a contact (session only).
  Future<ContactInfo> rename(String contact, String label);

  /// Rekey: without [code], propose one; with [code], the code read out by the contact.
  Future<RekeyReply> rekey(String contact, String password, {String? code});

  /// Issue a token to an agent (owner password). The token appears in the reply only once; with [tokenFile] the
  /// daemon also writes it to the agent's token file and returns the path (preview.4).
  Future<AgentAddedReply> agentAdd(String name,
      {required int localLevel, required String password, List<String>? links, bool tokenFile = false, bool? everyone});

  /// A new token for an existing agent (owner password); the old one stops working. Shown only once.
  Future<AgentAddedReply> agentToken(String name, String password, {bool tokenFile = false});

  /// Whose messages the agent treats as tasks (owner password; preview.4). [contacts] `null`: the default (contacts
  /// at trust level 5); empty: nobody.
  Future<void> agentTasks(String name, String password, {List<String>? contacts});

  /// The owner's agents and their sessions.
  Future<List<AgentInfo>> agents();

  /// Revoke an agent's token (owner password).
  Future<void> agentRemove(String name, String password);

  /// Audit log for a contact.
  Future<List<ReceiptInfo>> log(String contact, {int? limit});

  /// Send a file (v3): [path] is an absolute path on this computer.
  /// [to] / [toAgent] (v7, PG-19): who the offer is for (`agent` with the contact's agent, `everyone`, `person`);
  /// none: no address. A daemon before them ignores the fields and sends the offer unaddressed.
  Future<FileInfo> shareFile(String contact, String path,
      {String? name, String? approvalId, String? to, String? toAgent});

  /// Files in quarantine (and sent files); [all] includes previously accepted ones.
  Future<List<FileInfo>> filesPending({String? contact, bool all});

  /// Safe preview (rebuilt by the daemon; the original stays in quarantine).
  Future<FilePreviewReply> filePreview(String id);

  /// Accept a file into the link's folder; a threat or an unchecked file only with [force] and the owner password.
  Future<FileInfo> fileAccept(String id, {String? name, bool force, bool allowSpecial, String? approvalId, String? password});

  /// Reject a file.
  Future<FileInfo> fileReject(String id);

  /// Withdraw a sent file the contact has not answered (preview.5): the outgoing file, `state: "withdrawn"`.
  Future<FileInfo> fileWithdraw(String id);

  /// Streams in progress (v4): after `lagged`, a reconnect, or a `seq` gap.
  Future<List<StreamView>> streams();

  /// Agent wake for a link (v4, owner password).
  Future<WakeReply> wakeSet(WakeSetRequest request);

  /// Wake rules and recent runs (v4).
  Future<WakeReply> wakeList();

  /// Turn off wake for a link (v4).
  Future<WakeReply> wakeOff(String contact);

  /// The owner's own turn in a contact's resident session (v6, CONTROL §21): `resident_delta` events, then a
  /// [ResidentTurnReply].
  XDialog wakeSay(String contact, String text, {bool toContact = false, bool interrupt = false});

  /// A resident session command; [password] for [ResidentAction.reset].
  Future<ResidentSessionReply> wakeSession(String contact, ResidentAction action, {String? password});

  /// LAN via mDNS (v5): turn on (owner password) or off.
  Future<LanReply> lanSet({required bool enabled, String? password});

  /// LAN state (v5).
  Future<LanReply> lanStatus();

  /// "Install signed updates by itself" (v7, D-103): the setting and what the daemon did.
  Future<UpdateAutoInfo> updateAutoStatus();

  /// Turn it on or off: the owner password both ways (the daemon checks it); `unsupported_install` where this
  /// installation cannot replace itself.
  Future<UpdateAutoInfo> updateAutoSet({required bool enabled, required String password});

  /// Install the staged release now (`not_found`: nothing staged; `update_in_progress`: it installs already). With
  /// [password] when the daemon keeps no keys for the restart (`keys_kept` false, D-137): `password_required` without.
  Future<UpdateAutoInfo> updateAutoNow({String? password});

  /// Postpone the staged release by an hour.
  Future<UpdateAutoInfo> updateAutoLater();

  /// The facts [agent] itself gets, for the window that started it, without an owner session (v7, CONTROL §23).
  XDialog agentWatch(String agent);

  /// Can received file [id] be accepted under [name] (preview.8, CONTROL §14)?
  Future<FileNameCheck> fileNameCheck(String id, {String? name});

  /// Save files from own computer [contact] (or from its [agent]) into [path]; without [path], clear it (v7, D-130).
  Future<FileSaveDirsReply> fileSaveDir(String contact, {String? agent, String? path, String? password});

  /// Let [entries] from own computer [contact] through without waiting (v7, D-130).
  Future<FileAllowReply> fileAllow(String contact, List<String> entries, {String? password});

  /// Take [entries] (all when `null`) off [contact]'s allowlist (v7, D-130).
  Future<FileAllowReply> fileDisallow(String contact, {List<String>? entries});

  // Owner keys (v7, CONTROL §22, D-102): a proof by an enrolled key stands in for the password.

  /// A one-time challenge for a proof (no session; the keys must be unlocked). `password_required` when proofs would
  /// be refused anyway: the client asks for the password before it shows a Touch ID prompt. [enroll] only for
  /// `owner_key_add` (issued even then; useless for any other proof).
  Future<OwnerChallengeReply> ownerChallenge({bool enroll = false});

  /// [request] with a proof: [prove] gets the exact text of the request as it goes on the line and returns the proof
  /// over it; the line carries that text unchanged (`{"req":…,"proof":…}`). Every password field of [request] is `""`,
  /// except `owner_key_add`, which takes both. A dialog request ([XRequest.isDialog]) waits for its final reply.
  Future<Reply> callWithProof(XRequest request, ProofSource prove);

  /// The same for a dialog: `login {password: "", hold: true}` opens the owner session with a proof.
  XDialog openWithProof(XRequest request, ProofSource prove);

  /// The enrolled owner keys and when the password is due (owner session).
  Future<OwnerKeysReply> ownerKeyList();

  /// Remove an owner key and its unlock slot (no password, no session; `not_found` when unknown).
  Future<void> ownerKeyRemove(String keyId);

  /// Unlock with the unlock slot of owner key [keyId] ([slotKey]: base64 of 32 bytes) instead of the password.
  Future<DaemonState> unlockWithSlot(String keyId, String slotKey);

  // Local models and local agents (v7, CONTROL §24): only for a daemon whose `hello_ok.proto` is x-control/7.

  /// The computer, the runtime, the catalog with each model's state here, and the local agents.
  Future<LocalModelsReply> localModels();

  /// Download a catalog model, or copy [fromFile] (an absolute path); the reply is its state at once, the progress
  /// comes as `local_model` events (`no_space` before a download that would not fit).
  Future<LocalModelInfo> modelInstall(String model, {String? fromFile});

  /// Cancel a model's download or delete its file; its local agents stay.
  Future<LocalModelInfo> modelRemove(String model);

  /// Create a local agent on a model (owner password).
  Future<LocalAgentInfo> localAgentAdd(String name, {required String model, required String password});

  /// A turn of the owner's conversation: `local_delta` events, then a [LocalTurnReply].
  XDialog localSay(String agent, String text, {bool interrupt});

  /// A page of a local agent's conversation, oldest first.
  Future<LocalHistoryReply> localHistory(String agent, {int? limit, int? before});

  /// `status`, `interrupt`, `stop` or `reset` ([LocalSessionAction]); the answer is the agent's state.
  Future<LocalAgentInfo> localSession(String agent, String action);
}
