// SPDX-License-Identifier: AGPL-3.0-only
// Reply and event models of antenna_proto::control (crates/antenna-proto/src/control.rs, D-22).
// Parsing tolerates new fields: newer daemons (from slice 2 on) add fields and variants, and the client must not
// break.

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

part 'models_agent_stop.dart';
part 'models_approvals.dart';
part 'models_approvers.dart';
part 'models_chats.dart';
part 'models_escalations.dart';
part 'models_connections.dart';
part 'models_devices.dart';
part 'models_files.dart';
part 'models_local.dart';
part 'models_updates.dart';
part 'models_owner_keys.dart';
part 'models_resident.dart';
part 'models_pictures.dart';
part 'models_teams.dart';

typedef Json = Map<String, Object?>;

String _str(Json j, String k) {
  final v = j[k];
  if (v is String) return v;
  throw XProtocolException('field "$k": expected string, got ${v.runtimeType}');
}

String? _optStr(Json j, String k) {
  final v = j[k];
  if (v == null) return null;
  if (v is String) return v;
  throw XProtocolException('field "$k": expected string or null, got ${v.runtimeType}');
}

int _int(Json j, String k) {
  final v = j[k];
  if (v is int) return v;
  throw XProtocolException('field "$k": expected integer, got ${v.runtimeType}');
}

int? _optInt(Json j, String k) {
  final v = j[k];
  if (v == null) return null;
  if (v is int) return v;
  throw XProtocolException('field "$k": expected integer or null, got ${v.runtimeType}');
}

bool _bool(Json j, String k, {bool fallback = false}) {
  final v = j[k];
  if (v == null) return fallback;
  if (v is bool) return v;
  throw XProtocolException('field "$k": expected bool, got ${v.runtimeType}');
}

List<String> _strList(Json j, String k) {
  final v = j[k];
  if (v == null) return const [];
  if (v is List) return [for (final e in v) e is String ? e : throw XProtocolException('field "$k": expected strings')];
  throw XProtocolException('field "$k": expected list, got ${v.runtimeType}');
}

Json _obj(Json j, String k) {
  final v = j[k];
  if (v is Map<String, Object?>) return v;
  if (v == null) return const {};
  throw XProtocolException('field "$k": expected object, got ${v.runtimeType}');
}

/// The daemon's keystore state.
enum DaemonState {
  uninitialized,
  locked,
  unlocked,
  unknown;

  static DaemonState parse(String s) => switch (s) {
        'uninitialized' => DaemonState.uninitialized,
        'locked' => DaemonState.locked,
        'unlocked' => DaemonState.unlocked,
        _ => DaemonState.unknown,
      };
}

/// Reply to `hello`.
final class HelloOk {
  const HelloOk({
    required this.daemon,
    required this.protocol,
    required this.state,
    this.role,
    this.agent,
    this.forced = false,
    this.proto,
    this.session,
    this.raw = const {},
  });

  factory HelloOk.fromJson(Json j) => HelloOk(
        daemon: _str(j, 'daemon'),
        protocol: _str(j, 'protocol'),
        state: DaemonState.parse(_str(j, 'state')),
        role: _optStr(j, 'role'),
        agent: _optStr(j, 'agent'),
        forced: _bool(j, 'forced'),
        proto: _optStr(j, 'proto'),
        session: _optStr(j, 'session'),
        raw: j,
      );

  final String daemon;

  /// Network protocol version (`x/0` is a historical label, DECISIONS D-57).
  final String protocol;
  final DaemonState state;

  /// Effective role of the connection (`owner` / `agent`, v1). The owner's UI must check that it is `owner`.
  final String? role;

  /// Agent name, if the daemon assigned the agent role.
  final String? agent;

  /// The agent role was assigned by process tree (the client asked for owner).
  final bool forced;

  /// Control protocol version of the connection (`x-control/2`).
  final String? proto;

  /// Owner session of the connection (v2): `none` / `tty` / `parent` / `held`.
  final String? session;
  final Json raw;
}

/// Final reply `{"ok":{"type":…}}`.
sealed class Reply {
  const Reply();

  static Reply fromJson(Json j) {
    final type = _str(j, 'type');
    return switch (type) {
      'status' => StatusReply.fromJson(j),
      'done' => DoneReply(DaemonState.parse(_str(j, 'state'))),
      'linked' => LinkedReply.fromJson(j),
      'invite_created' => InviteCreatedReply(InviteInfo.fromJson(j)),
      'pairings' => PairingsReply([for (final i in _list(j, 'invites')) InviteInfo.fromJson(i)]),
      'contacts' => ContactsReply.fromJson(j),
      'sent' => SentReply.fromJson(j),
      'inbox' => InboxReply.fromJson(j),
      'history' => HistoryReply.fromJson(j),
      'approvals' => ApprovalsReply(
          [for (final a in _list(j, 'approvals')) ApprovalInfo.fromJson(a)],
          hiddenQuiet: _optInt(j, 'hidden_quiet') ?? 0,
        ),
      'approval' => ApprovalReply(ApprovalInfo.fromJson(j)),
      'log' => LogReply(_str(j, 'contact'), [for (final e in _list(j, 'entries')) ReceiptInfo.fromJson(e)]),
      'agents' => AgentsReply([for (final a in _list(j, 'agents')) AgentInfo.fromJson(a)]),
      'agent_added' => AgentAddedReply(name: _str(j, 'name'), token: _str(j, 'token'), tokenFile: _optStr(j, 'token_file')),
      'owner_session' => OwnerSessionReply(kind: _str(j, 'kind'), expiresMs: _int(j, 'expires_ms')),
      'history_status' => HistoryStatusReply(
          contact: _str(j, 'contact'),
          linkId: _str(j, 'link_id'),
          status: HistoryStatus.fromJson(_obj(j, 'status')),
        ),
      'revoked' => RevokedReply(
          contact: _str(j, 'contact'),
          linkId: _str(j, 'link_id'),
          historyDeleted: _bool(j, 'history_deleted'),
        ),
      'rekey' => RekeyReply(
          contact: _str(j, 'contact'),
          state: _str(j, 'state'),
          code: _optStr(j, 'code'),
          codeEmoji: _optStr(j, 'code_emoji'),
        ),
      'file' => FileReply(FileInfo.fromJson(j)),
      'files' => FilesReply([for (final f in _list(j, 'files')) FileInfo.fromJson(f)]),
      'file_preview' => FilePreviewReply(
          file: FileInfo.fromJson(_obj(j, 'file')),
          preview: j['preview'] is Map<String, Object?> ? FilePreview.fromJson(_obj(j, 'preview')) : null,
        ),
      'streams' => StreamsReply([for (final v in _list(j, 'streams')) StreamView.fromJson(v)]),
      'wake' => WakeReply(
          rules: [for (final r in _list(j, 'rules')) WakeRuleInfo.fromJson(r)],
          sandbox: _optStr(j, 'sandbox') ?? 'none',
          sandboxDetail: _optStr(j, 'sandbox_detail') ?? '',
        ),
      'lan' => LanReply.fromJson(j),
      'approvals_decided' => ApprovalsDecidedReply([for (final r in _list(j, 'results')) ApprovalResult.fromJson(r)]),
      'topics' => TopicsReply.fromJson(j),
      'chats' => ChatsReply.fromJson(j),
      'chat' => ChatReply(ChatInfo.fromJson(j)),
      'escalations' => EscalationsReply([for (final e in _list(j, 'escalations')) EscalationInfo.fromJson(e)]),
      'escalation' => EscalationReply(EscalationInfo.fromJson(j)),
      'file_requested' => FileRequestedReply(
          contact: _str(j, 'contact'),
          id: _str(j, 'id'),
          status: _str(j, 'status'),
        ),
      'local_models' => LocalModelsReply.fromJson(j),
      'local_model' => LocalModelReply(LocalModelInfo.fromJson(j)),
      'local_agent' => LocalAgentReply(LocalAgentInfo.fromJson(j)),
      'local_turn' => LocalTurnReply.fromJson(j),
      'local_history' => LocalHistoryReply.fromJson(j),
      'resident_session' => ResidentSessionReply(
          contact: _str(j, 'contact'),
          resident: ResidentInfo.fromJson(_obj(j, 'resident')),
        ),
      'resident_turn' => ResidentTurnReply.fromJson(j),
      'update_auto' => UpdateAutoReply(UpdateAutoInfo.fromJson(j)),
      'file_name' => FileNameCheck.fromJson(j),
      'file_save_dirs' => FileSaveDirsReply.fromJson(j),
      'file_allow' => FileAllowReply.fromJson(j),
      'owner_challenge' => OwnerChallengeReply.fromJson(j),
      'owner_key_added' => OwnerKeyAddedReply.fromJson(j),
      'owner_keys' => OwnerKeysReply.fromJson(j),
      'pictures' => PicturesReply.fromJson(j),
      'picture_photo' => PicturePhotoReply.fromJson(j),
      'teams' => TeamsReply([for (final t in _list(j, 'teams')) TeamInfo.fromJson(t)]),
      'team' => TeamReply(TeamInfo.fromJson(j)),
      'team_worker' => TeamWorkerReply(WorkerInfo.fromJson(j)),
      'task' => TaskReply(TaskInfo.fromJson(j)),
      'tasks' => TasksReply([for (final t in _list(j, 'tasks')) TaskInfo.fromJson(t)]),
      'task_diff' => TaskDiffReply.fromJson(j),
      'capacity' => CapacityReply.fromJson(j),
      'team_log' => TeamLogReply([for (final e in _list(j, 'entries')) TeamLogEntry.fromJson(e)]),
      'devices' => DevicesReply.fromJson(j),
      'device_challenge' => DeviceChallengeReply.fromJson(j),
      'device_decided' => DeviceDecidedReply.fromJson(j),
      'agent_connected' => AgentConnectedReply.fromJson(j),
      'agent_traffic' => AgentTrafficReply.fromJson(j),
      'approvers' => ApproversReply.fromJson(j),
      'agent_stopped' => AgentStoppedReply.fromJson(j),
      _ => UnknownReply(type, j),
    };
  }
}

List<Json> _list(Json j, String k) {
  final v = j[k];
  if (v == null) return const [];
  if (v is List) return [for (final e in v) e is Map<String, Object?> ? e : throw XProtocolException('field "$k": expected objects')];
  throw XProtocolException('field "$k": expected list, got ${v.runtimeType}');
}

/// `status`.
final class StatusReply extends Reply {
  const StatusReply({
    required this.state,
    required this.daemon,
    required this.protocol,
    required this.relay,
    this.links,
    this.updated,
  });

  factory StatusReply.fromJson(Json j) => StatusReply(
        state: DaemonState.parse(_str(j, 'state')),
        daemon: _str(j, 'daemon'),
        protocol: _str(j, 'protocol'),
        relay: _str(j, 'relay'),
        links: _optInt(j, 'links'),
        updated: j['updated'] is Map<String, Object?> ? UpdatedInfo.fromJson(_obj(j, 'updated')) : null,
      );

  final DaemonState state;
  final String daemon;
  final String protocol;

  /// `n0`, `disabled` or a URL.
  final String relay;

  /// Number of active links (only when unlocked).
  final int? links;

  /// This daemon process came up from an automatic update (v7, D-103): the window restores its Code mode agents.
  final UpdatedInfo? updated;
}

/// `init` / `unlock` / `lock`: the new state.
final class DoneReply extends Reply {
  const DoneReply(this.state);
  final DaemonState state;
}

/// Pairing finished: the link was created.
final class LinkedReply extends Reply {
  const LinkedReply({
    required this.contact,
    required this.linkId,
    required this.trust,
    required this.netMode,
    required this.kxGroup,
    required this.pairingMs,
  });

  factory LinkedReply.fromJson(Json j) => LinkedReply(
        contact: _str(j, 'contact'),
        linkId: _str(j, 'link_id'),
        trust: _int(j, 'trust'),
        netMode: _str(j, 'net_mode'),
        kxGroup: _str(j, 'kx_group'),
        pairingMs: _int(j, 'pairing_ms'),
      );

  final String contact;
  final String linkId;
  final int trust;
  final String netMode;

  /// TLS group negotiated during pairing (`X25519MLKEM768`).
  final String kxGroup;
  final int pairingMs;
}

/// E2E session facts from the libsignal state.
final class E2eInfo {
  const E2eInfo({this.sessionVersion, this.pqRatchet, this.lastRxVersion, this.lastRxPqLen});

  factory E2eInfo.fromJson(Json j) => E2eInfo(
        sessionVersion: _optInt(j, 'session_version'),
        pqRatchet: _optStr(j, 'pq_ratchet'),
        lastRxVersion: _optInt(j, 'last_rx_version'),
        lastRxPqLen: _optInt(j, 'last_rx_pq_len'),
      );

  /// 4 = PQXDH + SPQR (Triple Ratchet).
  final int? sessionVersion;

  /// SPQR state, for example `NegotiationComplete(V1)`.
  final String? pqRatchet;
  final int? lastRxVersion;

  /// Length of the SPQR part of the last received message.
  final int? lastRxPqLen;
}

/// Transport facts.
final class TransportInfo {
  const TransportInfo({
    required this.pairingKxGroup,
    this.lastKxGroup,
    required this.connected,
    this.lastPaths = const [],
    this.relay,
  });

  factory TransportInfo.fromJson(Json j) => TransportInfo(
        pairingKxGroup: _optStr(j, 'pairing_kx_group') ?? '',
        lastKxGroup: _optStr(j, 'last_kx_group'),
        connected: _bool(j, 'connected'),
        lastPaths: _strList(j, 'last_paths'),
        relay: j['relay'] is Map<String, Object?> ? HomeRelayInfo.fromJson(_obj(j, 'relay')) : null,
      );

  final String pairingKxGroup;
  final String? lastKxGroup;

  /// Whether there is currently a connection for this link.
  final bool connected;

  /// `relay:…` / `ip:…`.
  final List<String> lastPaths;

  /// preview.6: the link endpoint's home relay as iroh reports it; `null` when the node runs without a relay, the
  /// link's endpoint is not running, or the daemon is older.
  final HomeRelayInfo? relay;
}

/// The home relay of one link's endpoint (preview.6).
final class HomeRelayInfo {
  const HomeRelayInfo({required this.url, required this.connected, this.error});

  factory HomeRelayInfo.fromJson(Json j) =>
      HomeRelayInfo(url: _optStr(j, 'url') ?? '', connected: _bool(j, 'connected'), error: _optStr(j, 'error'));

  /// Empty while the endpoint has not chosen one yet.
  final String url;
  final bool connected;

  /// The most recent connection error (at most 200 characters), while not connected.
  final String? error;
}

/// A contact (owner's view).
final class ContactInfo {
  const ContactInfo({
    required this.label,
    required this.linkId,
    required this.trust,
    required this.netMode,
    required this.role,
    required this.createdMs,
    required this.peerEndpoint,
    required this.localEndpoint,
    this.localAddrs = const [],
    this.e2e = const E2eInfo(),
    required this.transport,
    this.outbox = 0,
    this.failed = 0,
    this.heads = const [],
    this.lamport = 0,
    this.presence = '',
    this.peerKind = '',
    this.agents = const [],
    this.peerAddressing = false,
    this.peerFileWithdraw = false,
    this.peerUrgent = false,
    this.unread = 0,
    this.rights,
    this.history,
    this.fileAllow = const [],
    this.saveDirs = const [],
    this.raw = const {},
  });

  factory ContactInfo.fromJson(Json j) => ContactInfo(
        label: _str(j, 'label'),
        linkId: _str(j, 'link_id'),
        trust: _int(j, 'trust'),
        netMode: _str(j, 'net_mode'),
        role: _str(j, 'role'),
        createdMs: _int(j, 'created_ms'),
        peerEndpoint: _str(j, 'peer_endpoint'),
        localEndpoint: _str(j, 'local_endpoint'),
        localAddrs: _strList(j, 'local_addrs'),
        e2e: E2eInfo.fromJson(_obj(j, 'e2e')),
        transport: TransportInfo.fromJson(_obj(j, 'transport')),
        outbox: _optInt(j, 'outbox') ?? 0,
        failed: _optInt(j, 'failed') ?? 0,
        heads: _strList(j, 'heads'),
        lamport: _optInt(j, 'lamport') ?? 0,
        presence: _optStr(j, 'presence') ?? '',
        peerKind: _optStr(j, 'peer_kind') ?? '',
        agents: [for (final a in _list(j, 'agents')) PeerAgent.fromJson(a)],
        peerAddressing: _bool(j, 'peer_addressing'),
        peerFileWithdraw: _bool(j, 'peer_file_withdraw'),
        peerUrgent: _bool(j, 'peer_urgent'),
        unread: _optInt(j, 'unread') ?? 0,
        rights: j['rights'] is Map<String, Object?> ? Rights.fromJson(_obj(j, 'rights')) : null,
        history: j['history'] is Map<String, Object?> ? HistoryStatus.fromJson(_obj(j, 'history')) : null,
        fileAllow: _strList(j, 'file_allow'),
        saveDirs: [for (final d in _list(j, 'save_dirs')) SaveDir.fromJson(d)],
        raw: j,
      );

  final String label;

  /// Link ID (hex, 64 characters).
  final String linkId;

  /// Local trust level 1–5 (SPEC §9).
  final int trust;

  /// `relay_only` / `direct`.
  final String netMode;

  /// `inviter` / `joiner`.
  final String role;
  final int createdMs;
  final String peerEndpoint;
  final String localEndpoint;
  final List<String> localAddrs;
  final E2eInfo e2e;
  final TransportInfo transport;

  /// Messages queued for sending.
  final int outbox;

  /// Outgoing messages rejected by the contact and dropped from the queue.
  final int failed;

  /// History heads (hex).
  final List<String> heads;
  final int lamport;

  /// Presence, subject to trust level (v1): `online` / `offline` for 3–5, `not_tracked` for 1–2 (SPEC §4, Q-8);
  /// empty from a v0 daemon.
  final String presence;

  /// Who is on the other side (v5, CONTROL §17): `human` / `agent` / `mixed` / `unknown` (the contact's node is older,
  /// or it has not yet announced agents nor written itself, as right after pairing). Empty from a daemon older than
  /// v1.
  final String peerKind;

  /// The contact's agents on this link (as announced by the contact; `revoked` means revoked). Names are contact data.
  final List<PeerAgent> agents;

  /// At least one active agent of the contact.
  List<PeerAgent> get activeAgents => agents.where((a) => a.state != 'revoked').toList();

  /// v6 (CONTROL §20): the contact's node understands addressing and topics (`addr/0`). Without it, the address and
  /// topic stay in this node's history only, and every agent of the contact may read the message.
  final bool peerAddressing;

  /// preview.5 (CONTROL §14): the contact's node deletes its pending copy when this node withdraws a file it sent
  /// (`file-withdraw/0`). Without it a withdrawal only stops serving the file.
  final bool peerFileWithdraw;

  /// v7 (CONTROL §33): the contact's node takes the owner's urgent messages (`urgent/0`): an own computer whose
  /// Antenna can interrupt the addressed agent's turn. Without it an urgent message goes as a normal one.
  final bool peerUrgent;

  /// Incoming messages not yet read by the owner (v2: `mark_read`).
  final int unread;

  /// Trust-level rights as reported by the daemon (v2).
  final Rights? rights;

  /// History verification state (v2).
  final HistoryStatus? history;

  /// v7 (D-130), an own computer at level 5: what of its programs and installers is saved without waiting
  /// (`executables`, `installers`, `.dmg`).
  final List<String> fileAllow;

  /// v7 (D-130), an own computer at level 5: where its files and its agents' files are saved.
  final List<SaveDir> saveDirs;

  /// The original JSON (fields from newer slices that the model does not know yet).
  final Json raw;

  ContactInfo copyWith({
    int? trust,
    String? netMode,
    String? presence,
    int? unread,
    HistoryStatus? history,
    String? label,
    String? peerKind,
    List<String>? fileAllow,
    List<SaveDir>? saveDirs,
  }) =>
      ContactInfo(
        label: label ?? this.label,
        linkId: linkId,
        trust: trust ?? this.trust,
        netMode: netMode ?? this.netMode,
        role: role,
        createdMs: createdMs,
        peerEndpoint: peerEndpoint,
        localEndpoint: localEndpoint,
        localAddrs: localAddrs,
        e2e: e2e,
        transport: transport,
        outbox: outbox,
        failed: failed,
        heads: heads,
        lamport: lamport,
        presence: presence ?? this.presence,
        peerKind: peerKind ?? this.peerKind,
        agents: agents,
        peerAddressing: peerAddressing,
        peerFileWithdraw: peerFileWithdraw,
        peerUrgent: peerUrgent,
        unread: unread ?? this.unread,
        rights: rights,
        history: history ?? this.history,
        fileAllow: fileAllow ?? this.fileAllow,
        saveDirs: saveDirs ?? this.saveDirs,
        raw: raw,
      );
}

/// `contacts`.
final class ContactsReply extends Reply {
  const ContactsReply(this.contacts);

  factory ContactsReply.fromJson(Json j) {
    final list = j['contacts'];
    if (list is! List) throw const XProtocolException('contacts: expected list');
    return ContactsReply([for (final c in list) ContactInfo.fromJson(c as Json)]);
  }

  final List<ContactInfo> contacts;
}

/// `send`.
final class SentReply extends Reply {
  const SentReply({
    required this.id,
    required this.status,
    required this.lamport,
    this.parents = const [],
    this.to,
    this.toAgent,
    this.topic,
    this.addressed,
    this.noAgent = false,
    this.peerAgents = const [],
    this.urgent,
  });

  factory SentReply.fromJson(Json j) => SentReply(
        id: _str(j, 'id'),
        status: _str(j, 'status'),
        lamport: _int(j, 'lamport'),
        parents: _strList(j, 'parents'),
        to: _optStr(j, 'to'),
        toAgent: _optStr(j, 'to_agent'),
        topic: TopicRef.parse(j['topic']),
        addressed: j['addressed'] is bool ? j['addressed']! as bool : null,
        noAgent: _bool(j, 'no_agent'),
        peerAgents: _strList(j, 'peer_agents'),
        urgent: j['urgent'] is bool ? j['urgent']! as bool : null,
      );

  final String id;

  /// `delivered` / `queued`.
  final String status;
  final int lamport;
  final List<String> parents;

  /// v6: what the daemon chose (CONTROL §20): `person` / `everyone` / `agent`, the agent's name, the topic.
  final String? to;
  final String? toAgent;
  final TopicRef? topic;

  /// v6: `false` when the contact's node does not understand addressing: the address stayed on this node only.
  final bool? addressed;

  /// v7 (CONTROL §26): the contact's node has no agent by the addressed name (nobody there reads the message).
  final bool noAgent;

  /// With [noAgent]: the agents the contact announced, the names one can address there.
  final List<String> peerAgents;

  /// v7 (CONTROL §33): present only when the message was sent as urgent: `true` the flag went with it; `false` the
  /// contact's Antenna cannot interrupt agents (no `urgent/0`), so it went as a normal message.
  final bool? urgent;

  bool get delivered => status == 'delivered';
}

/// An incoming message.
final class InboxMessage {
  const InboxMessage({
    required this.id,
    required this.contact,
    required this.linkId,
    required this.trust,
    required this.kind,
    required this.text,
    required this.ts,
    required this.receivedMs,
    required this.lamport,
    this.parents = const [],
  });

  factory InboxMessage.fromJson(Json j) => InboxMessage(
        id: _str(j, 'id'),
        contact: _str(j, 'contact'),
        linkId: _str(j, 'link_id'),
        trust: _int(j, 'trust'),
        kind: _str(j, 'kind'),
        text: _str(j, 'text'),
        ts: _int(j, 'ts'),
        receivedMs: _int(j, 'received_ms'),
        lamport: _int(j, 'lamport'),
        parents: _strList(j, 'parents'),
      );

  final String id;
  final String contact;
  final String linkId;
  final int trust;
  final String kind;
  final String text;

  /// Sender's timestamp, Unix ms.
  final int ts;

  /// When received, Unix ms.
  final int receivedMs;
  final int lamport;
  final List<String> parents;
}

/// `inbox`: unread messages (the daemon marks them read).
final class InboxReply extends Reply {
  const InboxReply(this.messages);

  factory InboxReply.fromJson(Json j) {
    final list = j['messages'];
    if (list is! List) throw const XProtocolException('inbox: expected list');
    return InboxReply([for (final m in list) InboxMessage.fromJson(m as Json)]);
  }

  final List<InboxMessage> messages;
}

/// A reply the client does not know yet (a newer daemon slice).
final class UnknownReply extends Reply {
  const UnknownReply(this.type, this.raw);
  final String type;
  final Json raw;
}

/// An event during a request `{"event":{"kind":…}}`.
sealed class XEvent {
  const XEvent();

  static XEvent fromJson(Json j) {
    final kind = _str(j, 'kind');
    return switch (kind) {
      'invite_created' => InviteCreated.fromJson(j),
      'attempt_failed' => AttemptFailed(
          attempts: _int(j, 'attempts'),
          max: _int(j, 'max'),
          reason: _str(j, 'reason'),
        ),
      'sas' => SasEvent(code: _str(j, 'code'), emoji: _optStr(j, 'emoji')),
      'peer_entered_code' => const PeerEnteredCode(),
      'need_input' => NeedInput(_str(j, 'what'), confirmWithoutCode: _bool(j, 'confirm_without_code')),
      'waiting' => Waiting(_str(j, 'what')),
      'subscribed' => Subscribed(proto: _str(j, 'proto'), role: _str(j, 'role')),
      'message' => MessageEvent(
          contact: _str(j, 'contact'),
          linkId: _str(j, 'link_id'),
          message: HistoryItem.fromJson(_obj(j, 'message')),
        ),
      'message_status' => MessageStatusEvent(
          contact: _str(j, 'contact'),
          linkId: _str(j, 'link_id'),
          id: _str(j, 'id'),
          status: _str(j, 'status'),
        ),
      'contact' => ContactEvent(ContactSummary.fromJson(_obj(j, 'contact'))),
      'invite' => InviteEvent(InviteInfo.fromJson(_obj(j, 'invite'))),
      'approval' => ApprovalEvent(ApprovalInfo.fromJson(_obj(j, 'approval'))),
      'approval_resolved' => ApprovalResolvedEvent.fromJson(j),
      'lagged' => Lagged(_int(j, 'missed')),
      'history' => HistoryEvent(
          contact: _str(j, 'contact'),
          linkId: _str(j, 'link_id'),
          status: HistoryStatus.fromJson(_obj(j, 'status')),
        ),
      'input_rejected' => InputRejected(what: _str(j, 'what'), code: _str(j, 'code'), message: _optStr(j, 'message') ?? ''),
      'session' => SessionEvent(token: _str(j, 'token'), mode: _optStr(j, 'mode') ?? 'held'),
      'rekey' => RekeyEvent(contact: _str(j, 'contact'), state: _str(j, 'state')),
      'message_stream' => MessageStreamEvent.fromJson(j),
      'stream_started' => StreamStartedEvent(
          streamId: _str(j, 'stream_id'),
          live: _bool(j, 'live'),
          reason: _optStr(j, 'reason'),
        ),
      'wake' => WakeEvent(
          contact: _str(j, 'contact'),
          linkId: _str(j, 'link_id'),
          agent: _optStr(j, 'agent') ?? '',
          runId: _optStr(j, 'run_id') ?? '',
          state: _str(j, 'state'),
          detail: _optStr(j, 'detail') ?? '',
        ),
      'file' => FileEvent(
          contact: _str(j, 'contact'),
          linkId: _str(j, 'link_id'),
          file: FileInfo.fromJson(_obj(j, 'file')),
        ),
      'agent' => AgentEvent(name: _str(j, 'name'), change: _optStr(j, 'change') ?? '', by: _optStr(j, 'by')),
      'local_delta' => LocalDeltaEvent(
          agent: _str(j, 'agent'),
          turn: _optInt(j, 'turn') ?? 0,
          delta: _optStr(j, 'delta') ?? '',
          activity: _optStr(j, 'activity'),
        ),
      'resident_delta' => ResidentDeltaEvent(
          contact: _str(j, 'contact'),
          turn: _optInt(j, 'turn') ?? 0,
          delta: _optStr(j, 'delta') ?? '',
          activity: _optStr(j, 'activity'),
        ),
      'chat' => ChatEvent(ChatInfo.fromJson(j)),
      'escalation' => EscalationEvent(EscalationInfo.fromJson(j)),
      'picture' => PictureEvent(PictureEntry.fromJson(j)),
      'local_model' => LocalModelEvent(LocalModelInfo.fromJson(j)),
      'local_agent' => LocalAgentEvent(LocalAgentInfo.fromJson(j)),
      'update_auto' => UpdateAutoEvent(
          state: _str(j, 'state'),
          version: _optStr(j, 'version') ?? '',
          source: _optStr(j, 'source') ?? '',
          contact: _optStr(j, 'contact'),
          atMs: _optInt(j, 'at_ms'),
          reason: _optStr(j, 'reason'),
        ),
      'device' => DeviceEvent(
          contact: _optStr(j, 'contact') ?? '',
          linkId: _optStr(j, 'link_id') ?? '',
          change: _optStr(j, 'change') ?? '',
        ),
      'message_fact' => MessageFactEvent(
          contact: _str(j, 'contact'),
          id: _optStr(j, 'id') ?? '',
          trust: _optInt(j, 'trust') ?? 0,
          chars: _optInt(j, 'chars') ?? 0,
          receivedMs: _optInt(j, 'received_ms'),
          urgent: _bool(j, 'urgent'),
        ),
      'team' => TeamEvent.fromJson(j),
      'worker_output' => WorkerOutputEvent.fromJson(j),
      'approval_to_answer' => ApprovalToAnswerEvent.fromJson(j),
      _ => UnknownEvent(kind, j),
    };
  }
}

/// Invite created: the link (contains a secret!), expiry, level, network mode.
final class InviteCreated extends XEvent {
  const InviteCreated(
      {required this.link, required this.expiresMs, required this.trust, required this.netMode, this.id, this.linkApp});

  factory InviteCreated.fromJson(Json j) => InviteCreated(
        link: _str(j, 'link'),
        linkApp: _optStr(j, 'link_app'),
        expiresMs: _int(j, 'expires_ms'),
        trust: _int(j, 'trust'),
        netMode: _str(j, 'net_mode'),
        id: _optStr(j, 'id'),
      );

  /// v5: the web address `https://antenna.contact/#…`, shown to people and in the QR code (an older daemon sends
  /// `x://pair#…`).
  final String link;

  /// v5: the same link as `antenna://pair#…`, to open in the app and for `0.1.0-preview.1` nodes.
  final String? linkApp;
  final int expiresMs;
  final int trust;
  final String netMode;

  /// Invite ID in the daemon (slice 2, Q-7); absent in slice 1.
  final String? id;

  @override
  String toString() => 'InviteCreated(trust $trust, $netMode, link <redacted>)';
}

/// A failed join attempt.
final class AttemptFailed extends XEvent {
  const AttemptFailed({required this.attempts, required this.max, required this.reason});
  final int attempts;
  final int max;
  final String reason;
}

/// The verification code (SAS) on A.
final class SasEvent extends XEvent {
  const SasEvent({required this.code, this.emoji});

  /// 6 digits.
  final String code;

  /// The same code as emoji, only if the daemon provides it (Q-6, slice 2).
  final String? emoji;

  @override
  String toString() => 'SasEvent(<redacted>)';
}

/// B entered the correct code (seen on A). This alone does not enable the link.
final class PeerEnteredCode extends XEvent {
  const PeerEnteredCode();
}

/// Owner input needed: `confirm` (on A) or `sas_code` (on B).
final class NeedInput extends XEvent {
  const NeedInput(this.what, {this.confirmWithoutCode = false});
  final String what;

  /// x-control/6 (D-95), with `confirm`: the daemon accepts "yes" without the code (the joiner entered the code
  /// correctly and no other invite of this node showed a code meanwhile). Absent from older daemons.
  final bool confirmWithoutCode;

  bool get isConfirm => what == 'confirm';
  bool get isSasCode => what == 'sas_code';
}

/// Waiting for the other side.
final class Waiting extends XEvent {
  const Waiting(this.what);
  final String what;
}

/// An event the client does not know yet.
/// preview.4: one of the owner's agents changed (`bound`: its token was bound to a process; `token`, `added`,
/// `removed`, `tasks`); the window reads `agent_list` again.
final class AgentEvent extends XEvent {
  const AgentEvent({required this.name, required this.change, this.by});
  final String name;

  /// `added` / `token` / `bound` / `refused` / `removed` / `approver`; v7 `stopped` (CONTROL §33: the agent and its
  /// processes were stopped).
  final String change;

  /// With `stopped`: `owner` (stopped on this computer) or the label of the own computer that asked.
  final String? by;
}

final class UnknownEvent extends XEvent {
  const UnknownEvent(this.kind, this.raw);
  final String kind;
  final Json raw;
}

// x-control/1 (slice 2): invites in the daemon, history, subscription, approvals, audit log.

/// An invite held by the daemon (Q-7). The link contains a secret: the daemon returns it and the code only with the
/// owner password.
final class InviteInfo {
  const InviteInfo({
    required this.id,
    required this.link,
    this.linkApp,
    required this.trust,
    this.label,
    required this.netMode,
    required this.createdMs,
    required this.expiresMs,
    required this.phase,
    this.sas,
    this.sasEmoji,
    this.attempts = 0,
    this.result,
    this.confirmWithoutCode = false,
  });

  factory InviteInfo.fromJson(Json j) => InviteInfo(
        id: _str(j, 'id'),
        link: _str(j, 'link'),
        linkApp: _optStr(j, 'link_app'),
        trust: _int(j, 'trust'),
        label: _optStr(j, 'label'),
        netMode: _str(j, 'net_mode'),
        createdMs: _int(j, 'created_ms'),
        expiresMs: _int(j, 'expires_ms'),
        phase: _str(j, 'phase'),
        sas: _optStr(j, 'sas'),
        sasEmoji: _optStr(j, 'sas_emoji'),
        attempts: _optInt(j, 'attempts') ?? 0,
        result: _optStr(j, 'result'),
        confirmWithoutCode: _bool(j, 'confirm_without_code'),
      );

  final String id;
  final String link;

  /// v5: `antenna://pair#…` (the app, preview.1 nodes); only with the password.
  final String? linkApp;
  final int trust;
  final String? label;
  final String netMode;
  final int createdMs;
  final int expiresMs;

  /// `waiting` → `code_ready` → `peer_entered_code` → `needs_confirm` → `finishing` → `linked` / `failed`.
  final String phase;
  final String? sas;
  final String? sasEmoji;
  final int attempts;

  /// Outcome: the contact label or an error code.
  final String? result;

  /// x-control/6 (D-95): in `needs_confirm`, the daemon accepts `pairing_confirm` without the code (with the
  /// password). Absent (false) from older daemons, and when another invite of this node showed a code at the same
  /// time (formal model F-4): the owner then types the code.
  final bool confirmWithoutCode;

  bool get needsConfirm => phase == 'needs_confirm';
  bool get finished => phase == 'linked' || phase == 'failed';

  /// The link and code are revealed: a `pairings` reply with the password (subscription events never carry them).
  bool get revealed => link.isNotEmpty;

  /// The new state from an event, keeping the link and code obtained earlier with the password.
  InviteInfo mergedOver(InviteInfo? old) => old == null || revealed
      ? this
      : InviteInfo(
          id: id,
          link: old.link,
          linkApp: old.linkApp,
          trust: trust,
          label: label,
          netMode: netMode,
          createdMs: createdMs,
          expiresMs: expiresMs,
          phase: phase,
          sas: sas ?? old.sas,
          sasEmoji: sasEmoji ?? old.sasEmoji,
          attempts: attempts,
          result: result,
          confirmWithoutCode: confirmWithoutCode,
        );

  @override
  String toString() => 'InviteInfo($id, $phase, link <redacted>)';
}

/// Invite created without following (`follow: false`).
final class InviteCreatedReply extends Reply {
  const InviteCreatedReply(this.invite);
  final InviteInfo invite;
}

/// `pairings`.
final class PairingsReply extends Reply {
  const PairingsReply(this.invites);
  final List<InviteInfo> invites;
}

/// A message in the link history (v1).
final class HistoryItem {
  const HistoryItem({
    required this.seq,
    required this.id,
    required this.direction,
    required this.kind,
    required this.text,
    required this.ts,
    required this.localMs,
    required this.lamport,
    required this.status,
    this.receipt,
    this.viaAgent,
    this.to,
    this.toAgent,
    this.topic,
    this.unread = false,
    this.noAgent = false,
    this.urgent = false,
  });

  factory HistoryItem.fromJson(Json j) => HistoryItem(
        seq: _int(j, 'seq'),
        id: _str(j, 'id'),
        direction: _str(j, 'direction'),
        kind: _str(j, 'kind'),
        text: _str(j, 'text'),
        ts: _int(j, 'ts'),
        localMs: _int(j, 'local_ms'),
        lamport: _int(j, 'lamport'),
        status: _str(j, 'status'),
        receipt: j['receipt'] is Map<String, Object?> ? ReceiptInfo.fromJson(_obj(j, 'receipt')) : null,
        viaAgent: _optStr(j, 'via_agent'),
        to: _optStr(j, 'to'),
        toAgent: _optStr(j, 'to_agent'),
        topic: TopicRef.parse(j['topic']),
        unread: _bool(j, 'unread'),
        noAgent: _bool(j, 'no_agent'),
        urgent: _bool(j, 'urgent'),
      );

  /// Local sequence number (the pagination cursor).
  final int seq;
  final String id;

  /// `in` / `out`.
  final String direction;
  final String kind;
  final String text;

  /// Author's timestamp, Unix ms.
  final int ts;

  /// Incoming: when received; outgoing: when created.
  final int localMs;
  final int lamport;

  /// Incoming: `received`; outgoing: `queued` / `delivered` / `failed`.
  final String status;

  /// For `kind = receipt` (v2): a receipt of an action taken on the contact's request (SPEC §9).
  final ReceiptInfo? receipt;

  /// v5 (CONTROL §17): incoming, the contact's agent; outgoing, our own agent; absent, the owner wrote it.
  final String? viaAgent;

  /// v6 (CONTROL §20): who the message is for, `person` / `everyone` / `agent`; absent, no address (from an older
  /// node, or written before v6).
  final String? to;

  /// With `to: "agent"`: outgoing, the contact's agent; incoming, this side's agent.
  final String? toAgent;

  /// v6: the topic the message belongs to.
  final TopicRef? topic;

  /// v6 (incoming, owner): not read by the owner yet.
  final bool unread;

  /// v7 (outgoing, CONTROL §26): the contact's node has no agent by the addressed name, so nobody there reads it.
  final bool noAgent;

  /// v7 (CONTROL §33): outgoing, sent with the urgent flag; incoming, the daemon honoured it (the owner's own message
  /// from an own computer at ∞, signed, fresh, to one of this node's agents, at most one per agent per 30 s). Only
  /// this verdict of the daemon makes a message urgent in the window, never the text or a contact's word.
  final bool urgent;

  bool get outgoing => direction == 'out';
  bool get isReceipt => kind == 'receipt';

  /// The same message with another read state (the daemon's `mark_read`, tests).
  HistoryItem withUnread(bool value) => HistoryItem(
        seq: seq,
        id: id,
        direction: direction,
        kind: kind,
        text: text,
        ts: ts,
        localMs: localMs,
        lamport: lamport,
        status: status,
        receipt: receipt,
        viaAgent: viaAgent,
        to: to,
        toAgent: toAgent,
        topic: topic,
        unread: value,
        noAgent: noAgent,
        urgent: urgent,
      );
}

/// A message's topic (v6): the ID (32 hex) and the title.
final class TopicRef {
  const TopicRef({required this.id, required this.title});

  /// `{id, title}`; a bare string (a title without an ID) is tolerated, anything else is no topic.
  static TopicRef? parse(Object? v) => switch (v) {
        {'id': final String id, 'title': final String title} => TopicRef(id: id, title: title),
        {'title': final String title} => TopicRef(id: '', title: title),
        final String title when title.isNotEmpty => TopicRef(id: '', title: title),
        _ => null,
      };

  final String id;

  /// The topic's title: contact data when the contact started it (plain text, no markup).
  final String title;

  @override
  bool operator ==(Object other) => other is TopicRef && other.id == id && other.title == title;

  @override
  int get hashCode => Object.hash(id, title);
}

/// A link's topic (v6, `topics`): most recent first.
final class TopicInfo {
  const TopicInfo({required this.id, required this.title, this.count = 0, this.lastSeq = 0, this.lastMs = 0});

  factory TopicInfo.fromJson(Json j) => TopicInfo(
        id: _str(j, 'id'),
        title: _str(j, 'title'),
        count: _optInt(j, 'count') ?? 0,
        lastSeq: _optInt(j, 'last_seq') ?? 0,
        lastMs: _optInt(j, 'last_ms') ?? 0,
      );

  final String id;

  /// The title of the topic's latest message.
  final String title;
  final int count;
  final int lastSeq;
  final int lastMs;

  TopicRef get ref => TopicRef(id: id, title: title);
}

/// `topics` (v6).
final class TopicsReply extends Reply {
  const TopicsReply({required this.contact, required this.linkId, required this.topics});

  factory TopicsReply.fromJson(Json j) => TopicsReply(
        contact: _str(j, 'contact'),
        linkId: _str(j, 'link_id'),
        topics: [for (final t in _list(j, 'topics')) TopicInfo.fromJson(t)],
      );

  final String contact;
  final String linkId;
  final List<TopicInfo> topics;
}

/// A history page: messages in ascending `seq`; [nextBefore] is the cursor of the older page.
final class HistoryReply extends Reply {
  const HistoryReply({required this.contact, required this.linkId, required this.messages, this.nextBefore});

  factory HistoryReply.fromJson(Json j) => HistoryReply(
        contact: _str(j, 'contact'),
        linkId: _str(j, 'link_id'),
        messages: [for (final m in _list(j, 'messages')) HistoryItem.fromJson(m)],
        nextBefore: _optInt(j, 'next_before'),
      );

  final String contact;
  final String linkId;
  final List<HistoryItem> messages;

  /// `null` means this is the start of the history.
  final int? nextBefore;
}

/// An audit log entry (SPEC §9).
final class ReceiptInfo {
  const ReceiptInfo({
    required this.seq,
    required this.ts,
    required this.actor,
    required this.action,
    required this.decision,
    required this.reason,
    this.messageId,
    this.approvalId,
    this.source = '',
    this.author = '',
    this.refs = const [],
    this.nameNumber,
    this.why,
    this.rules = const [],
  });

  factory ReceiptInfo.fromJson(Json j) => ReceiptInfo(
        seq: _optInt(j, 'seq') ?? 0,
        ts: _optInt(j, 'ts') ?? 0,
        actor: _str(j, 'actor'),
        action: _str(j, 'action'),
        decision: _str(j, 'decision'),
        reason: _optStr(j, 'reason') ?? '',
        messageId: _optStr(j, 'message_id'),
        approvalId: _optStr(j, 'approval_id'),
        source: _optStr(j, 'source') ?? '',
        author: _optStr(j, 'author') ?? '',
        refs: _strList(j, 'refs'),
        nameNumber: _optInt(j, 'name_number'),
        why: _optStr(j, 'why'),
        rules: _strList(j, 'rules'),
      );

  final int seq;
  final int ts;

  /// Agent or `owner`.
  final String actor;
  final String action;

  /// `allowed` / `approval_required` / `approved` / `denied` / `rate_limited` / …
  final String decision;
  final String reason;
  final String? messageId;
  final String? approvalId;

  /// v2: `dag` is a signed receipt in the shared history (both sides see it), `local` exists only on this node.
  final String source;

  /// For `dag`: `me` is an action of this node, `contact` of the contact's node.
  final String author;

  /// For `dag`: the messages it refers to (hex).
  final List<String> refs;

  /// v7 (D-128), a contact's `accept_file` / `accepted`: the offered name was taken in the contact's folder, so the
  /// file was saved as `<stem> (n).<ext>` with this `n` ([numberedFileName]).
  final int? nameNumber;

  /// v7 (D-129), a contact's `check_file` / `held` or `reject_file` / `denied` about our file: why its node holds or
  /// blocked it, from a closed vocabulary (`threat`, `executable`, `installer`, `uninspected`, `check_failed`,
  /// `review`, `not_saved`; blocked: `threat`, `damaged`, `limit`). Absent from an older node.
  final String? why;

  /// v7 (D-129): with [why], the rules of the contact's check that matched (finding codes, never file content).
  final List<String> rules;
}

final class LogReply extends Reply {
  const LogReply(this.contact, this.entries);
  final String contact;
  final List<ReceiptInfo> entries;
}

/// An agent of the owner (owner's view): only what the UI needs.
final class AgentInfo {
  const AgentInfo({
    required this.name,
    required this.createdMs,
    this.ceiling,
    this.links,
    this.boundTo,
    this.localLevel,
    this.everyone,
    this.boundPid,
    this.boundComm,
    this.boundAlive,
    this.lastSeenMs,
    this.mcpProcesses,
    this.tokenFile,
    this.tasksFrom,
    this.tasksFromDefault = true,
    this.escalateTo,
    this.refusedPid,
    this.refusedComm,
    this.refusedMs,
    this.refusedAlive,
    this.localModel,
    this.raw = const {},
  });

  factory AgentInfo.fromJson(Json j) {
    final s = _obj(j, 'session');
    final links = s['links'];
    final tasks = s['tasks_from'];
    final alive = s['bound_alive'];
    final refusedAlive = s['refused_alive'];
    return AgentInfo(
      name: _str(j, 'name'),
      createdMs: _int(j, 'created_ms'),
      ceiling: _optInt(s, 'ceiling'),
      links: links is List ? [for (final l in links) '$l'] : null,
      boundTo: _optStr(s, 'bound_to'),
      localLevel: _optInt(s, 'baseline_level'),
      everyone: j['everyone'] is bool ? j['everyone']! as bool : null,
      boundPid: _optInt(s, 'bound_pid'),
      boundComm: _optStr(s, 'bound_comm'),
      boundAlive: alive is bool ? alive : null,
      lastSeenMs: _optInt(s, 'last_seen_ms'),
      mcpProcesses: _optInt(s, 'mcp_processes'),
      tokenFile: _optStr(s, 'token_file'),
      tasksFrom: tasks is List ? [for (final t in tasks) '$t'] : null,
      tasksFromDefault: _bool(s, 'tasks_from_default', fallback: true),
      escalateTo: _optStr(s, 'escalate_to'),
      refusedPid: _optInt(s, 'refused_pid'),
      refusedComm: _optStr(s, 'refused_comm'),
      refusedMs: _optInt(s, 'refused_ms'),
      refusedAlive: refusedAlive is bool ? refusedAlive : null,
      localModel: _optStr(j, 'local_model'),
      raw: j,
    );
  }

  final String name;
  final int createdMs;

  /// The session's rights ceiling (taint); `null` means the session is clean.
  final int? ceiling;

  /// The agent's links; `null` means all.
  final List<String>? links;

  /// `<pid> <comm>`, with ` (ended)` once that process is gone (every daemon since slice 2).
  final String? boundTo;

  /// Base local-data label set by the owner (`--local-level`, Q-15).
  final int? localLevel;

  /// v6 (CONTROL §20): the agent also reads messages addressed to everyone and unaddressed ones; `null` from an older
  /// daemon (every agent read everything then).
  final bool? everyone;
  /// preview.4: the structured form of [boundTo]: the process ID, its name and whether it still runs.
  final int? boundPid;
  final String? boundComm;
  final bool? boundAlive;

  /// preview.4: the agent's last request since the daemon started (Unix ms); `null`: none yet.
  final int? lastSeenMs;

  /// D-97: how many `antenna mcp` processes of this agent run now (an app such as Claude Desktop starts one for its
  /// chats and more for other kinds of sessions; all of them are this agent). `null`: none, or an older daemon.
  final int? mcpProcesses;

  /// preview.4: the agent's token file (`<data-dir>/agents/<name>.token`), when the daemon wrote one.
  final String? tokenFile;

  /// preview.4: the contacts whose messages this agent treats as tasks the owner authorized (`null`: an older daemon
  /// that does not say); [tasksFromDefault]: the set follows the default (contacts at trust level 5).
  final List<String>? tasksFrom;
  final bool tasksFromDefault;

  /// v7 (D-118): the contact the agent's questions go to; `null`: the owner (or an older daemon).
  final String? escalateTo;

  /// preview.6: the last MCP host the daemon refused with `token_bound` because this agent's token is bound to
  /// another app (kept in memory since the daemon started): its PID, name, when, and whether it still runs. `null`
  /// from an older daemon, or when nothing was refused.
  final int? refusedPid;
  final String? refusedComm;
  final int? refusedMs;
  final bool? refusedAlive;

  /// v7 (CONTROL §24): a local agent, the catalog ID of the model the daemon runs it on. It has no token file; the
  /// window shows it with the local models, not with the agents that connect themselves.
  final String? localModel;
  final Json raw;

  /// The process the token is bound to, from the structured fields or parsed from [boundTo] (older daemons).
  ({int pid, String comm, bool alive})? get binding {
    if (boundPid case final pid?) return (pid: pid, comm: boundComm ?? '', alive: boundAlive ?? true);
    final b = boundTo;
    if (b == null) return null;
    final ended = b.endsWith(' (ended)');
    final core = ended ? b.substring(0, b.length - ' (ended)'.length) : b;
    final sp = core.indexOf(' ');
    final pid = int.tryParse(sp < 0 ? core : core.substring(0, sp));
    if (pid == null) return null;
    return (pid: pid, comm: sp < 0 ? '' : core.substring(sp + 1), alive: !ended);
  }
}

/// Agent created: the token is shown ONCE (the daemon stores only its hash, D-27).
final class AgentAddedReply extends Reply {
  const AgentAddedReply({required this.name, required this.token, this.tokenFile});
  final String name;
  final String token;

  /// preview.4: where the daemon wrote the token (asked with `token_file`). App configs carry this path, never the
  /// token itself.
  final String? tokenFile;

  @override
  String toString() => 'AgentAddedReply($name, token <redacted>)';
}

final class AgentsReply extends Reply {
  const AgentsReply(this.agents);
  final List<AgentInfo> agents;
}

/// Contact summary in subscription events.
final class ContactSummary {
  const ContactSummary({
    required this.contact,
    required this.linkId,
    required this.trust,
    required this.netMode,
    required this.presence,
    this.peerKind,
  });

  factory ContactSummary.fromJson(Json j) => ContactSummary(
        contact: _str(j, 'contact'),
        linkId: _str(j, 'link_id'),
        trust: _int(j, 'trust'),
        netMode: _str(j, 'net_mode'),
        presence: _optStr(j, 'presence') ?? '',
        peerKind: _optStr(j, 'peer_kind'),
      );

  final String contact;
  final String linkId;
  final int trust;
  final String netMode;
  final String presence;

  /// v5: sent when it changes (the contact announced an agent or wrote for the first time themselves).
  final String? peerKind;
}

/// Subscription opened.
final class Subscribed extends XEvent {
  const Subscribed({required this.proto, required this.role});
  final String proto;
  final String role;
}

/// A new message in the link history (incoming or outgoing).
final class MessageEvent extends XEvent {
  const MessageEvent({required this.contact, required this.linkId, required this.message});
  final String contact;
  final String linkId;
  final HistoryItem message;
}

/// Delivery status of an outgoing message changed: `delivered` / `failed`.
final class MessageStatusEvent extends XEvent {
  const MessageStatusEvent({required this.contact, required this.linkId, required this.id, required this.status});
  final String contact;
  final String linkId;
  final String id;
  final String status;
}

/// A contact appeared or changed (level, network mode, presence).
final class ContactEvent extends XEvent {
  const ContactEvent(this.contact);
  final ContactSummary contact;
}

/// An invite changed phase.
final class InviteEvent extends XEvent {
  const InviteEvent(this.invite);
  final InviteInfo invite;
}

/// The subscriber fell behind: reload the state.
final class Lagged extends XEvent {
  const Lagged(this.missed);
  final int missed;
}

// x-control/2 (slice 3): owner session, history verification, rekey, rights.

/// Trust-level rights (SPEC §9) as reported by the daemon.
final class Rights {
  const Rights({
    required this.level,
    required this.name,
    required this.messages,
    required this.files,
    required this.tasks,
    required this.commands,
    required this.msgsPerMin,
  });

  factory Rights.fromJson(Json j) => Rights(
        level: _optInt(j, 'level') ?? 0,
        name: _optStr(j, 'name') ?? '',
        messages: _optStr(j, 'messages') ?? '',
        files: _optStr(j, 'files') ?? '',
        tasks: _optStr(j, 'tasks') ?? '',
        commands: _optStr(j, 'commands') ?? '',
        msgsPerMin: _optInt(j, 'msgs_per_min') ?? 0,
      );

  final int level;
  final String name;
  final String messages;
  final String files;
  final String tasks;
  final String commands;
  final int msgsPerMin;
}

/// Where the history diverges.
final class HistoryPlace {
  const HistoryPlace({required this.author, required this.n, this.messageId, this.peerMessageId, this.seq, this.lamport, this.ts});

  factory HistoryPlace.fromJson(Json j) => HistoryPlace(
        author: _optStr(j, 'author') ?? '',
        n: _optInt(j, 'n') ?? 0,
        messageId: _optStr(j, 'message_id'),
        peerMessageId: _optStr(j, 'peer_message_id'),
        seq: _optInt(j, 'seq'),
        lamport: _optInt(j, 'lamport'),
        ts: _optInt(j, 'ts'),
      );

  /// Whose message: `me` / `contact`.
  final String author;

  /// The message's number on the author's side (1, 2, 3…).
  final int n;
  final String? messageId;
  final String? peerMessageId;

  /// `seq` in our own copy, for scrolling the chat.
  final int? seq;
  final int? lamport;
  final int? ts;
}

/// History verification state of a link (SPEC §8, CONTROL §12).
final class HistoryStatus {
  const HistoryStatus({
    required this.state,
    this.fingerprint,
    this.fingerprintDigits,
    this.atMs,
    this.place,
    this.whoChanged,
    this.reason,
    this.accepted = false,
    this.sendBlocked = false,
    this.rollback,
    this.counts = const [0, 0],
    this.heads = const [],
    this.detail = '',
  });

  factory HistoryStatus.fromJson(Json j) => HistoryStatus(
        state: _optStr(j, 'state') ?? 'unchecked',
        fingerprint: _optStr(j, 'fingerprint'),
        fingerprintDigits: _optStr(j, 'fingerprint_digits'),
        atMs: _optInt(j, 'at_ms'),
        place: j['where'] is Map<String, Object?> ? HistoryPlace.fromJson(_obj(j, 'where')) : null,
        whoChanged: _optStr(j, 'who_changed'),
        reason: _optStr(j, 'reason'),
        accepted: _bool(j, 'accepted'),
        sendBlocked: _bool(j, 'send_blocked'),
        rollback: _optStr(j, 'rollback'),
        counts: j['counts'] is List ? [for (final c in j['counts']! as List) c is int ? c : 0] : const [0, 0],
        heads: _strList(j, 'heads'),
        detail: _optStr(j, 'detail') ?? '',
      );

  /// `unchecked` / `syncing` / `verified` / `mismatch` / `rolled_back` / `peer_rolled_back`.
  final String state;

  /// A 3-emoji fingerprint (identical on both sides once verified).
  final String? fingerprint;

  /// The same fingerprint as digits (000–999).
  final String? fingerprintDigits;
  final int? atMs;
  final HistoryPlace? place;

  /// `me` / `contact` / `both` / `unknown`.
  final String? whoChanged;
  final String? reason;
  final bool accepted;
  final bool sendBlocked;

  /// `local_counter` / `counter_file_missing` / `counter_file_damaged` / `contact_numbers`.
  final String? rollback;
  final List<int> counts;
  final List<String> heads;
  final String detail;

  bool get verified => state == 'verified';
  bool get mismatch => state == 'mismatch';
  bool get rolledBack => state == 'rolled_back';
  bool get peerRolledBack => state == 'peer_rolled_back';
}

final class OwnerSessionReply extends Reply {
  const OwnerSessionReply({required this.kind, required this.expiresMs});
  final String kind;
  final int expiresMs;
}

final class HistoryStatusReply extends Reply {
  const HistoryStatusReply({required this.contact, required this.linkId, required this.status});
  final String contact;
  final String linkId;
  final HistoryStatus status;
}

final class RevokedReply extends Reply {
  const RevokedReply({required this.contact, required this.linkId, required this.historyDeleted});
  final String contact;
  final String linkId;
  final bool historyDeleted;
}

/// Rekey: `waiting_for_contact` (+ the code the owner reads out to the contact) / `done`.
final class RekeyReply extends Reply {
  const RekeyReply({required this.contact, required this.state, this.code, this.codeEmoji});
  final String contact;
  final String state;
  final String? code;
  final String? codeEmoji;

  bool get done => state == 'done';

  @override
  String toString() => 'RekeyReply($contact, $state, code <redacted>)';
}

/// History verification state changed.
final class HistoryEvent extends XEvent {
  const HistoryEvent({required this.contact, required this.linkId, required this.status});
  final String contact;
  final String linkId;
  final HistoryStatus status;
}

/// Dialog input was rejected (for example, "yes" with a code from a different invite): the invite stays alive.
final class InputRejected extends XEvent {
  const InputRejected({required this.what, required this.code, required this.message});
  final String what;
  final String code;
  final String message;
}

/// The owner session is open and held by the `login {hold}` connection.
final class SessionEvent extends XEvent {
  const SessionEvent({required this.token, required this.mode});
  final String token;
  final String mode;

  @override
  String toString() => 'SessionEvent($mode, token <redacted>)';
}

/// Link rekey: `requested_by_contact` / `confirm_contact_code` / `waiting_for_contact` / `conflicting_offers` / `done`.
final class RekeyEvent extends XEvent {
  const RekeyEvent({required this.contact, required this.state});
  final String contact;
  final String state;
}

// Streams and wake (x-control/4, CONTROL §15–§16).

/// The `message_stream` event: a "live" bubble for a message still being written. Keyed by [streamId].
final class MessageStreamEvent extends XEvent {
  const MessageStreamEvent({
    required this.contact,
    required this.linkId,
    required this.streamId,
    required this.direction,
    required this.state,
    required this.seq,
    required this.textLen,
    this.delta,
    this.activity,
    this.live = true,
    this.messageId,
    this.end,
    this.reason,
    this.text,
    this.viaAgent,
  });

  factory MessageStreamEvent.fromJson(Json j) => MessageStreamEvent(
        contact: _str(j, 'contact'),
        linkId: _str(j, 'link_id'),
        streamId: _str(j, 'stream_id'),
        direction: _optStr(j, 'direction') ?? 'in',
        state: _str(j, 'state'),
        seq: _optInt(j, 'seq') ?? 0,
        textLen: _optInt(j, 'text_len') ?? 0,
        delta: _optStr(j, 'delta'),
        activity: _optStr(j, 'activity'),
        live: _bool(j, 'live', fallback: true),
        messageId: _optStr(j, 'message_id'),
        end: _optStr(j, 'end'),
        reason: _optStr(j, 'reason'),
        text: _optStr(j, 'text'),
        viaAgent: _optStr(j, 'via_agent'),
      );

  final String contact;
  final String linkId;
  final String streamId;

  /// Which agent writes (v7, PG-20): `in`: the contact's agent as its node names it when the stream opens (the
  /// final message's `via_agent` is what counts); `out`: my own agent. `null`: a person, or a node that does not say.
  final String? viaAgent;

  /// `in`: the contact (their agent) is writing; `out`: this node (the owner via the CLI, or their agent on wake).
  final String direction;

  /// `streaming` → `final` | `interrupted`.
  final String state;
  final int seq;

  /// Length of the whole text after this event, in UTF-8 bytes.
  final int textLen;
  final String? delta;

  /// `tool:<name>`: what the source is busy with.
  final String? activity;

  /// `out`: the contact sees the stream as it is written.
  final bool live;

  /// `final`: ID of the final message in the history.
  final String? messageId;

  /// `final`: `done` / `interrupted`.
  final String? end;

  /// `interrupted`: `connection_lost`, `timeout`, `limit`, `bad_frame`, `sender_aborted`, `cut`, `empty`.
  final String? reason;

  /// `interrupted`: all the text that arrived.
  final String? text;
}

/// `stream_started` (reply to `send_stream`).
final class StreamStartedEvent extends XEvent {
  const StreamStartedEvent({required this.streamId, required this.live, this.reason});
  final String streamId;
  final bool live;
  final String? reason;
}

/// The `wake` event: an agent run triggered by wake.
final class WakeEvent extends XEvent {
  const WakeEvent({
    required this.contact,
    required this.linkId,
    required this.agent,
    required this.runId,
    required this.state,
    required this.detail,
  });
  final String contact;
  final String linkId;
  final String agent;
  final String runId;

  /// `queued` / `started` / `finished` / `failed` / `timeout` / `refused`.
  final String state;
  final String detail;
}

/// A stream in progress (`streams`).
final class StreamView {
  const StreamView({
    required this.contact,
    required this.linkId,
    required this.streamId,
    required this.direction,
    required this.text,
    required this.live,
    required this.seq,
    required this.startedMs,
    this.activity,
    this.viaAgent,
  });

  factory StreamView.fromJson(Json j) => StreamView(
        contact: _str(j, 'contact'),
        linkId: _str(j, 'link_id'),
        streamId: _str(j, 'stream_id'),
        direction: _optStr(j, 'direction') ?? 'in',
        text: _optStr(j, 'text') ?? '',
        activity: _optStr(j, 'activity'),
        live: _bool(j, 'live', fallback: true),
        seq: _optInt(j, 'seq') ?? 0,
        startedMs: _optInt(j, 'started_ms') ?? 0,
        viaAgent: _optStr(j, 'via_agent'),
      );

  /// Which agent writes (v7), as in [MessageStreamEvent.viaAgent].
  final String? viaAgent;
  final String contact;
  final String linkId;
  final String streamId;
  final String direction;
  final String text;
  final String? activity;
  final bool live;
  final int seq;
  final int startedMs;
}

final class StreamsReply extends Reply {
  const StreamsReply(this.streams);
  final List<StreamView> streams;
}

/// The latest agent run triggered by wake.
final class WakeRunInfo {
  const WakeRunInfo({
    required this.runId,
    required this.startedMs,
    required this.outcome,
    required this.sandbox,
    required this.detail,
    this.endedMs,
    this.exitCode,
  });

  factory WakeRunInfo.fromJson(Json j) => WakeRunInfo(
        runId: _optStr(j, 'run_id') ?? '',
        startedMs: _optInt(j, 'started_ms') ?? 0,
        endedMs: _optInt(j, 'ended_ms'),
        outcome: _optStr(j, 'outcome') ?? '',
        exitCode: _optInt(j, 'exit_code'),
        sandbox: _optStr(j, 'sandbox') ?? '',
        detail: _optStr(j, 'detail') ?? '',
      );

  final String runId;
  final int startedMs;
  final int? endedMs;

  /// `running` / `ok` / `failed` / `timeout` / `stopped` / `refused`.
  final String outcome;
  final int? exitCode;
  final String sandbox;
  final String detail;
}

/// A wake rule.
final class WakeRuleInfo {
  const WakeRuleInfo({
    required this.contact,
    required this.linkId,
    required this.agent,
    required this.argv,
    required this.mode,
    required this.timeoutSecs,
    required this.maxRunsPerHour,
    this.allowHosts = const [],
    this.homeFiles = const [],
    this.secretEnv = const [],
    this.createdMs = 0,
    this.running = false,
    this.pending = false,
    this.last,
    this.resident,
    this.project,
    this.toolPaths = const [],
    this.env = const [],
  });

  factory WakeRuleInfo.fromJson(Json j) => WakeRuleInfo(
        contact: _str(j, 'contact'),
        linkId: _str(j, 'link_id'),
        agent: _optStr(j, 'agent') ?? '',
        argv: _strList(j, 'argv'),
        mode: _optStr(j, 'mode') ?? 'plain',
        timeoutSecs: _optInt(j, 'timeout_secs') ?? 600,
        allowHosts: _strList(j, 'allow_hosts'),
        homeFiles: _strList(j, 'home_files'),
        secretEnv: _strList(j, 'secret_env'),
        maxRunsPerHour: _optInt(j, 'max_runs_per_hour') ?? 20,
        createdMs: _optInt(j, 'created_ms') ?? 0,
        running: _bool(j, 'running'),
        pending: _bool(j, 'pending'),
        last: j['last'] is Map<String, Object?> ? WakeRunInfo.fromJson(_obj(j, 'last')) : null,
        resident: j['resident'] is Map<String, Object?> ? ResidentInfo.fromJson(_obj(j, 'resident')) : null,
        project: _optStr(j, 'project'),
        toolPaths: _strList(j, 'tool_paths'),
        env: _strList(j, 'env'),
      );

  final String contact;
  final String linkId;
  final String agent;
  final List<String> argv;

  /// `claude_stream`: the daemon relays the reply as a stream; `plain`: the agent replies by itself.
  final String mode;
  final int timeoutSecs;
  final List<String> allowHosts;
  final List<String> homeFiles;

  /// Names only: the daemon never reveals the values.
  final List<String> secretEnv;
  final int maxRunsPerHour;
  final int createdMs;
  final bool running;
  final bool pending;
  final WakeRunInfo? last;

  /// A resident rule's session (v6, CONTROL §21); `null` for a one-shot rule.
  final ResidentInfo? resident;

  /// The own-machine profile (v7, D-122): the project folder the agent works in, the toolchains it reads, plain
  /// environment variables (`NAME=value`).
  final String? project;
  final List<String> toolPaths;
  final List<String> env;

  /// The same rule with another session view (after `wake_session`).
  WakeRuleInfo withResident(ResidentInfo r) => WakeRuleInfo(
        contact: contact,
        linkId: linkId,
        agent: agent,
        argv: argv,
        mode: mode,
        timeoutSecs: timeoutSecs,
        maxRunsPerHour: maxRunsPerHour,
        allowHosts: allowHosts,
        homeFiles: homeFiles,
        secretEnv: secretEnv,
        createdMs: createdMs,
        running: running,
        pending: pending,
        last: last,
        resident: r,
        project: project,
        toolPaths: toolPaths,
        env: env,
      );
}

/// `wake`: reply to `wake_set`, `wake_list`, `wake_off`.
final class WakeReply extends Reply {
  const WakeReply({required this.rules, required this.sandbox, required this.sandboxDetail});
  final List<WakeRuleInfo> rules;

  /// `bwrap` / `landlock` / `none`.
  final String sandbox;
  final String sandboxDetail;
}

// Contact agents and LAN (x-control/5, CONTROL §17–§18).

/// An agent of the contact, as announced by the contact on this link.
final class PeerAgent {
  const PeerAgent({required this.name, required this.state, required this.sinceMs});

  factory PeerAgent.fromJson(Json j) => PeerAgent(
        name: _str(j, 'name'),
        state: _optStr(j, 'state') ?? 'active',
        sinceMs: _optInt(j, 'since_ms') ?? 0,
      );

  /// `[A-Za-z0-9._-]`, ≤ 64; contact data.
  final String name;

  /// `active` / `revoked`.
  final String state;
  final int sinceMs;
}

/// A link on the LAN.
final class LanLink {
  const LanLink({required this.contact, required this.beacon, this.found = const [], this.foundMs});

  factory LanLink.fromJson(Json j) => LanLink(
        contact: _str(j, 'contact'),
        beacon: _bool(j, 'beacon'),
        found: _strList(j, 'found'),
        foundMs: _optInt(j, 'found_ms'),
      );

  final String contact;

  /// This node is currently announcing itself for this contact (there is something to deliver and the contact does
  /// not answer at known addresses).
  final bool beacon;

  /// The contact's addresses found on the network (≤ 10 minutes old).
  final List<String> found;
  final int? foundMs;
}

/// `lan`: reply to `lan_set` / `lan_status`.
final class LanReply extends Reply {
  const LanReply({required this.enabled, required this.listening, this.error, this.links = const []});

  factory LanReply.fromJson(Json j) => LanReply(
        enabled: _bool(j, 'enabled'),
        listening: _bool(j, 'listening'),
        error: _optStr(j, 'error'),
        links: [for (final l in _list(j, 'links')) LanLink.fromJson(l)],
      );

  final bool enabled;
  final bool listening;

  /// Why mDNS is not working (port 5353 busy, no multicast).
  final String? error;

  /// Links at level 3+.
  final List<LanLink> links;
}

