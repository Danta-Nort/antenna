// SPDX-License-Identifier: AGPL-3.0-only
// My devices (x-control/7, CONTROL §27, D-106; experimental): the owner's own computers (contacts at trust level 5)
// as the daemon learned them over their links, and what came of an approval answered from here. A part of
// models.dart. What another computer says about itself is its word: the window shows it as plain text.

part of 'models.dart';

/// A key a device answers approvals with: `touch_id` (a Secure Enclave key behind Touch ID there) or `password` (that
/// computer's own key, used by its daemon only after the password was typed there).
final class DeviceKeyInfo {
  const DeviceKeyInfo({required this.keyId, required this.label, required this.kind, this.publicKey = '', this.confirmedMs});

  factory DeviceKeyInfo.fromJson(Json j) => DeviceKeyInfo(
        keyId: _str(j, 'key_id'),
        label: _optStr(j, 'label') ?? '',
        kind: _optStr(j, 'kind') ?? '',
        publicKey: _optStr(j, 'public_key') ?? '',
        confirmedMs: _optInt(j, 'confirmed_ms'),
      );

  final String keyId;
  final String label;
  final String kind;
  final String publicKey;

  /// When this computer's owner confirmed it (only for a confirmed key).
  final int? confirmedMs;

  bool get touchId => kind == 'touch_id';
}

/// Updates that install by themselves, as that computer said.
final class DeviceUpdate {
  const DeviceUpdate({this.auto = false, this.staged, this.stagedState, this.last, this.lastResult, this.lastAtMs});

  factory DeviceUpdate.fromJson(Json j) => DeviceUpdate(
        auto: _bool(j, 'auto'),
        staged: _optStr(j, 'staged'),
        stagedState: _optStr(j, 'staged_state'),
        last: _optStr(j, 'last'),
        lastResult: _optStr(j, 'last_result'),
        lastAtMs: _optInt(j, 'last_at_ms'),
      );

  final bool auto;

  /// A verified release waiting to be installed there, and its state (`waiting`, `soon`, `installing`).
  final String? staged;
  final String? stagedState;

  /// The last automatic install there: the version, `installed` / `failed` / `refused`, when.
  final String? last;
  final String? lastResult;
  final int? lastAtMs;
}

/// A problem that computer's own checks see (the codes of `antenna doctor`).
final class DeviceHealth {
  const DeviceHealth({required this.code, required this.severity, this.count});

  factory DeviceHealth.fromJson(Json j) =>
      DeviceHealth(code: _str(j, 'code'), severity: _optStr(j, 'severity') ?? 'warning', count: _optInt(j, 'count'));

  final String code;

  /// `problem` or `warning`.
  final String severity;
  final int? count;

  bool get problem => severity == 'problem';
}

/// One agent of that computer.
final class DeviceAgent {
  const DeviceAgent({
    required this.name,
    required this.state,
    this.app,
    this.lastSeenMs,
    this.counterpart,
    this.takesTasks = false,
  });

  factory DeviceAgent.fromJson(Json j) => DeviceAgent(
        name: _str(j, 'name'),
        state: _optStr(j, 'state') ?? 'idle',
        app: _optStr(j, 'app'),
        lastSeenMs: _optInt(j, 'last_seen_ms'),
        counterpart: _optStr(j, 'counterpart'),
        takesTasks: _bool(j, 'takes_tasks'),
      );

  final String name;

  /// `connected`, `idle`, `local`.
  final String state;

  /// The program it runs as (`claude`, `codex`, …) or `local`.
  final String? app;
  final int? lastSeenMs;

  /// The agent map (CONTROL §30): its default counterpart is THIS computer's agent of this name, or this computer's
  /// person when `""`; `null`: none on this link (or an Antenna there without connections).
  final String? counterpart;

  /// It takes this computer's messages as tasks (D-88).
  final bool takesTasks;
}

/// One pending approval request of that computer (what its card shows there).
final class DeviceApproval {
  const DeviceApproval({
    required this.id,
    required this.action,
    required this.requester,
    required this.contact,
    required this.fingerprint,
    required this.createdMs,
    required this.expiresMs,
    this.contactTrust = 1,
    this.target,
    this.reasons = const [],
    this.quote = '',
    this.quoteWithheld = false,
    this.completes = false,
    this.approvers = const [],
  });

  factory DeviceApproval.fromJson(Json j) => DeviceApproval(
        id: _str(j, 'id'),
        action: _str(j, 'action'),
        requester: _optStr(j, 'requester') ?? '',
        contact: _optStr(j, 'contact') ?? '',
        contactTrust: _optInt(j, 'contact_trust') ?? 1,
        target: _optStr(j, 'target'),
        reasons: _strList(j, 'reasons'),
        quote: _optStr(j, 'quote') ?? '',
        quoteWithheld: _bool(j, 'quote_withheld'),
        fingerprint: _str(j, 'fingerprint'),
        createdMs: _optInt(j, 'created_ms') ?? 0,
        expiresMs: _optInt(j, 'expires_ms') ?? 0,
        completes: _bool(j, 'completes'),
        approvers: _strList(j, 'approvers'),
      );

  final String id;
  final String action;
  final String requester;
  final String contact;
  final int contactTrust;
  final String? target;
  final List<String> reasons;

  /// The request's text there, cut; empty when [quoteWithheld] (it contains a secret, which never travels).
  final String quote;
  final bool quoteWithheld;
  final String fingerprint;

  /// That computer's clock.
  final int createdMs;
  final int expiresMs;

  /// After an approval that computer carries the request out itself (D-100).
  final bool completes;

  /// Approver agents (CONTROL §31): THIS computer's agents, by the names they announced on that link, that the
  /// other computer accepts an answer from for this request now; empty: none (or an Antenna there without them).
  final List<String> approvers;

  bool get byAgent => requester != 'owner';
}

/// What a device last said about itself.
final class DeviceView {
  const DeviceView({
    required this.atMs,
    required this.name,
    required this.os,
    required this.arch,
    required this.version,
    this.osVersion = '',
    this.memoryBytes = 0,
    this.update = const DeviceUpdate(),
    this.health = const [],
    this.agents = const [],
    this.approvals = const [],
    this.pendingApprovals = 0,
    this.lend = false,
    this.approvers = const [],
  });

  factory DeviceView.fromJson(Json j) => DeviceView(
        atMs: _optInt(j, 'at_ms') ?? 0,
        name: _optStr(j, 'name') ?? '',
        os: _optStr(j, 'os') ?? '',
        osVersion: _optStr(j, 'os_version') ?? '',
        arch: _optStr(j, 'arch') ?? '',
        memoryBytes: _optInt(j, 'memory_bytes') ?? 0,
        version: _optStr(j, 'version') ?? '',
        update: j['update'] is Map<String, Object?> ? DeviceUpdate.fromJson(_obj(j, 'update')) : const DeviceUpdate(),
        health: [for (final h in _list(j, 'health')) DeviceHealth.fromJson(h)],
        agents: [for (final a in _list(j, 'agents')) DeviceAgent.fromJson(a)],
        approvals: [for (final a in _list(j, 'approvals')) DeviceApproval.fromJson(a)],
        pendingApprovals: _optInt(j, 'pending_approvals') ?? 0,
        lend: _bool(j, 'lend'),
        approvers: [for (final a in _list(j, 'approvers')) StatusApprover.fromJson(a)],
      );

  final int atMs;
  final String name;
  final String os;
  final String osVersion;
  final String arch;
  final int memoryBytes;
  final String version;
  final DeviceUpdate update;
  final List<DeviceHealth> health;
  final List<DeviceAgent> agents;
  final List<DeviceApproval> approvals;
  final int pendingApprovals;
  final bool lend;

  /// Approver agents (CONTROL §31): THIS computer's agents that computer's owner named approvers there, with the
  /// scope set there; empty: none (or an Antenna there without them).
  final List<StatusApprover> approvers;
}

/// Another own device reported this one as lost.
final class LostReport {
  const LostReport({required this.contact, required this.atMs});
  final String contact;
  final int atMs;
}

/// One of the owner's other computers.
final class DeviceInfo {
  const DeviceInfo({
    required this.contact,
    required this.linkId,
    required this.presence,
    required this.supported,
    this.status,
    this.receivedMs,
    this.confirmed = const [],
    this.offered = const [],
    this.acceptsMine = const [],
    this.lostBy,
    this.stopAgents = false,
  });

  factory DeviceInfo.fromJson(Json j) => DeviceInfo(
        contact: _str(j, 'contact'),
        linkId: _str(j, 'link_id'),
        presence: _optStr(j, 'presence') ?? 'offline',
        supported: _bool(j, 'supported'),
        status: j['status'] is Map<String, Object?> ? DeviceView.fromJson(_obj(j, 'status')) : null,
        receivedMs: _optInt(j, 'received_ms'),
        confirmed: [for (final k in _list(j, 'confirmed')) DeviceKeyInfo.fromJson(k)],
        offered: [for (final k in _list(j, 'offered')) DeviceKeyInfo.fromJson(k)],
        acceptsMine: _strList(j, 'accepts_mine'),
        lostBy: j['lost_by'] is Map<String, Object?>
            ? LostReport(contact: _str(_obj(j, 'lost_by'), 'contact'), atMs: _optInt(_obj(j, 'lost_by'), 'at_ms') ?? 0)
            : null,
        stopAgents: _bool(j, 'stop_agents'),
      );

  final String contact;
  final String linkId;

  /// `online` / `offline`.
  final String presence;

  /// Its Antenna speaks own devices; `false`: an older version there, or not known until it connects.
  final bool supported;
  final DeviceView? status;

  /// When this computer last heard from it (this computer's clock).
  final int? receivedMs;

  /// Its keys this computer accepts approvals from.
  final List<DeviceKeyInfo> confirmed;

  /// Keys it announced that are not confirmed here.
  final List<DeviceKeyInfo> offered;

  /// Which of this computer's keys it accepts approvals from (it says so).
  final List<String> acceptsMine;
  final LostReport? lostBy;

  /// CONTROL §33 (`agent-stop/0`): that computer stops its agents and the processes they started when this one asks
  /// (`device_agent_stop`); `false`: an older Antenna there.
  final bool stopAgents;

  bool get online => presence == 'online';
  int get pending => status?.pendingApprovals ?? 0;
}

/// A computer removed here as lost.
final class LostInfo {
  const LostInfo({required this.contact, required this.keyIds, required this.atMs});
  final String contact;
  final List<String> keyIds;
  final int atMs;
}

/// This computer.
final class ThisDevice {
  const ThisDevice({
    required this.name,
    required this.os,
    required this.arch,
    required this.version,
    this.osVersion = '',
    this.lend = false,
    this.keys = const [],
    this.lost = const [],
  });

  factory ThisDevice.fromJson(Json j) => ThisDevice(
        name: _optStr(j, 'name') ?? '',
        os: _optStr(j, 'os') ?? '',
        osVersion: _optStr(j, 'os_version') ?? '',
        arch: _optStr(j, 'arch') ?? '',
        version: _optStr(j, 'version') ?? '',
        lend: _bool(j, 'lend'),
        keys: [for (final k in _list(j, 'keys')) DeviceKeyInfo.fromJson(k)],
        lost: [
          for (final l in _list(j, 'lost'))
            LostInfo(contact: _str(l, 'contact'), keyIds: _strList(l, 'key_ids'), atMs: _optInt(l, 'at_ms') ?? 0),
        ],
      );

  final String name;
  final String os;
  final String osVersion;
  final String arch;
  final String version;

  /// "Lend this computer to my teams".
  final bool lend;

  /// The keys this computer answers its other devices' approvals with.
  final List<DeviceKeyInfo> keys;
  final List<LostInfo> lost;

  /// This computer's own device key (the password typed here).
  DeviceKeyInfo? get passwordKey => keys.where((k) => k.kind == 'password').firstOrNull;
}

/// `devices`.
final class DevicesReply extends Reply {
  const DevicesReply({required this.self, required this.devices});

  factory DevicesReply.fromJson(Json j) => DevicesReply(
        self: ThisDevice.fromJson(_obj(j, 'this')),
        devices: [for (final d in _list(j, 'devices')) DeviceInfo.fromJson(d)],
      );

  /// This computer (`this` on the wire).
  final ThisDevice self;
  final List<DeviceInfo> devices;

  DeviceInfo? byLink(String linkId) => devices.where((d) => d.linkId == linkId).firstOrNull;
}

/// `device_challenge`: the other computer's one-time challenge.
final class DeviceChallengeReply extends Reply {
  const DeviceChallengeReply({required this.contact, required this.linkId, required this.nonce, required this.expiresMs});

  factory DeviceChallengeReply.fromJson(Json j) => DeviceChallengeReply(
        contact: _str(j, 'contact'),
        linkId: _str(j, 'link_id'),
        nonce: _str(j, 'nonce'),
        expiresMs: _optInt(j, 'expires_ms') ?? 0,
      );

  final String contact;
  final String linkId;
  final String nonce;
  final int expiresMs;
}

/// `device_approve` / `device_decide`: what the other computer did.
final class DeviceDecidedReply extends Reply {
  const DeviceDecidedReply({required this.contact, required this.id, required this.state});

  factory DeviceDecidedReply.fromJson(Json j) =>
      DeviceDecidedReply(contact: _str(j, 'contact'), id: _str(j, 'id'), state: _str(j, 'state'));

  final String contact;
  final String id;

  /// `approved` / `denied`.
  final String state;
}

/// The `device` event (owner subscriptions of x-control/7): one own device changed (`status`, `keys`, `lost`,
/// `decided`); the window reads `devices` again.
final class DeviceEvent extends XEvent {
  const DeviceEvent({required this.contact, required this.linkId, required this.change});
  final String contact;
  final String linkId;
  final String change;
}

/// The exact text the window signs to approve [id] of the computer on [linkId] (`docs/PROTOCOL.md` §24): compact JSON,
/// fields in this order; the daemon checks the signature over these bytes and nothing else.
String remoteApproveText({required String linkId, required String id, required String fingerprint}) =>
    jsonEncode({'cmd': 'remote_approve', 'link': linkId, 'id': id, 'fingerprint': fingerprint});
