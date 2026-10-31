// SPDX-License-Identifier: AGPL-3.0-only
// Fake daemon for widget tests and golden screenshots: data in x-control/1 shapes, no socket.
// Dialogs (invite/join/subscribe) are driven by the test: the test sends the events and the result itself.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/protocol/x_control.dart';

import 'fake_agent_stop.dart';
import 'fake_approvers.dart';
import 'fake_connections.dart';
import 'fake_devices.dart';
import 'fake_local.dart';
import 'fake_owner_keys.dart';
import 'fake_pictures.dart';
import 'fake_teams.dart';
import 'fixtures.dart' show hex;

/// Code input → digits: digits as they are, animal emoji → digits (a simplified `antenna_proto::sas::parse_input`).
String parseSasDigits(String input) {
  final b = StringBuffer();
  for (final r in input.runes) {
    final ch = String.fromCharCode(r);
    if (RegExp(r'\d').hasMatch(ch)) {
      b.write(ch);
      continue;
    }
    final g = sasGlyphs.where((g) => g.emoji == ch).firstOrNull;
    if (g != null) b.write(g.digit);
  }
  return b.toString();
}

class FakeDialog implements XDialog {
  FakeDialog(this.request);

  final XRequest request;
  final _events = StreamController<XEvent>();
  final _result = Completer<Reply>();
  final inputs = <XInput>[];
  bool cancelled = false;

  void emit(XEvent e) => _events.add(e);
  void finish(Reply r) {
    if (!_result.isCompleted) _result.complete(r);
  }

  void fail(Object e) {
    if (!_result.isCompleted) _result.completeError(e);
  }

  @override
  Stream<XEvent> get events => _events.stream;

  @override
  Future<Reply> get result => _result.future;

  @override
  void input(XInput i) => inputs.add(i);

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

class FakeDaemon
    with FakeLocalModels, FakeTeams, FakeDevices, FakePictures, FakeConnections, FakeApprovers, FakeAgentStop
    implements XDaemon {
  FakeDaemon({
    this.socketPath = '/home/owner/.local/share/antenna/antennad.sock',
    this.state = DaemonState.unlocked,
    this.password = 'correct horse battery',
    List<ContactInfo>? contacts,
    Map<String, List<HistoryItem>>? history,
    List<ApprovalInfo>? approvals,
    List<InviteInfo>? invites,
    this.relay = 'n0',
    this.reachable = true,
  })  : contactList = contacts ?? [],
        historyMap = history ?? {},
        approvalList = approvals ?? [],
        inviteList = invites ?? [] {
    if (state == DaemonState.unlocked) sessionToken = 'xos_fake';
  }

  @override
  final String socketPath;
  DaemonState state;
  @override
  String password;

  /// Owner session token: an unlocked fake has a session right away (in tests the window is already signed in).
  @override
  String? sessionToken;

  /// The test sets the `history_status`/`verify` responses and the rekey steps.
  final historyStatusByLink = <String, HistoryStatus>{};

  /// How long `verify` takes before it answers (to catch the window mid-check); and an error it raises instead,
  /// keyed by contact (label or link id), for the "could not check" state.
  Duration verifyDelay = Duration.zero;
  final verifyErrors = <String, XClientException>{};
  RekeyReply Function(String contact, String? code)? onRekey;
  final markedRead = <String, int>{};
  String relay;
  bool reachable;
  @override
  List<ContactInfo> contactList;
  Map<String, List<HistoryItem>> historyMap;
  List<ApprovalInfo> approvalList;
  List<InviteInfo> inviteList;

  /// Behave like a daemon older than D-84: `deny` without the password is a `bad_request` (a missing field).
  bool denyNeedsPassword = false;

  /// The control protocol version this fake speaks: 7 by default; 6 behaves like a daemon older than owner keys and
  /// updates that install by themselves (CONTROL §22, §23), 5 like one older than addressing (CONTROL §20): the newer
  /// fields and commands are rejected as unknown, as the real daemon's strict parser does. Local models (CONTROL §24,
  /// `fake_local.dart`) answer only with `localModelsEnabled`.
  @override
  int protoVersion = 7;

  /// v6 requests as the window sent them (to check what it carries).
  final sentAddresses = <MessageAddress?>[];

  /// `send.urgent` of every send, in order (CONTROL §33).
  final sentUrgent = <bool>[];
  final markedIds = <String, List<String>>{};
  final approveManyCalls = <(List<ApproveItem>, String)>[];
  final denyManyCalls = <(List<String>, bool)>[];
  final agentSetCalls = <(String, bool, String?)>[];

  /// The `topics` answer per link (most recent first); a topic created by `send` is added in front.
  final topicMap = <String, List<TopicInfo>>{};

  void _v6(String what) {
    if (protoVersion < 6) throw XControlException(XErrorCode.badRequest, 'bad message: unknown field `$what`');
  }

  /// Requests whose time ran out: deciding them answers `approval_expired`.
  final expiredIds = <String>{};

  /// All requests (command names) in order.
  @override
  final calls = <String>[];

  /// Passwords that came with owner commands (to check that the UI passes them on).
  @override
  final passwords = <String, String>{};

  /// Owner commands that came with a valid proof instead of the password (D-131), in order.
  final proven = <String>[];

  /// The request being carried out came with a proof the fake checked: its password checks pass with `''`.
  @override
  bool proofChecked = false;
  @override
  final dialogs = <FakeDialog>[];
  int _seq = 1000;

  void _check() {
    if (!reachable) throw XDaemonUnreachable(socketPath, 'No such file or directory');
  }

  void _unlocked() {
    if (state == DaemonState.uninitialized) throw const XControlException(XErrorCode.notInitialized, 'run antenna init');
    if (state != DaemonState.unlocked) throw const XControlException(XErrorCode.locked, 'keystore is locked');
  }

  void _pw(String cmd, String pw) {
    passwords[cmd] = pw;
    if (proofChecked) return;
    if (pw != password) throw const XControlException(XErrorCode.wrongPassword, 'wrong password');
    ownerKeys.passwordUsed();
  }

  @override
  Future<HelloOk> hello() async {
    _check();
    calls.add('hello');
    return HelloOk(
      daemon: 'antennad 0.1.0 (1c63cc92d7bf)',
      protocol: 'x/1',
      state: state,
      role: 'owner',
      proto: 'x-control/$protoVersion',
      session: sessionToken == null ? 'none' : 'held',
    );
  }

  @override
  Future<StatusReply> status() async {
    _check();
    calls.add('status');
    return StatusReply(
      state: state,
      daemon: 'antennad 0.1.0 (1c63cc92d7bf)',
      protocol: 'x/0',
      relay: relay,
      links: state == DaemonState.unlocked ? contactList.length : null,
      updated: protoVersion >= 7 ? updated : null,
    );
  }

  /// `status.updated` (v7): this daemon came up from an automatic update (set by the test).
  UpdatedInfo? updated;

  @override
  Future<Reply> call(XRequest request) async {
    _check();
    calls.add(request.cmd);
    return switch (request) {
      SendRequest(:final contact, :final text, :final approvalId, :final address, :final urgent) =>
        _send(contact, text, approvalId: approvalId, address: address, urgent: urgent),
      AgentTerminalRequest() || AgentStopRequest() || DeviceAgentStopRequest() => agentStopCall(request),
      final TeamRequest r => teamCall(r),
      final ConnectionRequest r => connectionsCall(r),
      final ApproverRequest r => approversCall(r),
      _ when request.cmd == 'devices' || request.cmd.startsWith('device_') => devicesCall(request),
      _ => throw XControlException(XErrorCode.notImplemented, 'fake: ${request.cmd}'),
    };
  }

  @override
  XDialog open(XRequest request) {
    calls.add(request.cmd);
    final d = FakeDialog(request);
    dialogs.add(d);
    if (request case InviteRequest(:final password)) passwords['invite'] = password;
    if (request case JoinRequest(:final password)) passwords['join'] = password;
    if (request is TeamWatchRequest) return teamWatchOpen(request, d);
    return d;
  }

  @override
  Future<DaemonState> init(String password) async {
    _check();
    calls.add('init');
    if (state != DaemonState.uninitialized) {
      throw const XControlException(XErrorCode.alreadyInitialized, 'already initialized');
    }
    this.password = password;
    return state = DaemonState.unlocked;
  }

  @override
  Future<DaemonState> unlock(String password) async {
    _check();
    calls.add('unlock');
    if (password != this.password) throw const XControlException(XErrorCode.wrongPassword, 'wrong password');
    ownerKeys.passwordUsed();
    return state = DaemonState.unlocked;
  }

  // `init` unlocks the keys, as in the real daemon; the window's session comes from a separate `login`.

  @override
  Future<DaemonState> lock() async {
    _check();
    calls.add('lock');
    sessionToken = null;
    return state = DaemonState.locked;
  }

  @override
  Future<List<ContactInfo>> contacts() async {
    _check();
    calls.add('contacts');
    _unlocked();
    return contactList;
  }

  ContactInfo _find(String contact) => contactList.firstWhere(
        (c) => c.label == contact || c.linkId.startsWith(contact),
        orElse: () => throw const XControlException(XErrorCode.notFound, 'no such contact'),
      );

  /// Behave like a daemon before 0.2.0: a text over 64 KiB is a `bad_request`, not `text_too_long`.
  bool tooLongAsBadRequest = false;

  SentReply _send(String contact, String text, {String? approvalId, MessageAddress? address, bool urgent = false}) {
    _unlocked();
    // As the daemon checks it (antenna-core node/text_limit.rs): bytes of UTF-8, at most 64 KiB.
    final bytes = utf8.encode(text).length;
    if (bytes > 65536) {
      throw tooLongAsBadRequest
          ? const XControlException(XErrorCode.badRequest, 'text must be 1..65536 bytes')
          : XControlException(XErrorCode.textTooLong,
              'the text is $bytes bytes and a message holds at most 65536: send it as a file');
    }
    if (address != null) _v6('to');
    sentAddresses.add(address);
    sentUrgent.add(urgent);
    final c = _find(contact);
    // CONTROL §33: only the owner's message to one agent of an own computer; an older contact node gets it as a normal
    // message, and the reply says so.
    if (urgent) {
      if (protoVersion < 7) throw const XControlException(XErrorCode.badRequest, 'bad message: unknown field `urgent`');
      if (address?.to != 'agent' || address?.toAgent == null) {
        throw const XControlException(XErrorCode.badRequest, 'urgent needs to: agent and to_agent');
      }
      if (c.trust != 5) throw const XControlException(XErrorCode.forbidden, 'urgent only to an own computer');
    }
    final sentUrgentFlag = urgent && c.peerUrgent;
    final id = 'f${(_seq++).toRadixString(16).padLeft(63, '0')}';
    final h = historyMap.putIfAbsent(c.linkId, () => []);
    final topic = address == null ? null : _topicFor(c.linkId, address);
    final to = address?.to ?? (protoVersion >= 6 ? 'person' : null);
    // v7 (PROTOCOL §23, `no-agent/0`): the contact's node answers that it has no agent by this name; the fake knows
    // the contact's agents from what it announced
    final names = [for (final a in c.agents) if (a.state != 'revoked') a.name];
    final noAgent = protoVersion >= 7 && address?.toAgent != null && !names.contains(address!.toAgent);
    h.add(HistoryItem(
      seq: _seq,
      id: id,
      direction: 'out',
      kind: 'text',
      text: text,
      ts: 0,
      localMs: 0,
      lamport: h.length + 1,
      status: 'delivered',
      to: to,
      toAgent: address?.toAgent,
      topic: topic,
      noAgent: noAgent,
      urgent: sentUrgentFlag,
    ));
    return SentReply(
      id: id,
      status: 'delivered',
      lamport: h.length,
      to: to,
      toAgent: address?.toAgent,
      topic: topic,
      addressed: protoVersion >= 6 ? c.peerAddressing : null,
      noAgent: noAgent,
      peerAgents: noAgent ? names : const [],
      urgent: urgent ? sentUrgentFlag : null,
    );
  }

  /// The topic of a sent message: by ID (it must exist), by title (an existing one, or a new one in front).
  TopicRef? _topicFor(String linkId, MessageAddress a) {
    final list = topicMap.putIfAbsent(linkId, () => []);
    if (a.topicId != null) {
      final t = list.where((t) => t.id == a.topicId).firstOrNull;
      if (t == null) throw const XControlException(XErrorCode.notFound, 'no such topic on this link');
      return t.ref;
    }
    final title = a.topic;
    if (title == null || title.isEmpty) return null;
    final known = list.where((t) => t.title == title).firstOrNull;
    if (known != null) return known.ref;
    final t = TopicInfo(id: hex(0x70 + list.length + title.length, 32), title: title, count: 1);
    list.insert(0, t);
    return t.ref;
  }

  @override
  Future<SentReply> send(String contact, String text,
      {Duration wait = const Duration(seconds: 2),
      MessageAddress? address,
      String? approvalId,
      bool urgent = false}) async {
    _check();
    calls.add('send');
    return _send(contact, text, approvalId: approvalId, address: address, urgent: urgent);
  }

  @override
  Future<List<InboxMessage>> inbox({bool wait = false, Duration? timeout}) async {
    calls.add('inbox');
    return const [];
  }

  @override
  Future<HistoryReply> history(String contact, {int? before, int? limit, ChatRef? chat}) async {
    _check();
    calls.add('history');
    _unlocked();
    if (chat != null) _v7chats('chat');
    final c = _find(contact);
    historyChats.add(chat);
    final linkAll = historyMap[c.linkId] ?? const <HistoryItem>[];
    final all = chat == null ? linkAll : [for (final m in linkAll) if (fakeChatOf(m) == chat.agent) m];
    final older = before == null ? all : all.where((m) => m.seq < before).toList();
    final n = limit ?? 50;
    final page = older.length > n ? older.sublist(older.length - n) : older;
    return HistoryReply(
      contact: c.label,
      linkId: c.linkId,
      messages: page,
      nextBefore: older.length > n ? page.first.seq : null,
    );
  }

  @override
  XDialog subscribe() => open(const SubscribeRequest());

  @override
  Future<ContactInfo> trust(String contact, int level, String password) async {
    _check();
    calls.add('trust');
    _pw('trust', password);
    final i = contactList.indexWhere((c) => c.label == contact || c.linkId.startsWith(contact));
    final c = contactList[i].copyWith(trust: level, netMode: level <= 2 ? 'relay_only' : 'direct');
    contactList = [...contactList]..[i] = c;
    return c;
  }

  @override
  Future<List<InviteInfo>> pairings({String? password}) async {
    calls.add('pairings');
    if (password != null) {
      _pw('pairings', password);
      return inviteList;
    }
    // Without the password the daemon does not hand out the link and code.
    return [
      for (final i in inviteList)
        InviteInfo(
          id: i.id,
          link: '',
          trust: i.trust,
          label: i.label,
          netMode: i.netMode,
          createdMs: i.createdMs,
          expiresMs: i.expiresMs,
          phase: i.phase,
          attempts: i.attempts,
          result: i.result,
          confirmWithoutCode: i.confirmWithoutCode,
        ),
    ];
  }

  @override
  Future<LinkedReply> pairingConfirm(String id, String password, {String? code}) async {
    calls.add('pairing_confirm');
    confirmCodes.add(code);
    if (code == null) {
      // D-95: without a code only when the invite offers it; a daemon older than D-95 requires the field.
      if (!pairingWithoutCode) throw const XControlException(XErrorCode.badRequest, 'missing field `code`');
      _pw('pairing_confirm', password);
      final offered = inviteList.where((i) => i.id == id).firstOrNull?.confirmWithoutCode ?? false;
      if (!offered) {
        throw const XControlException(
            XErrorCode.codeRequired, 'another invite showed a code at the same time: type the code you read out');
      }
      return _linked();
    }
    if (code.isEmpty) throw const XControlException(XErrorCode.badRequest, '`code` is required');
    _pw('pairing_confirm', password);
    final want = inviteCodes[id] ?? inviteList.where((i) => i.id == id).firstOrNull?.sas;
    if (want == null || parseSasDigits(code) != want) {
      throw XControlException(XErrorCode.sasMismatch, 'this is not the code of invite $id');
    }
    return _linked();
  }

  /// The daemon knows D-95: `pairing_confirm` without `code` is accepted when the invite offers it, otherwise
  /// `code_required`. `false` behaves like preview.4 and earlier: a missing code is a `bad_request`.
  bool pairingWithoutCode = true;

  /// The contact a pairing creates: `pairing_confirm` adds it to `contacts`, as the daemon does.
  ContactInfo? pairedContact;

  /// A link from `pairing_confirm`.
  LinkedReply _linked() {
    if (pairedContact case final c?) contactList = [...contactList, c];
    final r = LinkedReply(
      contact: 'Alex',
      linkId: hex(9001),
      trust: 3,
      netMode: 'direct',
      kxGroup: 'X25519MLKEM768',
      pairingMs: 2600,
    );
    // The result also arrives on the `invite` monitoring connection.
    for (final d in dialogs.where((d) => d.request is InviteRequest)) {
      d.finish(r);
    }
    return r;
  }

  /// Codes of invites created in the test (id → 6 digits).
  final inviteCodes = <String, String>{};

  /// Codes received in `pairing_confirm` (to check that the window never fills in the code itself); `null`: none sent.
  final confirmCodes = <String?>[];

  @override
  Future<List<InviteInfo>> pairingCancel(String id, String password) async {
    calls.add('pairing_cancel');
    _pw('pairing_cancel', password);
    return inviteList;
  }

  @override
  Future<ApprovalsReply> approvals({bool all = false}) async {
    calls.add('approvals');
    return ApprovalsReply(approvalList);
  }

  @override
  Future<ApprovalInfo> approve(String id, String password) async {
    calls.add('approve');
    _pw('approve', password);
    approveIds.add(id);
    if (expiredIds.contains(id)) {
      throw const XControlException(XErrorCode.approvalExpired, 'the request expired (10 minutes) and closed by itself');
    }
    final a = approvalList.firstWhere((a) => a.id == id);
    approvalList = approvalList.where((x) => x.id != id).toList();
    return ApprovalInfo.fromJson({..._approvalJson(a), 'state': 'approved'});
  }

  @override
  Future<ApprovalInfo> deny(String id, {bool hour = false, String? password}) async {
    calls.add('deny');
    if (password != null) {
      _pw('deny', password);
    } else if (denyNeedsPassword) {
      throw const XControlException(XErrorCode.badRequest, 'bad message: missing field `password`');
    }
    if (expiredIds.contains(id)) {
      throw const XControlException(XErrorCode.approvalExpired, 'the request expired (10 minutes) and closed by itself');
    }
    final a = approvalList.firstWhere((a) => a.id == id);
    approvalList = approvalList.where((x) => x.id != id).toList();
    return ApprovalInfo.fromJson({..._approvalJson(a), 'state': 'denied'});
  }

  /// IDs approved one by one (`approve`), in order.
  final approveIds = <String>[];

  /// How many times a password was checked for approvals (one `approve_many` counts once).
  int get approvalPasswordChecks =>
      calls.where((c) => c == 'approve' || c == 'approve_many').length;

  ApprovalResult _decideOne(String id, String state, {String? fingerprint}) {
    if (expiredIds.contains(id)) {
      return ApprovalResult(
        id: id,
        error: const XControlException(XErrorCode.approvalExpired, 'the request expired (10 minutes) and closed by itself'),
      );
    }
    final a = approvalList.where((a) => a.id == id).firstOrNull;
    if (a == null) return ApprovalResult(id: id, error: const XControlException(XErrorCode.notFound, 'no such request'));
    if (fingerprint != null && fingerprint != a.fingerprint) {
      return ApprovalResult(
        id: id,
        error: const XControlException(XErrorCode.approvalMismatch, 'the request changed since it was shown'),
      );
    }
    approvalList = approvalList.where((x) => x.id != id).toList();
    return ApprovalResult(id: id, approval: ApprovalInfo.fromJson({..._approvalJson(a), 'state': state}));
  }

  @override
  Future<List<ApprovalResult>> approveMany(List<ApproveItem> items, String password) async {
    _check();
    calls.add('approve_many');
    _v6('approve_many');
    approveManyCalls.add((items, password));
    _pw('approve_many', password);
    return [for (final i in items) _decideOne(i.id, 'approved', fingerprint: i.fingerprint)];
  }

  @override
  Future<List<ApprovalResult>> denyMany(List<String> ids, {bool hour = false}) async {
    _check();
    calls.add('deny_many');
    _v6('deny_many');
    denyManyCalls.add((ids, hour));
    return [for (final id in ids) _decideOne(id, 'denied')];
  }

  @override
  Future<List<AgentInfo>> agentSet(String name, {required bool everyone, String? password}) async {
    _check();
    calls.add('agent_set');
    _v6('agent_set');
    agentSetCalls.add((name, everyone, password));
    if (everyone) _pw('agent_set', password ?? '');
    agentList = [
      for (final a in agentList)
        a.name != name
            ? a
            : AgentInfo(
                name: a.name,
                createdMs: a.createdMs,
                ceiling: a.ceiling,
                links: a.links,
                boundTo: a.boundTo,
                localLevel: a.localLevel,
                everyone: everyone,
                boundPid: a.boundPid,
                boundComm: a.boundComm,
                boundAlive: a.boundAlive,
                lastSeenMs: a.lastSeenMs,
                tokenFile: a.tokenFile,
                tasksFrom: a.tasksFrom,
                tasksFromDefault: a.tasksFromDefault,
              ),
    ];
    return agentList;
  }

  // Chats per agent (v7, CONTROL §26).

  /// A v7 daemon from before chats: `chats`, `chat_set` and the `chat` fields are unknown to it.
  bool chatsEnabled = true;

  /// The owner's chat settings, per link and agent (`''` the person chat), as `chat_set` left them.
  final chatSettings = <String, Map<String, ChatInfo>>{};

  /// What the window sent: `chat_set` requests, the `chat` of each `history` page, `mark_read` by chat.
  final chatSetCalls = <ChatSetRequest>[];
  final historyChats = <ChatRef?>[];
  final markedChats = <String, (ChatRef, int)>{};

  void _v7chats(String what) {
    if (protoVersion < 7 || !chatsEnabled) {
      throw XControlException(XErrorCode.unknownCommand, 'no such command: $what');
    }
  }

  /// The chat of a history message, by the daemon's rule: `null` is the person chat.
  static String? fakeChatOf(HistoryItem m) {
    if (m.isReceipt) return null;
    if (!m.outgoing) return m.viaAgent;
    return m.to == 'agent' ? m.toAgent : null;
  }

  List<ChatInfo> _chatsOf(ContactInfo c) {
    final h = historyMap[c.linkId] ?? const <HistoryItem>[];
    final saved = chatSettings[c.linkId] ?? const <String, ChatInfo>{};
    final keys = <String>{'', for (final m in h) if (!m.isReceipt) fakeChatOf(m) ?? '', ...saved.keys};
    final out = <ChatInfo>[];
    for (final k in keys) {
      final agent = k.isEmpty ? null : k;
      final msgs = [for (final m in h) if (!m.isReceipt && (fakeChatOf(m) ?? '') == k) m];
      final s = saved[k];
      final last = msgs.lastOrNull;
      final lastMs = last == null ? null : (last.outgoing ? last.localMs : (last.localMs == 0 ? last.ts : last.localMs));
      final archivedMs = s?.archivedMs;
      out.add(ChatInfo(
        contact: c.label,
        linkId: c.linkId,
        agent: agent,
        name: s?.name,
        notify: s?.notifySet == true ? s!.notify : (agent == null ? ChatNotify.all : ChatNotify.asks),
        notifySet: s?.notifySet ?? false,
        archived: archivedMs != null && (lastMs == null || lastMs <= archivedMs),
        archivedMs: archivedMs,
        count: msgs.length,
        unread: msgs.where((m) => m.unread).length,
        lastSeq: last?.seq,
        lastMs: lastMs,
        last: last,
        saved: s != null,
      ));
    }
    out.sort((a, b) {
      if (a.isPerson != b.isPerson) return a.isPerson ? -1 : 1;
      return (b.lastSeq ?? -1).compareTo(a.lastSeq ?? -1);
    });
    return out;
  }

  @override
  Future<List<ChatInfo>> chats({String? contact}) async {
    _check();
    calls.add('chats');
    _unlocked();
    _v7chats('chats');
    return [for (final c in contact == null ? contactList : [_find(contact)]) ..._chatsOf(c)];
  }

  @override
  Future<ChatInfo> chatSet(String contact, {String? agent, String? name, String? notify, bool? archived}) async {
    _check();
    calls.add('chat_set');
    _unlocked();
    _v7chats('chat_set');
    chatSetCalls.add(ChatSetRequest(contact: contact, agent: agent, name: name, notify: notify, archived: archived));
    final c = _find(contact);
    if (agent == null && archived == true) {
      throw const XControlException(XErrorCode.badRequest, 'the person chat is not archived');
    }
    final known = agent == null ||
        c.agents.any((a) => a.name == agent) ||
        (historyMap[c.linkId] ?? const <HistoryItem>[]).any((m) => fakeChatOf(m) == agent);
    if (!known) throw XControlException(XErrorCode.notFound, '$contact has no agent $agent');
    final key = agent ?? '';
    final map = chatSettings.putIfAbsent(c.linkId, () => {});
    var s = map[key] ?? ChatInfo(contact: c.label, linkId: c.linkId, agent: agent, saved: true);
    if (name != null) s = name.trim().isEmpty ? s.copyWith(clearName: true) : s.copyWith(name: name.trim());
    if (notify != null) {
      s = notify == ChatNotify.byDefault
          ? s.copyWith(notify: agent == null ? ChatNotify.all : ChatNotify.asks, notifySet: false)
          : s.copyWith(notify: notify, notifySet: true);
    }
    if (archived != null) {
      s = archived
          ? s.copyWith(archivedMs: chatClockMs != 0 ? chatClockMs : DateTime.now().millisecondsSinceEpoch)
          : s.copyWith(clearArchivedMs: true);
    }
    map[key] = s;
    return _chatsOf(c).firstWhere((x) => (x.agent ?? '') == key);
  }

  /// The fake's clock for `archived_ms`; 0 is the real clock (later than every fixture's message).
  int chatClockMs = 0;

  @override
  Future<TopicsReply> topics(String contact) async {
    _check();
    calls.add('topics');
    _v6('topics');
    final c = _find(contact);
    final list = [...?topicMap[c.linkId]];
    // Topics met in the history that the test did not list.
    for (final m in (historyMap[c.linkId] ?? const <HistoryItem>[]).reversed) {
      final t = m.topic;
      if (t != null && !list.any((x) => x.id == t.id)) {
        list.add(TopicInfo(id: t.id, title: t.title, count: 1, lastSeq: m.seq, lastMs: m.localMs));
      }
    }
    return TopicsReply(contact: c.label, linkId: c.linkId, topics: list);
  }

  @override
  Future<List<ReceiptInfo>> log(String contact, {int? limit}) async {
    calls.add('log');
    return receipts[_find(contact).linkId] ?? const [];
  }

  Map<String, List<ReceiptInfo>> receipts = {};

  /// The owner's agents.
  @override
  List<AgentInfo> agentList = [];

  @override
  XDialog login(String password) {
    calls.add('login');
    final d = FakeDialog(LoginRequest(password));
    dialogs.add(d);
    if (password != this.password) {
      d.fail(const XControlException(XErrorCode.wrongPassword, 'wrong password'));
    } else if (state != DaemonState.unlocked) {
      d.fail(const XControlException(XErrorCode.locked, 'keystore is locked'));
    } else {
      ownerKeys.passwordUsed();
      d.emit(const SessionEvent(token: 'xos_fake', mode: 'held'));
    }
    return d;
  }

  // Owner keys (x-control/7, CONTROL §22): challenges, keys and slots in [ownerKeys]; a proof is checked there.

  @override
  final ownerKeys = FakeOwnerKeys();

  void _v7(String what) {
    if (protoVersion < 7) throw XControlException(XErrorCode.badRequest, 'bad message: unknown variant `$what`');
  }

  /// With a proof every password field is empty (CONTROL §22.2).
  static void _noPassword(String pw) {
    if (pw.isNotEmpty) throw const XControlException(XErrorCode.badRequest, 'a password next to a proof');
  }

  @override
  Future<OwnerChallengeReply> ownerChallenge({bool enroll = false}) async {
    _check();
    calls.add('owner_challenge');
    _v7('owner_challenge');
    _unlocked();
    return ownerKeys.challenge(enroll: enroll);
  }

  @override
  Future<OwnerKeysReply> ownerKeyList() async {
    _check();
    calls.add('owner_key_list');
    _v7('owner_key_list');
    _unlocked();
    return ownerKeys.list();
  }

  @override
  Future<void> ownerKeyRemove(String keyId) async {
    _check();
    calls.add('owner_key_remove');
    _v7('owner_key_remove');
    ownerKeys.remove(keyId);
  }

  @override
  Future<DaemonState> unlockWithSlot(String keyId, String slotKey) async {
    _check();
    calls.add('unlock');
    _v7('key_id');
    if (state == DaemonState.uninitialized) throw const XControlException(XErrorCode.notInitialized, 'run antenna init');
    ownerKeys.openSlot(keyId, slotKey);
    return state = DaemonState.unlocked;
  }

  @override
  Future<Reply> callWithProof(XRequest request, ProofSource prove) async {
    _check();
    final req = requestText(request);
    final proof = await prove(req);
    calls.add(request.cmd);
    _v7('proof');
    _unlocked();
    switch (request) {
      case OwnerKeyAddRequest(:final publicKey, :final label, :final unlock, :final password):
        _pw('owner_key_add', password);
        ownerKeys.verify(req, proof, enrolling: publicKey);
        return ownerKeys.add(publicKey, label, unlock: unlock);
      case ApproveRequest(:final id, :final password, :final fingerprint):
        _noPassword(password);
        ownerKeys.verify(req, proof);
        approveIds.add(id);
        final r = _decideOne(id, 'approved', fingerprint: fingerprint);
        if (r.error case final e?) throw e;
        return ApprovalReply(r.approval!);
      case ApproveManyRequest(:final items, :final password):
        _noPassword(password);
        ownerKeys.verify(req, proof);
        approveManyCalls.add((items, password));
        return ApprovalsDecidedReply([for (final i in items) _decideOne(i.id, 'approved', fingerprint: i.fingerprint)]);
      case ApproverSetRequest(:final password):
        _noPassword(password);
        ownerKeys.verify(req, proof);
        return approversCall(request, proof: true);
      // What keeps the password (D-131): turning automatic installs on.
      case UpdateAutoSetRequest(enabled: true):
        throw const XControlException(XErrorCode.passwordRequired, 'update_auto_set takes the owner password');
      default:
        // Every other password command takes a proof (D-131): checked as the daemon does, then carried out as with
        // the password.
        final pw = (jsonDecode(req) as Map<String, Object?>)['password'];
        if (pw is String && pw.isNotEmpty) throw const XControlException(XErrorCode.badRequest, 'a password next to a proof');
        ownerKeys.verify(req, proof);
        proven.add(request.cmd);
        // The typed method records the command itself.
        calls.removeLast();
        proofChecked = true;
        try {
          return await _typed(request);
        } finally {
          proofChecked = false;
        }
    }
  }

  /// A request that came with a proof, carried out by the typed method of this fake (or [call] for the commands that
  /// go through it), with the reply the client expects for it.
  Future<Reply> _typed(XRequest r) async => switch (r) {
        TrustRequest(:final contact, :final level, :final password) =>
          ContactsReply([await trust(contact, level, password)]),
        RevokeRequest(:final contact, :final password, :final deleteHistory) =>
          await revoke(contact, password, deleteHistory: deleteHistory),
        RekeyRequest(:final contact, :final password, :final code) => await rekey(contact, password, code: code),
        VerifyRequest(:final contact, :final accept, :final repair, :final password) =>
          await verify(contact, accept: accept, repair: repair, password: password),
        PairingsRequest(:final password) => PairingsReply(await pairings(password: password)),
        PairingConfirmRequest(:final id, :final password, :final code) => await pairingConfirm(id, password, code: code),
        PairingCancelRequest(:final id, :final password) => PairingsReply(await pairingCancel(id, password)),
        AgentAddRequest(:final name, :final localLevel, :final password, :final links, :final tokenFile, :final everyone) =>
          await agentAdd(name,
              localLevel: localLevel, password: password, links: links, tokenFile: tokenFile, everyone: everyone),
        AgentTokenRequest(:final name, :final password, :final tokenFile) =>
          await agentToken(name, password, tokenFile: tokenFile),
        AgentTasksRequest(:final name, :final password, :final contacts) => await () async {
            await agentTasks(name, password, contacts: contacts);
            return const DoneReply(DaemonState.unlocked);
          }(),
        AgentRemoveRequest(:final name, :final password) => await () async {
            await agentRemove(name, password);
            return const DoneReply(DaemonState.unlocked);
          }(),
        AgentSetRequest(:final name, :final everyone, :final password) =>
          AgentsReply(await agentSet(name, everyone: everyone, password: password)),
        AgentEscalateRequest(:final name, :final password, :final to) =>
          AgentsReply(await agentEscalate(name, password, to: to)),
        FileAcceptRequest(:final id, :final name, :final force, :final allowSpecial, :final approvalId, :final password) =>
          FileReply(await fileAccept(id,
              name: name, force: force, allowSpecial: allowSpecial, approvalId: approvalId, password: password)),
        final WakeSetRequest w => await wakeSet(w),
        WakeSessionRequest(:final contact, :final action, :final password) =>
          await wakeSession(contact, action, password: password),
        LanSetRequest(:final enabled, :final password) => await lanSet(enabled: enabled, password: password),
        LocalAgentAddRequest(:final name, :final model, :final password) =>
          LocalAgentReply(await localAgentAdd(name, model: model, password: password)),
        UpdateAutoSetRequest(:final enabled, :final password) =>
          UpdateAutoReply(await updateAutoSet(enabled: enabled, password: password)),
        _ => await call(r),
      };

  @override
  XDialog openWithProof(XRequest request, ProofSource prove) {
    calls.add(request.cmd);
    final d = FakeDialog(request);
    dialogs.add(d);
    unawaited(() async {
      try {
        final req = requestText(request);
        final proof = await prove(req);
        _check();
        _v7('proof');
        switch (request) {
          // An invite or a join with a proof (D-131): checked, then the dialog goes on as with the password.
          case InviteRequest(:final password) || JoinRequest(:final password):
            _noPassword(password);
            _unlocked();
            ownerKeys.verify(req, proof);
            proven.add(request.cmd);
            passwords[request.cmd] = '';
            return;
          case LoginRequest(:final password):
            _noPassword(password);
            _unlocked();
            ownerKeys.verify(req, proof);
            d.emit(const SessionEvent(token: 'xos_fake', mode: 'held'));
          default:
            throw XControlException(XErrorCode.notImplemented, 'fake: ${request.cmd}');
        }
      } catch (e) {
        d.fail(e);
      }
    }());
    return d;
  }

  @override
  Future<void> logout() async {
    calls.add('logout');
    sessionToken = null;
  }

  ContactInfo _replace(String contact, ContactInfo Function(ContactInfo) f) {
    final i = contactList.indexWhere((c) => c.label == contact || c.linkId.startsWith(contact));
    if (i < 0) throw const XControlException(XErrorCode.notFound, 'no such contact');
    final c = f(contactList[i]);
    contactList = [...contactList]..[i] = c;
    return c;
  }

  @override
  Future<ContactInfo> markRead(String contact, int upToSeq, {List<String>? ids, ChatRef? chat}) async {
    calls.add('mark_read');
    if (ids != null) _v6('ids');
    final link = _find(contact).linkId;
    final h = historyMap[link];
    if (chat != null) {
      _v7chats('chat');
      markedChats[contact] = (chat, upToSeq);
      if (h != null) {
        historyMap[link] = [
          for (final m in h)
            if (m.unread && m.seq <= upToSeq && fakeChatOf(m) == chat.agent) m.withUnread(false) else m,
        ];
      }
      final left = (historyMap[link] ?? const <HistoryItem>[]).where((m) => m.unread).length;
      return _replace(contact, (c) => c.copyWith(unread: left));
    }
    markedRead[contact] = upToSeq;
    if (ids != null) markedIds[contact] = ids;
    if (ids == null || upToSeq > 0) {
      if (h != null) {
        historyMap[link] = [for (final m in h) m.seq <= upToSeq && m.unread ? m.withUnread(false) : m];
      }
      return _replace(contact, (c) => c.copyWith(unread: 0));
    }
    var marked = 0;
    if (h != null) {
      historyMap[link] = [
        for (final m in h)
          if (m.unread && ids.contains(m.id)) ...[m.withUnread(false)] else m,
      ];
      marked = h.where((m) => m.unread && ids.contains(m.id)).length;
    }
    return _replace(contact, (c) => c.copyWith(unread: (c.unread - marked).clamp(0, 1 << 30)));
  }

  /// The agents' questions (D-118); `null` stands for a daemon from before them (`unknown_command`).
  List<EscalationInfo>? questions = [];

  /// `escalation_answer` calls, in order.
  final answers = <EscalationAnswerRequest>[];

  /// `agent_escalate` calls: agent → contact (`null`: the owner).
  final escalateSet = <String, String?>{};

  @override
  Future<List<EscalationInfo>> escalations({bool all = false}) async {
    calls.add('escalations');
    final q = questions;
    if (q == null) throw XControlException(XErrorCode.unknownCommand, 'no such command: "escalations"');
    return [for (final e in q) if (all || e.open) e];
  }

  @override
  Future<EscalationInfo> escalationAnswer(String id, {String? answer, bool dismiss = false}) async {
    calls.add('escalation_answer');
    answers.add(EscalationAnswerRequest(id: id, answer: answer, dismiss: dismiss));
    final q = questions ?? const <EscalationInfo>[];
    final e = q.where((e) => e.id == id).firstOrNull;
    if (e == null) throw XControlException(XErrorCode.notFound, 'no question $id');
    if (!e.open) throw XControlException(XErrorCode.denied, 'this question is ${e.state}');
    final done = EscalationInfo(
      id: e.id,
      agent: e.agent,
      to: e.to,
      question: e.question,
      state: dismiss ? EscalationState.dismissed : EscalationState.answered,
      createdMs: e.createdMs,
      answer: answer,
      answeredMs: e.createdMs + 1000,
      readFrom: e.readFrom,
    );
    questions = [for (final x in q) x.id == id ? done : x];
    return done;
  }

  @override
  Future<List<AgentInfo>> agentEscalate(String name, String password, {String? to}) async {
    calls.add('agent_escalate');
    _pw('agent_escalate', password);
    if (!agentList.any((a) => a.name == name)) throw XControlException(XErrorCode.notFound, 'no agent $name');
    escalateSet[name] = to;
    return agentList;
  }

  @override
  Future<HistoryStatusReply> historyStatus(String contact) async {
    calls.add('history_status');
    final c = _find(contact);
    return HistoryStatusReply(
      contact: c.label,
      linkId: c.linkId,
      status: historyStatusByLink[c.linkId] ?? c.history ?? const HistoryStatus(state: 'unchecked'),
    );
  }

  @override
  Future<HistoryStatusReply> verify(String contact, {bool accept = false, bool repair = false, String? password}) async {
    calls.add('verify');
    if (accept) _pw('verify', password ?? '');
    final c = _find(contact);
    if (verifyDelay > Duration.zero) await Future<void>.delayed(verifyDelay);
    final error = verifyErrors[contact] ?? verifyErrors[c.label] ?? verifyErrors[c.linkId];
    if (error != null) throw error;
    final st = historyStatusByLink[c.linkId] ?? c.history ?? const HistoryStatus(state: 'unchecked');
    return HistoryStatusReply(contact: c.label, linkId: c.linkId, status: st);
  }

  @override
  Future<RevokedReply> revoke(String contact, String password, {bool deleteHistory = false}) async {
    calls.add('revoke');
    _pw('revoke', password);
    final c = _find(contact);
    contactList = contactList.where((x) => x.linkId != c.linkId).toList();
    return RevokedReply(contact: c.label, linkId: c.linkId, historyDeleted: deleteHistory);
  }

  @override
  Future<ContactInfo> rename(String contact, String label) async {
    calls.add('rename');
    return _replace(contact, (c) => c.copyWith(label: label));
  }

  @override
  Future<RekeyReply> rekey(String contact, String password, {String? code}) async {
    calls.add('rekey');
    _pw('rekey', password);
    final f = onRekey;
    if (f == null) throw const XControlException(XErrorCode.notFound, 'no rekey offer');
    return f(_find(contact).label, code);
  }

  @override
  Future<AgentAddedReply> agentAdd(String name,
      {required int localLevel,
      required String password,
      List<String>? links,
      bool tokenFile = false,
      bool? everyone}) async {
    calls.add('agent_add');
    _pw('agent_add', password);
    if (everyone != null) _v6('everyone');
    agentAddEveryone.add(everyone);
    if (tokenFile && !tokenFiles) throw const XControlException(XErrorCode.badRequest, 'unknown field `token_file`');
    if (agentList.any((a) => a.name == name)) {
      throw XControlException(XErrorCode.badRequest, 'agent $name already exists');
    }
    final file = tokenFile ? tokenFileOf(name) : null;
    agentList = [
      ...agentList,
      AgentInfo(
        name: name,
        createdMs: 0,
        links: links,
        localLevel: localLevel,
        tokenFile: file,
        tasksFrom: const [],
        everyone: protoVersion >= 6 ? (everyone ?? false) : null,
      ),
    ];
    return AgentAddedReply(name: name, token: 'xat_${hex(name.length + 7, 43)}', tokenFile: file);
  }

  /// The `everyone` field of each `agent_add`, as the window sent it (`null`: not sent).
  final agentAddEveryone = <bool?>[];

  /// Tokens issued by `agent_token`, per agent (the fake's count, to make each one different).
  final tokenRounds = <String, int>{};

  /// The daemon writes token files (preview.4); `false`: an older daemon that rejects the field.
  bool tokenFiles = true;

  /// Where the fake daemon "writes" an agent's token file.
  String tokenFileOf(String agent) => '${tokenDir ?? socketPath.substring(0, socketPath.lastIndexOf('/'))}/agents/$agent.token';

  /// The data directory's `agents` folder parent, when it is not the socket's folder (a Mac in goldens).
  String? tokenDir;

  @override
  Future<AgentAddedReply> agentToken(String name, String password, {bool tokenFile = false}) async {
    calls.add('agent_token');
    _pw('agent_token', password);
    if (tokenFile && !tokenFiles) throw const XControlException(XErrorCode.badRequest, 'unknown field `token_file`');
    final a = agentList.where((a) => a.name == name).firstOrNull;
    if (a == null) {
      throw XControlException(XErrorCode.notFound, 'no agent $name');
    }
    final round = tokenRounds[name] = (tokenRounds[name] ?? 0) + 1;
    // The daemon rewrites an existing token file with every new token.
    final file = tokenFile || a.tokenFile != null ? tokenFileOf(name) : null;
    if (file != null && a.tokenFile == null) {
      agentList = [for (final x in agentList) x.name == name ? _withTokenFile(x, file) : x];
    }
    return AgentAddedReply(name: name, token: 'xat_${hex(name.length * 31 + round, 43)}', tokenFile: file);
  }

  static AgentInfo _withTokenFile(AgentInfo a, String file) => AgentInfo(
        name: a.name,
        createdMs: a.createdMs,
        ceiling: a.ceiling,
        links: a.links,
        boundTo: a.boundTo,
        localLevel: a.localLevel,
        boundPid: a.boundPid,
        boundComm: a.boundComm,
        boundAlive: a.boundAlive,
        lastSeenMs: a.lastSeenMs,
        tokenFile: file,
        tasksFrom: a.tasksFrom,
        tasksFromDefault: a.tasksFromDefault,
        everyone: a.everyone,
      );

  /// `agent_tasks` calls: agent → contacts (`null`: the default).
  final tasksSet = <String, List<String>?>{};

  @override
  Future<void> agentTasks(String name, String password, {List<String>? contacts}) async {
    calls.add('agent_tasks');
    _pw('agent_tasks', password);
    final a = agentList.where((a) => a.name == name).firstOrNull;
    if (a == null) throw XControlException(XErrorCode.notFound, 'no agent $name');
    tasksSet[name] = contacts;
    final level5 = [for (final c in contactList) if (c.trust == 5) c.label];
    agentList = [
      for (final x in agentList)
        x.name == name
            ? AgentInfo(
                name: x.name,
                createdMs: x.createdMs,
                ceiling: x.ceiling,
                links: x.links,
                boundTo: x.boundTo,
                localLevel: x.localLevel,
                boundPid: x.boundPid,
                boundComm: x.boundComm,
                boundAlive: x.boundAlive,
                lastSeenMs: x.lastSeenMs,
                tokenFile: x.tokenFile,
                tasksFrom: contacts ?? level5,
                tasksFromDefault: contacts == null,
                everyone: x.everyone,
              )
            : x,
    ];
  }

  @override
  Future<List<AgentInfo>> agents() async {
    calls.add('agent_list');
    return agentList;
  }

  @override
  Future<void> agentRemove(String name, String password) async {
    calls.add('agent_remove');
    _pw('agent_remove', password);
    agentList = agentList.where((a) => a.name != name).toList();
    // A local agent goes with its conversation (CONTROL §24).
    localAgentList = localAgentList.where((a) => a.name != name).toList();
    localHistoryMap.remove(name);
  }

  // Files (x-control/3).

  /// The fake's files (ID → FileInfo) and previews (ID → preview); a test may change them and send `file` events.
  final fileMap = <String, FileInfo>{};
  final previewMap = <String, FilePreview?>{};

  /// Paths the window asked to send.
  final shared = <String>[];

  /// What a real daemon would have read at each `share_file`: the file's bytes, or `null` when the path was gone (the
  /// real one answers `not_found`; the fake still accepts, for tests that send made-up paths).
  final sharedContent = <String, List<int>?>{};

  /// Sending this path needs approval (the secret scanner found a secret): the approval request ID.
  final shareNeedsApproval = <String, String>{};

  /// Sending this path fails with this error (a quota, a level that forbids files).
  final shareErrors = <String, XControlException>{};

  /// How long `share_file` takes (the real daemon hashes and encrypts before it replies).
  Duration shareDelay = Duration.zero;
  int _fileSeq = 0;

  /// The address each `share_file` carried (`to`, `to_agent`), in order.
  final shareAddresses = <(String?, String?)>[];

  @override
  Future<FileInfo> shareFile(String contact, String path,
      {String? name, String? approvalId, String? to, String? toAgent}) async {
    _check();
    _unlocked();
    calls.add('share_file');
    shareAddresses.add((to, toAgent));
    if (shareDelay > Duration.zero) await Future<void>.delayed(shareDelay);
    shared.add(path);
    final file = File(path);
    sharedContent[path] = file.existsSync() ? file.readAsBytesSync() : null;
    final error = shareErrors[path];
    if (error != null) throw error;
    final need = shareNeedsApproval[path];
    if (need != null && approvalId != need) {
      throw XControlException(XErrorCode.approvalRequired, 'the file looks like it contains a secret',
          approval: {'id': need, 'state': 'pending'});
    }
    final c = contactList.firstWhere((c) => c.label == contact || c.linkId.startsWith(contact));
    final id = hex(0xF00 + ++_fileSeq, 32);
    final f = FileInfo(
      id: id,
      contact: c.label,
      linkId: c.linkId,
      direction: 'out',
      name: name ?? path.split('/').last,
      size: 1024,
      blake3: hex(0xB3 + _fileSeq, 64),
      state: 'sent',
      verdict: 'clean',
      mime: _mimeFromName(name ?? path.split('/').last),
      createdMs: DateTime(2026, 10, 2, 14, 30).millisecondsSinceEpoch,
    );
    fileMap[id] = f;
    return f;
  }

  /// By extension only (the real daemon reads the signature): good enough to mark a sent `.png`/`.jpg` an image.
  static String? _mimeFromName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return null;
  }

  @override
  Future<List<FileInfo>> filesPending({String? contact, bool all = false}) async {
    _check();
    _unlocked();
    calls.add('files_pending');
    return [
      for (final f in fileMap.values)
        if ((contact == null || f.contact == contact || f.linkId == contact) &&
            (all || !(f.state == 'accepted' || f.state == 'rejected')))
          f,
    ];
  }

  @override
  Future<FilePreviewReply> filePreview(String id) async {
    _check();
    calls.add('file_preview');
    final f = _file(id);
    return FilePreviewReply(file: f, preview: previewMap[f.id]);
  }

  @override
  Future<FileInfo> fileAccept(String id,
      {String? name, bool force = false, bool allowSpecial = false, String? approvalId, String? password}) async {
    _check();
    calls.add('file_accept');
    final f = _file(id);
    acceptForces.add(force);
    if (f.needsForce && !force) {
      throw XControlException(XErrorCode.forbidden,
          'check verdict is ${f.verdict}: only the owner with --force and password may accept');
    }
    // D-130: a file the own-computer rules hold is kept only with --force and the password.
    if ((f.held?.holdsByRule ?? false) && !force) {
      throw XControlException(XErrorCode.forbidden, 'held (${f.held!.code}): only the owner with --force and password');
    }
    if (force) _pw('file_accept', password ?? '');
    if (f.name.startsWith('.') && !allowSpecial && !force) {
      throw const XControlException(
          XErrorCode.approvalRequired, 'dot-files and auto-executed names need a separate approve of the owner');
    }
    final c = contactList.firstWhere((c) => c.linkId == f.linkId);
    final want = name ?? f.name;
    acceptNames.add(name);
    if (_badName(want) case final why?) throw XControlException(XErrorCode.badFileName, why);
    final folder = folderFiles.putIfAbsent(f.linkId, () => {});
    var saved = want;
    var there = folder[want.toLowerCase()];
    // D-128: without the owner's own name, a name another file has is saved under the next free number, and the same
    // content under a number is that file.
    if (name == null && numbersTakenNames && protoVersion >= 7 && !acceptRace && there != null && there != f.blake3) {
      for (var n = 2; there != null && there != f.blake3; n++) {
        saved = numberedFileName(want, n);
        there = folder[saved.toLowerCase()];
      }
    }
    // preview.8: the same content under this name is accepted without a second copy; a v6 daemon refused it as taken.
    if (acceptRace || (there != null && (protoVersion < 7 || there != f.blake3))) {
      throw XControlException(XErrorCode.fileNameTaken, 'a file named "$want" already exists in the link folder');
    }
    folder[saved.toLowerCase()] = f.blake3;
    final done = _copyFile(f,
        state: 'accepted', dest: c.trust == 2 ? 'inbox' : 'shared', savedAs: saved, duplicate: there != null);
    fileMap[f.id] = done;
    return done;
  }

  /// The daemon numbers a taken name itself (D-128); `false`: a daemon before it, which answers `file_name_taken`.
  bool numbersTakenNames = true;

  /// What each link's folder already holds (link ID → lower-cased name → BLAKE3), as the daemon reads the folder for
  /// `file_accept` and `file_name_check`.
  final folderFiles = <String, Map<String, String>>{};

  /// Every name is taken by the time of the accept (another process took it after the check).
  bool acceptRace = false;

  /// The `name` of each `file_accept`, in order (`null`: the contact's name).
  final acceptNames = <String?>[];

  /// The `force` of each `file_accept`, in order.
  final acceptForces = <bool>[];

  /// The names `file_name_check` was asked about, in order.
  final nameChecks = <String?>[];

  static String? _badName(String n) {
    if (n.trim().isEmpty) return 'the name is empty';
    if (n.contains('/') || n.contains('\\')) return 'a name cannot contain / or \\';
    if (n == '.' || n == '..') return 'not a file name';
    if (n.runes.any((r) => r < 0x20 || r == 0x7f)) return 'a name cannot contain control characters';
    return null;
  }

  /// What `file_save_dir` refuses as a folder (the daemon checks it exists in the home and is not hidden or a system
  /// folder): the test sets the paths.
  final badSaveDirs = <String>{};

  ContactInfo _ownComputer(String contact, String cmd) {
    final c = contactList.firstWhere((c) => c.label == contact || c.linkId.startsWith(contact),
        orElse: () => throw const XControlException(XErrorCode.notFound, 'no such contact'));
    if (c.trust < 5) {
      throw XControlException(XErrorCode.forbidden, '$cmd: only for an own computer (trust level 5)');
    }
    return c;
  }

  @override
  Future<FileSaveDirsReply> fileSaveDir(String contact, {String? agent, String? path, String? password}) async {
    _check();
    _unlocked();
    calls.add('file_save_dir');
    final c = _ownComputer(contact, 'file_save_dir');
    if (path != null) {
      _pw('file_save_dir', password ?? '');
      if (badSaveDirs.contains(path)) {
        throw const XControlException(XErrorCode.badRequest, 'the folder must exist in your home folder');
      }
    }
    final dirs = [
      for (final d in c.saveDirs)
        if (d.agent != agent) d,
      if (path != null) SaveDir(agent: agent, path: path),
    ];
    _replace(contact, (x) => x.copyWith(saveDirs: dirs));
    return FileSaveDirsReply(contact: c.label, linkId: c.linkId, dirs: dirs);
  }

  @override
  Future<FileAllowReply> fileAllow(String contact, List<String> entries, {String? password}) async {
    _check();
    _unlocked();
    calls.add('file_allow');
    final c = _ownComputer(contact, 'file_allow');
    _pw('file_allow', password ?? '');
    final all = {...c.fileAllow, ...entries}.toList();
    _replace(contact, (x) => x.copyWith(fileAllow: all));
    return FileAllowReply(contact: c.label, linkId: c.linkId, entries: all);
  }

  @override
  Future<FileAllowReply> fileDisallow(String contact, {List<String>? entries}) async {
    _check();
    _unlocked();
    calls.add('file_disallow');
    final c = contactList.firstWhere((c) => c.label == contact || c.linkId.startsWith(contact));
    final left = entries == null ? <String>[] : [for (final e in c.fileAllow) if (!entries.contains(e)) e];
    _replace(contact, (x) => x.copyWith(fileAllow: left));
    return FileAllowReply(contact: c.label, linkId: c.linkId, entries: left);
  }

  @override
  Future<FileNameCheck> fileNameCheck(String id, {String? name}) async {
    _check();
    calls.add('file_name_check');
    _v7('file_name_check');
    nameChecks.add(name);
    final f = _file(id);
    final want = name ?? f.name;
    if (_badName(want) case final why?) return FileNameCheck(name: want, state: 'invalid', message: why);
    final folder = folderFiles[f.linkId] ?? const <String, String>{};
    final there = folder[want.toLowerCase()];
    if (there == null) return FileNameCheck(name: want, state: 'free');
    if (there == f.blake3) return FileNameCheck(name: want, state: 'same_file');
    final dot = want.lastIndexOf('.');
    final (stem, ext) = dot > 0 ? (want.substring(0, dot), want.substring(dot)) : (want, '');
    var n = 2;
    while (folder.containsKey('$stem ($n)$ext'.toLowerCase())) {
      n++;
    }
    return FileNameCheck(
        name: want,
        state: 'taken',
        suggestion: '$stem ($n)$ext',
        message: 'a file with this name (ignoring case) already exists');
  }

  // Updates that install by themselves (x-control/7, CONTROL §23).

  /// What `update_auto_status` answers (the test changes it); `update_auto_set` turns [UpdateAutoInfo.enabled].
  UpdateAutoInfo updateAuto = const UpdateAutoInfo(enabled: false, supported: true);

  /// `update_auto_set` calls: (enabled, password).
  final updateAutoSets = <(bool, String)>[];

  @override
  Future<UpdateAutoInfo> updateAutoStatus() async {
    _check();
    calls.add('update_auto_status');
    _v7('update_auto_status');
    _unlocked();
    return updateAuto;
  }

  @override
  Future<UpdateAutoInfo> updateAutoSet({required bool enabled, required String password}) async {
    _check();
    calls.add('update_auto_set');
    _v7('update_auto_set');
    updateAutoSets.add((enabled, password));
    _pw('update_auto_set', password);
    if (enabled && !updateAuto.supported) {
      throw XControlException(XErrorCode.unsupportedInstall, updateAuto.unsupportedReason ?? 'a development build');
    }
    return updateAuto = _auto(enabled: enabled, staged: updateAuto.staged);
  }

  @override
  Future<UpdateAutoInfo> updateAutoNow({String? password}) async {
    _check();
    calls.add('update_auto_now');
    _v7('update_auto_now');
    final st = updateAuto.staged;
    if (st == null) throw const XControlException(XErrorCode.notFound, 'nothing is staged');
    // As the daemon (D-137): with no keys kept for the restart, the password opens them; a proof never does.
    if (password != null) {
      _pw('update_auto_now', password);
    } else if (!updateAuto.keysKept) {
      throw const XControlException(XErrorCode.passwordRequired, 'the owner password is needed');
    }
    return updateAuto = _auto(
        staged: StagedUpdate(
            version: st.version, source: st.source, contact: st.contact, stagedMs: st.stagedMs, state: 'installing'));
  }

  @override
  Future<UpdateAutoInfo> updateAutoLater() async {
    _check();
    calls.add('update_auto_later');
    _v7('update_auto_later');
    final st = updateAuto.staged;
    if (st == null) throw const XControlException(XErrorCode.notFound, 'nothing is staged');
    return updateAuto = _auto(
        staged: StagedUpdate(
            version: st.version,
            source: st.source,
            contact: st.contact,
            stagedMs: st.stagedMs,
            state: 'waiting',
            atMs: (st.atMs ?? st.stagedMs) + const Duration(hours: 1).inMilliseconds));
  }

  UpdateAutoInfo _auto({bool? enabled, StagedUpdate? staged}) {
    final a = updateAuto;
    return UpdateAutoInfo(
      enabled: enabled ?? a.enabled,
      supported: a.supported,
      unsupportedReason: a.unsupportedReason,
      keysKept: (enabled ?? a.enabled) && state == DaemonState.unlocked,
      url: a.url,
      lastCheckMs: a.lastCheckMs,
      staged: staged,
      last: a.last,
      failed: a.failed,
      history: a.history,
    );
  }

  /// `agent_watch` dialogs, in order (the test emits their events and ends them).
  List<FakeDialog> get watches => [for (final d in dialogs) if (d.request is AgentWatchRequest) d];

  /// `false`: a daemon that answers `agent_watch` with `unknown_command` (older than v7).
  bool agentWatchSupported = true;

  @override
  XDialog agentWatch(String agent) {
    final d = open(AgentWatchRequest(agent)) as FakeDialog;
    if (protoVersion < 7 || !agentWatchSupported) {
      d.fail(const XControlException(XErrorCode.unknownCommand, 'unknown command "agent_watch"'));
    }
    return d;
  }

  /// `file_withdraw` (preview.5); `false` plays an older daemon (`unknown_command`).
  bool withdrawSupported = true;

  @override
  Future<FileInfo> fileWithdraw(String id) async {
    _check();
    calls.add('file_withdraw');
    if (!withdrawSupported) {
      throw const XControlException(XErrorCode.unknownCommand, 'unknown command "file_withdraw"');
    }
    final f = fileMap.values.firstWhere(
      (f) => !f.incoming && f.state == 'sent' && (f.id.startsWith(id) || (f.messageId?.startsWith(id) ?? false)),
      orElse: () => throw const XControlException('not_found', 'no such file, or the contact has answered it'),
    );
    final c = contactList.firstWhere((c) => c.linkId == f.linkId);
    final done = _copyFile(f,
        state: 'withdrawn', withdrawal: c.peerFileWithdraw ? 'contact_notified' : 'contact_cannot_withdraw');
    fileMap[done.id] = done;
    return done;
  }

  @override
  Future<FileInfo> fileReject(String id) async {
    _check();
    calls.add('file_reject');
    final done = _copyFile(_file(id), state: 'rejected');
    fileMap[done.id] = done;
    return done;
  }

  FileInfo _file(String id) => fileMap.values.firstWhere(
        (f) => f.id.startsWith(id),
        orElse: () => throw const XControlException('not_found', 'no such file'),
      );

  static FileInfo _copyFile(FileInfo f,
          {required String state, String? dest, String? savedAs, String? withdrawal, bool duplicate = false}) =>
      FileInfo(
        id: f.id,
        contact: f.contact,
        linkId: f.linkId,
        direction: f.direction,
        name: f.name,
        size: f.size,
        blake3: f.blake3,
        state: state,
        createdMs: f.createdMs,
        senderMime: f.senderMime,
        senderVerdict: f.senderVerdict,
        verdict: f.verdict,
        mime: f.mime,
        findings: f.findings,
        sandbox: f.sandbox,
        dest: dest ?? f.dest,
        savedAs: savedAs ?? f.savedAs,
        messageId: f.messageId,
        expiresMs: f.expiresMs,
        reason: f.reason,
        withdrawal: withdrawal ?? f.withdrawal,
        duplicate: duplicate,
        labels: f.labels,
        fileClass: f.fileClass,
      );

  // Streams and wake (x-control/4).

  /// The `streams` response (set by the test).
  List<StreamView> streamViews = [];

  /// Wake rules; the sandbox of this "OS".
  List<WakeRuleInfo> wakeRuleList = [];
  String wakeSandbox = 'bwrap';

  /// The last `wake_set` request (secrets included, so a test can check that the window passed them on).
  WakeSetRequest? lastWakeSet;

  @override
  Future<List<StreamView>> streams() async {
    _check();
    calls.add('streams');
    return streamViews;
  }

  WakeReply _wake() => WakeReply(
        rules: wakeRuleList,
        sandbox: wakeSandbox,
        sandboxDetail: wakeSandbox == 'none' ? 'no sandbox for agents on this OS' : 'namespaces, landlock, seccomp',
      );

  @override
  Future<WakeReply> wakeSet(WakeSetRequest request) async {
    _check();
    calls.add('wake_set');
    lastWakeSet = request;
    _pw('wake_set', request.password);
    if (wakeSandbox == 'none') {
      throw const XControlException(XErrorCode.sandboxUnavailable, 'no sandbox for agents on this OS');
    }
    final bad = request.argv.any((a) =>
        a.contains('dangerously') || a.contains('bypassPermissions') || a == '--yolo' || a == '--resume' || a == '--continue');
    if (bad) throw const XControlException(XErrorCode.denied, 'forbidden agent flag');
    final c = contactList.firstWhere((c) => c.linkId == request.contact || c.label == request.contact);
    final rule = WakeRuleInfo(
      contact: c.label,
      linkId: c.linkId,
      agent: 'wake-${c.label.split(' ').first.toLowerCase()}',
      argv: ['/usr/local/bin/${request.argv.first}', ...request.argv.skip(1)],
      mode: request.argv.contains('stream-json') ? 'claude_stream' : 'plain',
      timeoutSecs: request.timeoutSecs ?? 600,
      allowHosts: request.allowHosts,
      homeFiles: request.homeFiles ?? (request.argv.first.endsWith('claude') ? ['.claude/.credentials.json'] : const []),
      secretEnv: [for (final e in request.secretEnv) e.name],
      maxRunsPerHour: request.maxRunsPerHour ?? 20,
      createdMs: DateTime(2026, 10, 3, 9).millisecondsSinceEpoch,
    );
    wakeRuleList = [...wakeRuleList.where((r) => r.linkId != c.linkId), rule];
    return _wake();
  }

  @override
  Future<WakeReply> wakeList() async {
    _check();
    calls.add('wake_list');
    return _wake();
  }

  /// The owner's turns (`wake_say`) and session commands (`wake_session`) the window sent.
  final wakeSays = <(String, String, bool, FakeDialog)>[];
  final wakeSessions = <(String, ResidentAction, String?)>[];

  @override
  XDialog wakeSay(String contact, String text, {bool toContact = false, bool interrupt = false}) {
    final d = FakeDialog(WakeSayRequest(contact: contact, text: text, toContact: toContact, interrupt: interrupt));
    dialogs.add(d);
    wakeSays.add((contact, text, toContact, d));
    if (!wakeRuleList.any((r) => (r.contact == contact || r.linkId == contact) && r.resident != null)) {
      d.fail(const XControlException(XErrorCode.notFound, 'no resident rule for this contact'));
    }
    return d;
  }

  @override
  Future<ResidentSessionReply> wakeSession(String contact, ResidentAction action, {String? password}) async {
    _check();
    calls.add('wake_session');
    wakeSessions.add((contact, action, password));
    if (action == ResidentAction.reset) _pw('wake_session', password ?? '');
    final i = wakeRuleList.indexWhere((r) => (r.contact == contact || r.linkId == contact) && r.resident != null);
    if (i < 0) throw const XControlException(XErrorCode.notFound, 'no resident rule for this contact');
    final r = wakeRuleList[i];
    final old = r.resident!;
    final now = switch (action) {
      ResidentAction.reset => ResidentInfo(
          state: ResidentState.sleeping,
          idleStopSecs: old.idleStopSecs,
          compactIdleSecs: old.compactIdleSecs,
          compactAboveTokens: old.compactAboveTokens),
      ResidentAction.stop => ResidentInfo(
          state: ResidentState.sleeping,
          sessionId: old.sessionId,
          turns: old.turns,
          ownerTurns: old.ownerTurns,
          starts: old.starts,
          contextTokens: old.contextTokens,
          compactions: old.compactions,
          parked: true),
      ResidentAction.compact => ResidentInfo(
          state: old.state,
          sessionId: old.sessionId,
          turns: old.turns,
          ownerTurns: old.ownerTurns,
          starts: old.starts,
          contextTokens: 1200,
          compactions: old.compactions + 1),
      ResidentAction.status => old,
    };
    wakeRuleList = [...wakeRuleList]..[i] = r.withResident(now);
    return ResidentSessionReply(contact: r.contact, resident: now);
  }

  @override
  Future<WakeReply> wakeOff(String contact) async {
    _check();
    calls.add('wake_off');
    wakeRuleList = wakeRuleList.where((r) => r.linkId != contact && r.contact != contact).toList();
    return _wake();
  }

  // LAN (x-control/5).

  bool lanEnabled = false;
  bool lanListening = true;
  String? lanError;
  List<LanLink> lanLinks = [];

  LanReply _lan() => LanReply(
        enabled: lanEnabled,
        listening: lanEnabled && lanListening,
        error: lanEnabled && !lanListening ? lanError : null,
        links: lanLinks,
      );

  @override
  Future<LanReply> lanSet({required bool enabled, String? password}) async {
    _check();
    calls.add('lan_set');
    if (enabled) _pw('lan_set', password ?? '');
    lanEnabled = enabled;
    return _lan();
  }

  @override
  Future<LanReply> lanStatus() async {
    _check();
    calls.add('lan_status');
    return _lan();
  }

  static Map<String, Object?> _approvalJson(ApprovalInfo a) => {
        'id': a.id,
        'state': a.state,
        'quiet': a.quiet,
        'requester': a.requester,
        'contact': a.contact,
        'contact_trust': a.contactTrust,
        'action': a.action,
        'target': a.target,
        'reasons': a.reasons,
        'grants': {'read': a.grants.read, 'write': a.grants.write, 'commands': a.grants.commands, 'send': a.grants.send},
        'quote': a.quote,
        'fingerprint': a.fingerprint,
        'created_ms': a.createdMs,
        'expires_ms': a.expiresMs,
        'link_id': ?a.linkId,
        'target_link_id': ?a.targetLinkId,
        if (a.completes) 'completes': true,
      };
}
