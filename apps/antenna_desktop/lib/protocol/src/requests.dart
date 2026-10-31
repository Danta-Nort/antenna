// SPDX-License-Identifier: AGPL-3.0-only
// Requests and owner input of antenna_proto::control (docs/CONTROL.md). On the wire: `{"req":{"cmd":…}}` and
// `{"input":{…}}`. The daemon parses requests strictly (`deny_unknown_fields`), so we never send fields its version
// does not have. Commands that change trust or links carry the owner password; the daemon checks it on every call
// (Q-12a).

import 'dart:convert';

import 'errors.dart';
import 'models.dart';

part 'requests_agent_stop.dart';
part 'requests_approvers.dart';
part 'requests_chats.dart';
part 'requests_escalations.dart';
part 'requests_connections.dart';
part 'requests_devices.dart';
part 'requests_files.dart';
part 'requests_local.dart';
part 'requests_owner_keys.dart';
part 'requests_resident.dart';
part 'requests_pictures.dart';
part 'requests_teams.dart';
part 'requests_updates.dart';

/// The control protocol versions this client speaks, newest first (`CONTROL_SUPPORTED`, docs/CONTROL.md §2). The
/// client says the first one; a daemon that refuses it (`bad_request` "unsupported control protocol") is asked again
/// with the next: v7 adds owner keys (Touch ID, §22), updates that install by themselves, `agent_watch` and
/// `file_name_check` (§23, §14) and local models (§24); v6 addressing, topics and batch approvals (§20); a v5 daemon
/// gets none of them. Everything newer than v5 is used only after `hello_ok.proto` says so ([controlVersion]).
const List<String> controlProtos = ['x-control/7', 'x-control/6', 'x-control/5'];

/// The newest version, the one the client says first (`CONTROL_PROTO`); always `controlProtos.first`.
const String controlProto = 'x-control/7';

/// The version to try after the daemon refused [proto], or `null` when [proto] is the oldest this client speaks.
String? olderControlProto(String proto) {
  final i = controlProtos.indexOf(proto);
  return i < 0 || i + 1 >= controlProtos.length ? null : controlProtos[i + 1];
}

/// The first version with local models and local agents (CONTROL §24): `local_models`, `local_say` and the
/// `local_model` / `local_agent` events.
const int localModelsVersion = 7;

/// The first version with teams of agents (CONTROL §25): `team_*`, `task_*` and the `team` event.
const int teamsVersion = 7;

/// The number in `x-control/N` (`hello_ok.proto`); 0 when absent or unreadable (a v0 daemon does not echo it).
int controlVersion(String? proto) {
  if (proto == null) return 0;
  final i = proto.lastIndexOf('/');
  return int.tryParse(i < 0 ? proto : proto.substring(i + 1)) ?? 0;
}

/// The daemon refused the hello's protocol version (it is older than this client).
bool isUnsupportedProto(Object e) =>
    e is XControlException && e.code == XErrorCode.badRequest && e.message.contains('unsupported control protocol');

/// Who a message is for and which topic it belongs to (v6, CONTROL §20). Only for a daemon that speaks
/// `x-control/6`: an older one rejects the unknown fields.
final class MessageAddress {
  const MessageAddress({this.to, this.toAgent, this.topic, this.topicId});

  /// The contact's person (the other side's owner).
  const MessageAddress.person({this.topic, this.topicId})
      : to = 'person',
        toAgent = null;

  /// Everyone on the other side (agents read it only when their owner allows it).
  const MessageAddress.everyone({this.topic, this.topicId})
      : to = 'everyone',
        toAgent = null;

  /// One agent of the other side, by the name the contact announced.
  const MessageAddress.agent(String name, {this.topic, this.topicId})
      : to = 'agent',
        toAgent = name;

  /// `person` / `everyone` / `agent`.
  final String? to;
  final String? toAgent;

  /// A topic title: continue the link's topic with exactly this title, or start a new one.
  final String? topic;

  /// 32 hex: continue this topic (takes precedence over [topic]).
  final String? topicId;

  Json get fields => {'to': ?to, 'to_agent': ?toAgent, 'topic': ?topic, 'topic_id': ?topicId};

  @override
  bool operator ==(Object other) =>
      other is MessageAddress &&
      other.to == to &&
      other.toAgent == toAgent &&
      other.topic == topic &&
      other.topicId == topicId;

  @override
  int get hashCode => Object.hash(to, toAgent, topic, topicId);

  @override
  String toString() => 'MessageAddress($to${toAgent == null ? '' : ':$toAgent'}, topic ${topicId ?? topic})';
}

/// Maximum length of a JSON line the window sends (`MAX_LINE`).
const int maxLine = 256 * 1024;

/// Maximum length of a line the window reads from the daemon. Larger than [maxLine]: a `file_preview` reply carries
/// its PNG images inline as base64, and the PNG of one screenshot or a 1024-pixel logo is already more than 256 KiB
/// (CONTROL §1). Up to preview.8 the window refused such a reply as "line too long", and every picture larger than
/// that showed "Couldn't show the preview image". The daemon is this computer's own process; the bound only keeps a
/// broken one from growing the window's memory without limit.
const int maxReplyLine = 64 * 1024 * 1024;

/// A client request. [toString] never prints passwords, message texts or links (SPEC §13).
sealed class XRequest {
  const XRequest();

  /// The `cmd` value.
  String get cmd;

  /// Request fields without `cmd`.
  Json get fields;

  Json toJson() => {'cmd': cmd, ...fields};

  /// A dialog: the request may be followed by events and owner input (pairing) or by an event stream (subscribe).
  bool get isDialog => false;

  @override
  String toString() => 'XRequest::$cmd';
}

final class StatusRequest extends XRequest {
  const StatusRequest();
  @override
  String get cmd => 'status';
  @override
  Json get fields => const {};
}

final class InitRequest extends XRequest {
  const InitRequest(this.password);
  final String password;
  @override
  String get cmd => 'init';
  @override
  Json get fields => {'password': password};
}

/// Unlock the keystore with the password, or (v7, CONTROL §22.4) with the unlock slot of owner key [keyId]: [slotKey]
/// is base64 of its 32 bytes and [password] is then `""`.
final class UnlockRequest extends XRequest {
  const UnlockRequest(this.password, {this.keyId, this.slotKey});
  final String password;
  final String? keyId;
  final String? slotKey;
  @override
  String get cmd => 'unlock';
  @override
  Json get fields => {'password': password, 'key_id': ?keyId, 'slot_key': ?slotKey};
}

final class LockRequest extends XRequest {
  const LockRequest();
  @override
  String get cmd => 'lock';
  @override
  Json get fields => const {};
}

final class ContactsRequest extends XRequest {
  const ContactsRequest();
  @override
  String get cmd => 'contacts';
  @override
  Json get fields => const {};
}

final class SendRequest extends XRequest {
  const SendRequest({
    required this.contact,
    required this.text,
    this.waitMs = 2000,
    this.approvalId,
    this.address,
    this.urgent = false,
  });

  /// Contact label or a hex prefix of link_id.
  final String contact;
  final String text;

  /// How long to wait for the delivery confirmation, in ms (0: don't wait; the daemon caps it at 60 s).
  final int waitMs;

  /// An approved approval request for this same text (the secret scanner found a secret).
  final String? approvalId;

  /// v6: who the message is for and its topic; `null` sends no addressing fields (a v5 daemon rejects them).
  final MessageAddress? address;

  /// v7 (CONTROL §33, experimental): "Urgent: interrupt now", the owner's message to one agent of an own computer
  /// (`to: "agent"`, a contact at ∞). Sent only when set: an older daemon rejects the unknown field.
  final bool urgent;

  @override
  String get cmd => 'send';
  @override
  Json get fields => {
        'contact': contact,
        'text': text,
        'wait_ms': waitMs,
        'approval_id': ?approvalId,
        ...?address?.fields,
        if (urgent) 'urgent': true,
      };
}

/// Incoming messages: the daemon marks them read. The owner's UI reads history and the subscription and leaves `inbox`
/// to the CLI and agents (otherwise it would "eat" their unread messages).
final class InboxRequest extends XRequest {
  const InboxRequest({this.wait = false, this.timeoutMs, this.contact});
  final bool wait;
  final int? timeoutMs;
  final String? contact;
  @override
  String get cmd => 'inbox';
  @override
  Json get fields => {'wait': wait, 'timeout_ms': timeoutMs, 'contact': ?contact};
}

/// Invite (side A). With [follow] it is a dialog: `invite_created` → `sas` → `peer_entered_code` →
/// `need_input confirm`; without it, `invite_created` right away and confirmation later via [PairingConfirmRequest].
final class InviteRequest extends XRequest {
  const InviteRequest({
    required this.trust,
    required this.ttlSecs,
    required this.password,
    this.label,
    this.follow = true,
    this.autoConfirm = false,
  });

  /// Initial trust level 1–5.
  final int trust;
  final int ttlSecs;
  final String? label;

  /// Follow the invite over this connection.
  final bool follow;

  /// Owner password (Q-12a).
  final String password;

  /// Only for `antennad --allow-auto-confirm` (tests); a regular daemon replies `forbidden` (D-26).
  final bool autoConfirm;

  @override
  String get cmd => 'invite';
  @override
  Json get fields => {
        'trust': trust,
        'ttl_secs': ttlSecs,
        'label': label,
        'auto_confirm': autoConfirm,
        'follow': follow,
        'password': password,
      };
  @override
  bool get isDialog => follow;
}

/// Join by link (side B). Dialog: `need_input sas_code` → the owner enters the code as read out by A
/// (digits, the same emoji, or animal names).
final class JoinRequest extends XRequest {
  const JoinRequest({
    required this.link,
    required this.trust,
    required this.password,
    this.label,
    this.sasCode,
    this.connectTimeoutMs = 20000,
  });

  final String link;
  final int trust;
  final String? label;
  final String? sasCode;
  final int connectTimeoutMs;

  /// Owner password (Q-12a).
  final String password;

  @override
  String get cmd => 'join';
  @override
  Json get fields => {
        'link': link,
        'trust': trust,
        'label': label,
        'sas_code': sasCode,
        'connect_timeout_ms': connectTimeoutMs,
        'password': password,
      };
  @override
  bool get isDialog => true;
}

/// Invites held by the daemon (Q-7). The link (a secret) and the code come only with the correct owner password;
/// without it, only the ID, phase, label and expiry.
final class PairingsRequest extends XRequest {
  const PairingsRequest({this.wait = false, this.timeoutMs, this.password});
  final bool wait;
  final int? timeoutMs;
  final String? password;
  @override
  String get cmd => 'pairings';
  @override
  Json get fields => {'wait': wait, 'timeout_ms': timeoutMs, 'password': ?password};
}

/// Confirm the link on A (phase `needs_confirm`). [code] is what the owner TYPED, the code they read out and the
/// other person confirmed; the daemon checks it against the code of this particular invite. The client never fills in
/// the displayed code itself (CONTROL §6, PROTOCOL §15, F-4). Without [code] only when the invite offers
/// `confirm_without_code` (D-95): otherwise `code_required`, and `bad_request` from a daemon older than D-95.
final class PairingConfirmRequest extends XRequest {
  const PairingConfirmRequest({required this.id, required this.password, this.code});
  final String id;

  /// The code the owner typed; `null` sends no `code` (D-95: only when the invite offers `confirm_without_code`).
  final String? code;
  final String password;
  @override
  String get cmd => 'pairing_confirm';
  @override
  Json get fields => {'id': id, 'code': ?code, 'password': password};
}

/// Burn an invite.
final class PairingCancelRequest extends XRequest {
  const PairingCancelRequest({required this.id, required this.password});
  final String id;
  final String password;
  @override
  String get cmd => 'pairing_cancel';
  @override
  Json get fields => {'id': id, 'password': password};
}

/// Set a contact's trust level (this also changes the network mode: 1–2 are relay only).
final class TrustRequest extends XRequest {
  const TrustRequest({required this.contact, required this.level, required this.password});
  final String contact;
  final int level;
  final String password;
  @override
  String get cmd => 'trust';
  @override
  Json get fields => {'contact': contact, 'level': level, 'password': password};
}

/// Approval requests.
final class ApprovalsRequest extends XRequest {
  const ApprovalsRequest({this.all = false});

  /// Include both resolved and "silent" ones.
  final bool all;
  @override
  String get cmd => 'approvals';
  @override
  Json get fields => {'all': all};
}

/// Allow once. [fingerprint] (v7, CONTROL §22.1) is the request's fingerprint the owner was shown: the daemon refuses
/// a request whose fingerprint differs (`approval_mismatch`). A proof covers the request's text, so an approval with a
/// proof sends it; an older daemon rejects the field, so the password path leaves it out.
final class ApproveRequest extends XRequest {
  const ApproveRequest({required this.id, required this.password, this.fingerprint});
  final String id;
  final String password;
  final String? fingerprint;
  @override
  String get cmd => 'approve';
  @override
  Json get fields => {'id': id, 'password': password, 'fingerprint': ?fingerprint};
}

/// Deny; with [hour], also deny everything from this contact for the next hour. No password since D-84 (a refusal
/// only reduces what happens); [password] is only for daemons older than that, which still require it.
final class DenyRequest extends XRequest {
  const DenyRequest({required this.id, this.password, this.hour = false});
  final String id;
  final bool hour;
  final String? password;
  @override
  String get cmd => 'deny';
  @override
  Json get fields => {'id': id, 'hour': hour, 'password': ?password};
}

/// One request of [ApproveManyRequest]: its ID and the fingerprint the owner was shown (`ApprovalInfo.fingerprint`):
/// a request whose fingerprint differs fails alone with `approval_mismatch`.
final class ApproveItem {
  const ApproveItem(this.id, {this.fingerprint});
  final String id;
  final String? fingerprint;
  Json toJson() => {'id': id, 'fingerprint': ?fingerprint};
}

/// Approve several requests with one password (v6, CONTROL §20): the daemon checks the password once, then approves
/// each request exactly as `approve` does; each item succeeds or fails alone. ≤ 64 items.
final class ApproveManyRequest extends XRequest {
  const ApproveManyRequest({required this.items, required this.password});
  final List<ApproveItem> items;
  final String password;
  @override
  String get cmd => 'approve_many';
  @override
  Json get fields => {
        'items': [for (final i in items) i.toJson()],
        'password': password,
      };
}

/// Deny several requests (v6): like `deny`, no password (D-84). ≤ 64 IDs.
final class DenyManyRequest extends XRequest {
  const DenyManyRequest({required this.ids, this.hour = false});
  final List<String> ids;
  final bool hour;
  @override
  String get cmd => 'deny_many';
  @override
  Json get fields => {'ids': ids, 'hour': hour};
}

/// Change what an agent may read (v6): [everyone] lets it also read messages addressed to everyone and unaddressed
/// ones. Turning it on widens what the agent reads, so it needs the owner [password]; turning it off does not.
final class AgentSetRequest extends XRequest {
  const AgentSetRequest({required this.name, required this.everyone, this.password});
  final String name;
  final bool everyone;
  final String? password;
  @override
  String get cmd => 'agent_set';
  @override
  Json get fields => {'name': name, 'everyone': everyone, 'password': ?password};
}

/// The link's topics, most recent first (v6).
final class TopicsRequest extends XRequest {
  const TopicsRequest(this.contact);
  final String contact;
  @override
  String get cmd => 'topics';
  @override
  Json get fields => {'contact': contact};
}

/// Issue a session token to an agent (owner password). [localLevel] labels the local data the agent can see bypassing
/// the daemon (0–5, Q-15: the owner chooses, there is no default); [links] are the agent's links (labels), `null`
/// means all.
final class AgentAddRequest extends XRequest {
  const AgentAddRequest({
    required this.name,
    required this.localLevel,
    required this.password,
    this.links,
    this.tokenFile = false,
    this.everyone,
  });
  final String name;
  final int localLevel;
  final List<String>? links;
  final String password;

  /// preview.4: the daemon also writes the token to `<data-dir>/agents/<name>.token` (0600) and returns the path.
  /// Sent only when set: an older daemon rejects unknown fields.
  final bool tokenFile;

  /// v6 (CONTROL §20): the agent also reads messages addressed to everyone; `null` sends nothing (a v5 daemon rejects
  /// the field; a v6 daemon then defaults to `false`).
  final bool? everyone;
  @override
  String get cmd => 'agent_add';
  @override
  Json get fields => {
        'name': name,
        'links': links,
        'local_level': localLevel,
        'password': password,
        if (tokenFile) 'token_file': true,
        'everyone': ?everyone,
      };
}

/// A new token for an existing agent (owner password; CONTROL §4, `agent_token`): the old token stops working, the
/// agent keeps its links, data label and session. The reply is `agent_added`.
final class AgentTokenRequest extends XRequest {
  const AgentTokenRequest({required this.name, required this.password, this.tokenFile = false});
  final String name;
  final String password;

  /// preview.4: write the new token to the agent's token file too (the daemon rewrites an existing file anyway).
  final bool tokenFile;
  @override
  String get cmd => 'agent_token';
  @override
  Json get fields => {'name': name, 'password': password, if (tokenFile) 'token_file': true};
}

/// preview.4: whose messages the agent treats as tasks the owner authorized (owner password). [contacts] `null`: the
/// default (contacts at trust level 5); empty: nobody, every message is data.
final class AgentTasksRequest extends XRequest {
  const AgentTasksRequest({required this.name, required this.password, this.contacts});
  final String name;
  final List<String>? contacts;
  final String password;
  @override
  String get cmd => 'agent_tasks';
  @override
  Json get fields => {'name': name, 'contacts': contacts, 'password': password};
}

/// Revoke an agent's token.
final class AgentRemoveRequest extends XRequest {
  const AgentRemoveRequest({required this.name, required this.password});
  final String name;
  final String password;
  @override
  String get cmd => 'agent_remove';
  @override
  Json get fields => {'name': name, 'password': password};
}

/// The owner's agents and their sessions.
final class AgentListRequest extends XRequest {
  const AgentListRequest();
  @override
  String get cmd => 'agent_list';
  @override
  Json get fields => const {};
}

/// Audit log of actions taken on a contact's requests.
final class LogRequest extends XRequest {
  const LogRequest({required this.contact, this.limit});
  final String contact;
  final int? limit;
  @override
  String get cmd => 'log';
  @override
  Json get fields => {'contact': contact, 'limit': ?limit};
}

/// Link history in pages, newest first.
final class HistoryRequest extends XRequest {
  const HistoryRequest({required this.contact, this.before, this.limit, this.chat});
  final String contact;

  /// The `next_before` cursor of the previous page.
  final int? before;

  /// 1…500, default 50.
  final int? limit;

  /// v7 (CONTROL §26): only this chat of the link. Sent only when set: an older daemon rejects unknown fields.
  final ChatRef? chat;
  @override
  String get cmd => 'history';
  @override
  Json get fields => {'contact': contact, 'before': before, 'limit': limit, 'chat': ?chat?.toJson()};
}

/// Event subscription over one long-lived connection; there is no final `ok`.
final class SubscribeRequest extends XRequest {
  const SubscribeRequest();
  @override
  String get cmd => 'subscribe';
  @override
  Json get fields => const {};
  @override
  bool get isDialog => true;
}

/// Open an owner session with the password (v2, Q-14b). With [hold], the session lives while this connection is open:
/// a `session` event carries the token (`xos_…`) and there is no final reply; the token goes into `hello.session` of
/// this process's subsequent connections.
final class LoginRequest extends XRequest {
  const LoginRequest(this.password, {this.hold = true});
  final String password;
  final bool hold;
  @override
  String get cmd => 'login';
  @override
  Json get fields => {'password': password, 'hold': hold};
  @override
  bool get isDialog => hold;
}

/// Close our own owner session.
final class LogoutRequest extends XRequest {
  const LogoutRequest();
  @override
  String get cmd => 'logout';
  @override
  Json get fields => const {};
}

/// Mark the link's incoming messages read up to and including `upToSeq` (v2); with [ids] (v6, ≤ 500), also exactly
/// these messages (`upToSeq: 0` marks only them): a client that shows threads marks the thread it shows.
final class MarkReadRequest extends XRequest {
  const MarkReadRequest({required this.contact, required this.upToSeq, this.ids, this.chat});
  final String contact;
  final int upToSeq;
  final List<String>? ids;

  /// v7 (CONTROL §26): [upToSeq] marks only this chat's incoming messages.
  final ChatRef? chat;
  @override
  String get cmd => 'mark_read';
  @override
  Json get fields => {'contact': contact, 'up_to_seq': upToSeq, 'ids': ?ids, 'chat': ?chat?.toJson()};
}

/// History verification state (v2).
final class HistoryStatusRequest extends XRequest {
  const HistoryStatusRequest(this.contact);
  final String contact;
  @override
  String get cmd => 'history_status';
  @override
  Json get fields => {'contact': contact};
}

/// Verify history now; [accept] (with password) accepts a divergence, [repair] restores our copy.
final class VerifyRequest extends XRequest {
  const VerifyRequest({required this.contact, this.accept = false, this.repair = false, this.password});
  final String contact;
  final bool accept;
  final bool repair;
  final String? password;
  @override
  String get cmd => 'verify';
  @override
  Json get fields => {'contact': contact, 'accept': accept, 'repair': repair, 'password': ?password};
}

/// Delete a link (keys are wiped; history optionally).
final class RevokeRequest extends XRequest {
  const RevokeRequest({required this.contact, required this.password, this.deleteHistory = false});
  final String contact;
  final bool deleteHistory;
  final String password;
  @override
  String get cmd => 'revoke';
  @override
  Json get fields => {'contact': contact, 'delete_history': deleteHistory, 'password': password};
}

/// Rename a contact (the label is local to this node; owner session, no password).
final class RenameRequest extends XRequest {
  const RenameRequest({required this.contact, required this.label});
  final String contact;
  final String label;
  @override
  String get cmd => 'rename';
  @override
  Json get fields => {'contact': contact, 'label': label};
}

/// Rekey after a rollback (two codes, CONTROL §12): without [code], propose (only the side that rolled back); with
/// [code], the code read out by the contact's owner.
final class RekeyRequest extends XRequest {
  const RekeyRequest({required this.contact, required this.password, this.code});
  final String contact;
  final String? code;
  final String password;
  @override
  String get cmd => 'rekey';
  @override
  Json get fields => {'contact': contact, 'code': ?code, 'password': password};
}

/// Streams in progress on both sides, with their text so far (v4).
final class StreamsRequest extends XRequest {
  const StreamsRequest();
  @override
  String get cmd => 'streams';
  @override
  Json get fields => const {};
}

/// A secret environment variable for the agent (the value never reaches the logs).
final class SecretEnvVar {
  const SecretEnvVar(this.name, this.value);
  final String name;
  final String value;
  Json toJson() => {'name': name, 'value': value};
  @override
  String toString() => 'SecretEnvVar($name)';
}

/// Agent wake for a link (v4, CONTROL §16): [argv] is the program and its arguments, without a shell; owner password.
final class WakeSetRequest extends XRequest {
  const WakeSetRequest({
    required this.contact,
    required this.argv,
    required this.password,
    this.agent,
    this.timeoutSecs,
    this.allowHosts = const [],
    this.homeFiles,
    this.maxRunsPerHour,
    this.secretEnv = const [],
  });
  final String contact;
  final List<String> argv;
  final String password;
  final String? agent;
  final int? timeoutSecs;
  final List<String> allowHosts;

  /// `null`: the daemon's default (the agent CLI's sign-in files, if any); `[]`: nothing from the owner's $HOME.
  final List<String>? homeFiles;
  final int? maxRunsPerHour;
  final List<SecretEnvVar> secretEnv;
  @override
  String get cmd => 'wake_set';
  @override
  Json get fields => {
        'contact': contact,
        'argv': argv,
        'agent': ?agent,
        'timeout_secs': ?timeoutSecs,
        if (allowHosts.isNotEmpty) 'allow_hosts': allowHosts,
        'home_files': ?homeFiles,
        'max_runs_per_hour': ?maxRunsPerHour,
        if (secretEnv.isNotEmpty) 'secret_env': [for (final e in secretEnv) e.toJson()],
        'password': password,
      };
}

/// Wake rules and recent runs (v4).
final class WakeListRequest extends XRequest {
  const WakeListRequest();
  @override
  String get cmd => 'wake_list';
  @override
  Json get fields => const {};
}

/// Turn off wake for a link (v4): the rule and the dedicated agent are removed, a running run is stopped.
final class WakeOffRequest extends XRequest {
  const WakeOffRequest(this.contact);
  final String contact;
  @override
  String get cmd => 'wake_off';
  @override
  Json get fields => {'contact': contact};
}

/// LAN via mDNS (v5, CONTROL §18): turning it on needs the owner password; turning it off needs none (the safe
/// direction).
final class LanSetRequest extends XRequest {
  const LanSetRequest({required this.enabled, this.password});
  final bool enabled;
  final String? password;
  @override
  String get cmd => 'lan_set';
  @override
  Json get fields => {'enabled': enabled, 'password': ?password};
}

/// LAN state (v5).
final class LanStatusRequest extends XRequest {
  const LanStatusRequest();
  @override
  String get cmd => 'lan_status';
  @override
  Json get fields => const {};
}

/// Owner input during pairing.
sealed class XInput {
  const XInput();
  Json toJson();
}

/// Owner A's decision on the `invite` follow connection. "Yes" comes with the [code] the owner TYPED (the one they
/// read out and had confirmed; v2): a wrong code yields an `input_rejected` event and the invite stays alive. "Yes"
/// without a code only after `need_input confirm` said `confirm_without_code` (D-95); otherwise the daemon answers
/// `input_rejected` with `code_required` (or `bad_request` from a daemon older than D-95). "No" needs no code.
final class ConfirmInput extends XInput {
  const ConfirmInput(this.yes, {this.code});
  final bool yes;
  final String? code;
  @override
  Json toJson() => {
        'confirm': {'yes': yes, 'code': ?code},
      };
  @override
  String toString() => 'ConfirmInput($yes)';
}

/// The code owner B entered as read out by A: digits, the same emoji, or animal names.
final class SasCodeInput extends XInput {
  const SasCodeInput(this.code);
  final String code;
  @override
  Json toJson() => {
        'sas_code': {'code': code},
      };
  @override
  String toString() => 'SasCodeInput(<redacted>)';
}
