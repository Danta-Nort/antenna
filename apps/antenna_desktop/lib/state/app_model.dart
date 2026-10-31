// SPDX-License-Identifier: AGPL-3.0-only
// Application state on top of XDaemon (x-control/1). Everything shown to the owner is either a fact from the daemon
// (status, contacts, history, subscribe events) or the UI's own conclusion, explicitly marked as such.
//
// How it works:
// - after unlock: `contacts` → `subscribe` (one long-lived connection) → `approvals`, `pairings`;
// - the chat is `history` in pages plus `message` / `message_status` events from the subscription;
// - the UI never calls `inbox`: it marks messages read, and unread messages are the queue of the CLI and agents;
// - transport and E2E facts (TLS group, libsignal session, queue) come from polling `contacts`; there are no events
//   for them.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../host/app_connect.dart';
import '../host/binaries.dart';
import '../host/cli_install.dart';
import '../host/daemon_host.dart';
import '../host/touch_id.dart';
import '../host/updater.dart';
import '../protocol/x_control.dart';
import 'agent_map.dart';
import 'agent_stop.dart';
import 'ai_apps_model.dart';
import 'appearance.dart' show AgentRunStore;
import 'approval_alerts.dart';
import 'approval_finish.dart';
import 'approvers.dart';
import 'auto_update.dart';
import 'chat_list.dart';
import 'chat_prefs.dart';
import 'code_mode.dart';
import 'code_restore.dart';
import 'code_shot.dart';
import 'code_wake.dart';
import 'conversation.dart';
import 'devices.dart';
import 'doctor.dart';
import 'drafts.dart';
import 'escalations.dart';
import 'file_prefs.dart';
import 'files.dart';
import 'lan.dart';
import 'local_models.dart';
import 'long_text.dart';
import 'owner_auth.dart';
import 'pairing.dart';
import 'pictures.dart';
import 'streams.dart';
import 'teams.dart';
import 'threads.dart';
import 'touch_id.dart';
import 'updates.dart';
import 'wake.dart';

/// `loginRequired`: keys are unlocked, but the window has no owner session (x-control/2, Q-14b); the password is
/// needed.
enum Phase { connecting, unreachable, uninitialized, locked, loginRequired, unlocked }

enum Delivery {
  /// The `send` request is still in flight.
  sending,

  /// The contact confirmed it was stored.
  delivered,

  /// In the daemon's queue: the contact is unreachable, retries with backoff (D-21).
  queued,

  /// Not delivered: rejected 5 times, a send error, or approval needed.
  failed;

  static Delivery? parse(String s) => switch (s) {
        'delivered' => Delivery.delivered,
        'queued' => Delivery.queued,
        'failed' => Delivery.failed,
        _ => null,
      };

  int get _rank => switch (this) {
        Delivery.sending => 0,
        Delivery.queued => 1,
        Delivery.delivered || Delivery.failed => 2,
      };

  /// The status only moves forward: events and the `send` reply arrive in any order.
  static Delivery? later(Delivery? a, Delivery? b) {
    if (a == null) return b;
    if (b == null) return a;
    return b._rank >= a._rank ? b : a;
  }
}

/// `receipt`: a receipt of an action taken on the contact's request (v2), shown as a service line, not a bubble.
enum EntryKind { incoming, outgoing, local, receipt }

/// A chat entry.
class ChatEntry {
  ChatEntry({
    required this.id,
    required this.kind,
    required this.text,
    required this.at,
    this.seq,
    this.delivery,
    this.lamport,
    this.error,
    this.approvalId,
    this.receipt,
    this.receiptOutgoing = false,
    this.viaAgent,
    this.to,
    this.toAgent,
    this.topic,
    this.unread = false,
    this.noteThread,
    this.address,
    this.noAgent = false,
    this.urgent = false,
  });

  factory ChatEntry.fromHistory(HistoryItem m) => ChatEntry(
        id: m.id,
        kind: m.isReceipt ? EntryKind.receipt : (m.outgoing ? EntryKind.outgoing : EntryKind.incoming),
        receipt: m.receipt,
        receiptOutgoing: m.outgoing,
        viaAgent: m.viaAgent,
        to: m.to,
        toAgent: m.toAgent,
        topic: m.topic,
        unread: !m.outgoing && m.unread,
        noAgent: m.outgoing && m.noAgent,
        urgent: m.urgent,
        text: m.text,
        at: DateTime.fromMillisecondsSinceEpoch(m.outgoing ? m.localMs : m.ts),
        seq: m.seq,
        delivery: m.outgoing ? Delivery.parse(m.status) : null,
        lamport: m.lamport,
      );

  String id;
  final EntryKind kind;
  String text;
  final DateTime at;

  /// The daemon's local order (the history cursor); `null` for entries created by the UI.
  int? seq;
  Delivery? delivery;
  int? lamport;
  String? error;

  /// The daemon's own words for [error] (English), shown with the code's explanation.
  String? errorMessage;

  /// The approval request without which the daemon will not send this text (secret scanner).
  String? approvalId;

  /// The receipt (for [EntryKind.receipt]).
  final ReceiptInfo? receipt;

  /// A receipt from this node (`out`) or the contact's node (`in`).
  final bool receiptOutgoing;

  /// v5: incoming, the contact's agent; outgoing, our own agent (CONTROL §17). `null` means the owner wrote it.
  String? viaAgent;

  /// v6 (CONTROL §20): `person` / `everyone` / `agent`; `null` means no address (an older node, or before v6).
  String? to;

  /// With `to: "agent"`: outgoing, the contact's agent; incoming, our own agent.
  String? toAgent;

  /// v6: the message's topic.
  TopicRef? topic;

  /// v6 (incoming): the owner has not read it yet.
  bool unread;

  /// A note of the window ([EntryKind.local]): the thread it was written in.
  final ThreadKey? noteThread;

  /// What the window sent this message with (v6), kept for a retry and for "Approve and send".
  MessageAddress? address;

  /// Ours, addressed to an agent the contact's node does not have (v7, PROTOCOL §23): nobody there reads it.
  bool noAgent;

  /// CONTROL §33: outgoing, sent (or, while sending, asked) as urgent; incoming, the daemon honoured the owner's urgent
  /// message. From the daemon's history; the window never decides it from the text.
  bool urgent;

  bool get outgoing => kind == EntryKind.outgoing;
}

/// Where the history of a link, or of one of its chats, has been read to.
class ChatPage {
  /// Cursor of the older page; `null` with [reachedStart] means the start of the history.
  int? nextBefore;
  bool loaded = false;
  bool loadingOlder = false;
  bool reachedStart = false;
}

/// The history of one link: its entries, how far the whole link was read (an older daemon), and how far each chat was
/// read (`history {chat}`, v7, CONTROL §26).
class ChatThread extends ChatPage {
  final List<ChatEntry> entries = [];

  /// Per chat of the link (the daemon reads by chat): how far it was read.
  final Map<ThreadKey, ChatPage> pages = {};

  ChatEntry? byId(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Add or update history entries, keeping `seq` order (entries without `seq` go last).
  void merge(Iterable<ChatEntry> items) {
    for (final it in items) {
      final ex = byId(it.id);
      if (ex != null) {
        ex
          ..seq = it.seq ?? ex.seq
          ..delivery = Delivery.later(ex.delivery, it.delivery)
          ..lamport = it.lamport ?? ex.lamport
          ..text = it.text
          ..viaAgent = it.viaAgent ?? ex.viaAgent
          ..to = it.to ?? ex.to
          ..toAgent = it.toAgent ?? ex.toAgent
          ..topic = it.topic ?? ex.topic
          ..unread = it.unread
          ..noAgent = ex.noAgent || it.noAgent
          ..urgent = it.urgent;
      } else {
        entries.add(it);
      }
    }
    _sort();
  }

  void _sort() {
    // Stable sort: history by seq, local/in-flight entries by time, after the known seqs.
    final indexed = entries.indexed.toList();
    indexed.sort((a, b) {
      final sa = a.$2.seq, sb = b.$2.seq;
      if (sa != null && sb != null) return sa.compareTo(sb);
      final t = a.$2.at.compareTo(b.$2.at);
      return t != 0 ? t : a.$1.compareTo(b.$1);
    });
    entries
      ..clear()
      ..addAll(indexed.map((e) => e.$2));
  }
}

typedef DaemonConnector = XDaemon Function(String socketPath);

class AppModel extends ChangeNotifier
    with
        FilesMixin,
        StreamsMixin,
        WakeMixin,
        LanMixin,
        CodeMixin,
        CodeWakeMixin,
        CodeShotMixin,
        CodeRestoreMixin,
        AgentStopMixin,
        AiAppsMixin,
        ApprovalFinishMixin,
        ConversationMixin,
        ChatListMixin,
        DoctorMixin,
        LocalModelsMixin,
        PicturesMixin,
        AutoUpdateMixin,
        TouchIdMixin,
        EscalationsMixin,
        TeamsMixin,
        DevicesMixin,
        ApprovalAlertsMixin,
        AgentMapMixin,
        ApproversMixin,
        LongTextMixin,
        DraftsMixin,
        ChatPrefsMixin,
        FilePrefsMixin {
  AppModel({
    required this.connector,
    required String socketPath,
    this.host,
    this.binaries,
    this.cliInstaller,
    this.updater,
    this.defaultSocket,
    this.agentHost,
    this.connectorFs,
    this.appLauncher,
    TouchIdHost? touchId,
    this.live = true,
    DateTime Function()? clock,
    this.factsEvery = const Duration(seconds: 10),
    this.pageSize = 50,
    AgentRunStore? agentRuns,
    ChatPrefsStore? chatPrefs,
  })  : _clock = clock ?? DateTime.now,
        _socketPath = socketPath,
        touchIdHost = touchId ?? const NoTouchId(),
        daemon = connector(socketPath) {
    agentRunStore = agentRuns;
    chatPrefsStore = chatPrefs;
  }

  /// Creates a client for a socket path (XControlClient for real, a fake in tests).
  final DaemonConnector connector;

  /// Background work (subscription, facts polling, reconnect). Disabled in golden tests.
  @override
  final bool live;
  final Duration factsEvery;
  final int pageSize;
  final DateTime Function() _clock;

  @override
  XDaemon daemon;
  String _socketPath;
  @override
  String get socketPath => _socketPath;

  /// What starts our own daemon (LaunchAgent / child process); `null` means the window does not start the daemon
  /// (`antennad` was not found, or the socket belongs to another daemon, for example forwarded over ssh).
  @override
  DaemonHost? host;

  /// Paths of `antennad` and `antenna` (for the "Connect an agent" screen).
  @override
  final CoreBinaries? binaries;

  /// "antenna command in the terminal": `null` if the app has no bundled CLI (nothing to install from).
  final CliInstaller? cliInstaller;

  /// Updates through the CLI (`antenna update`): `null` when no CLI was found.
  final AntennaUpdater? updater;

  /// Code mode: the terminal and the computer's environment for agent CLIs (`null`: no terminal here).
  @override
  final AgentHost? agentHost;

  /// Agents → AI apps: the apps' configuration files and the system's "open" (`null`: Connect writes nothing).
  @override
  final ConnectorFs? connectorFs;
  @override
  final AppLauncher? appLauncher;

  /// The Secure Enclave keys for Touch ID (macOS; [NoTouchId] elsewhere: nothing is offered).
  @override
  final TouchIdHost touchIdHost;

  /// Signed release manifests among accepted files, checked by the CLI on first sight (`null` without a CLI).
  late final ManifestChecks? manifestChecks = switch (updater) { final u? => ManifestChecks(u), null => null };

  /// The socket the `antenna` CLI finds by itself (without `ANTENNA_SOCKET`); any other socket is passed to agents
  /// explicitly.
  final String? defaultSocket;

  /// Agents must be given the socket explicitly (the window is not using the default socket).
  @override
  bool get socketNeedsEnv => defaultSocket != null && socketPath != defaultSocket;

  /// The window starts its own daemon if it does not respond (first launch, after a reboot).
  bool autoStartDaemon = true;
  bool _autoStartTried = false;

  /// The window is starting the daemon right now.
  bool startingDaemon = false;

  /// Why the daemon did not start.
  @override
  DaemonStartException? hostError;

  @override
  Phase phase = Phase.connecting;
  Object? lastError;
  @override
  HelloOk? hello;
  @override
  StatusReply? status;
  @override
  List<ContactInfo> contacts = const [];

  /// [contacts] came from the daemon at least once since the keys were unlocked (an empty list then means none).
  bool contactsLoaded = false;
  @override
  String? selectedLinkId;
  @override
  final Map<String, ChatThread> chats = {};

  /// Rekey per link (linkId → progress of the two codes).
  final Map<String, RekeyFlow> rekeys = {};

  /// The daemon supports owner sessions (x-control/2: `hello_ok` has `session`).
  bool sessionsSupported = false;

  /// The daemon speaks x-control/6 (CONTROL §20): addressing and topics, per-message `unread`, batch approvals, what
  /// each agent reads. An older daemon refuses the v6 hello and the client falls back to v5: the window then sends no
  /// addresses, groups threads by `via_agent` only and decides several approvals one by one.
  @override
  bool get addressing => controlVersion(hello?.proto) >= 6;

  @override
  int get daemonProto => controlVersion(hello?.proto);

  @override
  bool get watchWithoutSession => phase == Phase.loginRequired && !notOwner;

  XDialog? _ownerSession;
  int _sessionGen = 0;

  /// Invites held by the daemon (Q-7): from `pairings` and `invite` events.
  final Map<String, InviteInfo> invites = {};

  /// Approval requests awaiting the owner's decision.
  @override
  final Map<String, ApprovalInfo> approvals = {};
  int hiddenQuietApprovals = 0;

  /// A new request from an agent arrived (subscription event, not a re-read): the window may notify the owner (D-84).
  Stream<ApprovalInfo> get newApprovals => _newApprovals.stream;
  final _newApprovals = StreamController<ApprovalInfo>.broadcast();

  /// A new message arrived in a chat whose notifications ask for it (D-UI-32): the window may notify the owner, with
  /// the chat's name and nothing of the text (SPEC §11).
  Stream<ChatNotice> get newMessages => _newMessages.stream;
  final _newMessages = StreamController<ChatNotice>.broadcast();
  Timer? _approvalsTimer;

  /// The subscription is active (events are arriving).
  bool subscribed = false;
  bool busy = false;

  int _gen = 0; // generation of background work: a phase change stops the old one
  Timer? _factsTimer;
  Timer? _reconnectTimer;
  XDialog? _subscription;
  int _localSeq = 0;
  bool _disposed = false;

  @override
  DateTime now() => _clock();

  /// The connection's role is not owner (the process is in an agent's tree, D-28): the owner's UI must not run like
  /// this.
  bool get notOwner => hello?.role != null && hello!.role != 'owner';

  // Connection and keys.

  /// Switch the socket (another daemon, ssh forwarding) and connect.
  Future<void> useSocket(String path) async {
    if (path != _socketPath) host = null; // another daemon's socket: we never start our own daemon for it
    _socketPath = path;
    daemon = connector(path);
    _resetSession();
    await connect();
  }

  /// Start our own daemon and connect. Errors go to [hostError].
  Future<void> startDaemon() async {
    final h = host;
    if (h == null || startingDaemon) return;
    _autoStartTried = true;
    startingDaemon = true;
    hostError = null;
    _notify();
    try {
      await h.start();
      startingDaemon = false;
      await connect();
    } on DaemonStartException catch (e) {
      hostError = e;
      startingDaemon = false;
      _setPhase(Phase.unreachable);
    } finally {
      startingDaemon = false;
      _notify();
    }
  }

  /// Stop our own daemon (keys are wiped from memory). Autostart stays off until the next explicit "Start daemon".
  Future<void> stopDaemon() async {
    final h = host;
    if (h == null) return;
    _autoStartTried = true;
    _sessionGen++;
    daemon.sessionToken = null;
    await _ownerSession?.cancel();
    _ownerSession = null;
    await h.stop();
    forgetAgentTokens();
    _resetSession();
    lastError = const XDaemonUnreachable('', 'daemon stopped by the owner');
    _setPhase(Phase.unreachable);
  }

  /// The window is closing: a child daemon is stopped, a LaunchAgent stays.
  Future<void> onWindowExit() async => host?.onWindowExit();

  Future<void> connect() async {
    if (phase != Phase.unreachable) _setPhase(Phase.connecting);
    try {
      final h = await daemon.hello();
      hello = h;
      sessionsSupported = h.session != null;
      lastError = null;
      status = await daemon.status();
      // A daemon that restarted knows nothing of the window's terminals (agent_stop.dart).
      registerAgentTerminals();
      // A daemon that came up from an automatic update: its Code mode agents come back (code_restore.dart).
      restoreAfterUpdate();
      await refreshTouchId();
      switch (h.state) {
        case DaemonState.uninitialized:
          _setPhase(Phase.uninitialized);
        case DaemonState.locked || DaemonState.unknown:
          _setPhase(Phase.locked);
        case DaemonState.unlocked:
          if (!sessionsSupported || h.session == 'held') {
            await _enterUnlocked();
          } else {
            // The daemon is already running (LaunchAgent, the window was restarted): keys are unlocked, but the
            // window has no session.
            daemon.sessionToken = null;
            _setPhase(Phase.loginRequired);
          }
      }
      _notify();
    } on XClientException catch (e) {
      lastError = e;
      if (e is XDaemonUnreachable && host != null && autoStartDaemon && !_autoStartTried && !startingDaemon) {
        await startDaemon();
        return;
      }
      _setPhase(Phase.unreachable);
    }
  }

  /// Unlock the keystore and open the window's session. Returns the error or `null`.
  Future<Object?> unlock(String password) =>
      _keyOp(() => daemon.unlock(password), session: () => daemon.login(password));

  /// An owner session held by the `login {hold}` connection (CONTROL §3, §13): the token goes into every connection
  /// of the window. [login] opens it: with the password, or with a Touch ID proof (D-102).
  Future<void> _openSession(XDialog Function() login) async {
    final gen = ++_sessionGen;
    await _ownerSession?.cancel();
    final d = login();
    final got = Completer<String>();
    d.events.listen((e) {
      if (e is SessionEvent && !got.isCompleted) got.complete(e.token);
    });
    unawaited(d.result.then((_) {}, onError: (Object e) {
      if (!got.isCompleted) {
        got.completeError(e);
      } else if (gen == _sessionGen) {
        _sessionClosed(e);
      }
    }));
    final token = await got.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw const XProtocolException('no session event'),
    );
    daemon.sessionToken = token;
    _ownerSession = d;
  }

  /// The session connection closed: `lock`, a disconnect, the daemon stopped.
  void _sessionClosed(Object e) {
    daemon.sessionToken = null;
    _ownerSession = null;
    if (_disposed) return;
    if (e is XControlException && e.code == XErrorCode.locked) {
      _setPhase(Phase.locked);
    } else if (e is XDaemonUnreachable) {
      _fail(e);
    } else if (phase == Phase.unlocked) {
      _setPhase(Phase.loginRequired);
    }
  }

  /// Close the window's session (log out): keys stay unlocked for agents and the CLI with their own sessions.
  Future<void> logout() async {
    _sessionGen++;
    final d = _ownerSession;
    _ownerSession = null;
    daemon.sessionToken = null;
    await d?.cancel();
    forgetAgentTokens();
    _setPhase(Phase.loginRequired);
  }

  /// Create the device root key. Returns the error or `null`.
  Future<Object?> init(String password) =>
      _keyOp(() => daemon.init(password), session: () => daemon.login(password));

  /// Open an owner session in this window (keys are already unlocked). Returns the error or `null`.
  Future<Object?> login(String password) =>
      _keyOp(() async => DaemonState.unlocked, session: () => daemon.login(password));

  /// A way in other than the password (Touch ID, D-102): [op] changes the keys' state, [session] opens the session.
  /// A Touch ID failure inside [session] is thrown, not returned (the caller maps it).
  @override
  Future<Object?> keyOpWith(Future<DaemonState> Function() op, XDialog Function() session) =>
      _keyOp(op, session: session);

  Future<Object?> _keyOp(Future<DaemonState> Function() op, {XDialog Function()? session}) async {
    busy = true;
    _notify();
    try {
      final st = await op();
      lastError = null;
      status = await daemon.status();
      if (st == DaemonState.unlocked) {
        // The same entry opens the window's owner session (v2): one entry unlocks both keys and session.
        if (sessionsSupported && session != null) await _openSession(session);
        await _enterUnlocked();
        // The update came up locked (the keys did not come across): the agents come back once the owner unlocks.
        restoreAfterUpdate();
      }
      return null;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) {
        lastError = e;
        _setPhase(Phase.unreachable);
      }
      return e;
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  Future<void> recheckKeys() async {
    try {
      final h = await daemon.hello();
      hello = h;
      if (h.state == DaemonState.unlocked && phase == Phase.locked) {
        daemon.sessionToken = null;
        _setPhase(Phase.loginRequired);
      }
    } on XClientException catch (e) {
      _fail(e);
    }
  }

  @override
  void daemonFailed(Object e) => _fail(e);

  /// `antenna lock`: keys are locked, link networking stops, the subscription ends.
  Future<void> lock() async {
    try {
      _sessionGen++;
      daemon.sessionToken = null;
      final d = _ownerSession;
      _ownerSession = null;
      await d?.cancel();
      await daemon.lock();
      forgetAgentTokens();
      clearFiles();
      clearDrafts();
      clearStreams();
      clearWake();
      clearLocal();
      clearPictures();
      clearTeams();
      clearUpdateAuto();
      clearDevices();
      clearAgentMap();
      clearApprovers();
      _setPhase(Phase.locked);
      status = await daemon.status();
    } on XClientException catch (e) {
      _fail(e);
    }
    _notify();
  }

  Future<void> _enterUnlocked() async {
    _setPhase(Phase.unlocked);
    await refreshContacts();
    if (live) _startSubscription(_gen);
    await Future.wait(
        [refreshApprovals(), refreshQuestions(), refreshPairings(), _loadChats(), refreshFiles(), refreshWake(),
            refreshUpdateAuto(), refreshLocalModels(), refreshTeams(), refreshDevices(), refreshPictures()]);
    unawaited(resyncStreams());
    if (selectedLinkId == null && contacts.isNotEmpty) await select(contacts.first.linkId);
  }

  /// The chats of every link with their latest messages (`chats`, v7), for the list's rows; a chat's page loads when
  /// it opens. A daemon without chats: the previews as before.
  Future<void> _loadChats() async {
    if (!await refreshChats()) return _loadPreviews();
    for (final byKey in chatInfo.values) {
      for (final c in byKey.values) {
        final last = c.last;
        if (last != null) chats.putIfAbsent(c.linkId, ChatThread.new).merge([ChatEntry.fromHistory(last)]);
      }
    }
    contacts = _sorted(contacts);
    _notify();
  }

  /// The latest page of each link (a daemon without `chats`): the list groups its rows from it, so a contact's agent
  /// chats show before the link is opened. Before addressing (v5) there are no agent chats to find: one message is
  /// enough for the row's preview.
  Future<void> _loadPreviews() async {
    final limit = addressing ? pageSize : 1;
    for (final c in contacts) {
      if (chats[c.linkId] != null) continue;
      try {
        final h = await daemon.history(c.linkId, limit: limit);
        final t = chats.putIfAbsent(c.linkId, ChatThread.new)..merge(h.messages.map(ChatEntry.fromHistory));
        if (limit == pageSize) {
          t
            ..loaded = true
            ..nextBefore = h.nextBefore
            ..reachedStart = h.nextBefore == null;
        }
      } on XClientException catch (e) {
        _fail(e);
        return;
      }
    }
    contacts = _sorted(contacts);
    _notify();
  }

  void _setPhase(Phase p) {
    if (phase == p) return;
    phase = p;
    // Once in, a later lock is the owner's own: the gate after it waits for a click (D-131).
    if (p == Phase.unlocked) touchIdAtStart = false;
    _gen++;
    _factsTimer?.cancel();
    _factsTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final s = _subscription;
    _subscription = null;
    subscribed = false;
    if (s != null) unawaited(s.cancel());
    if (live && !_disposed) {
      if (p == Phase.unlocked) {
        _factsTimer = Timer.periodic(factsEvery, (_) => unawaited(refreshContacts()));
      } else if (p == Phase.unreachable) {
        _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(connect()));
      }
    }
    // Restored agents are watched without a session until the owner signs in (CONTROL §23).
    if (!_disposed) syncAgentWatches();
    _notify();
  }

  void _fail(Object e) {
    lastError = e;
    if (e is XDaemonUnreachable) {
      _setPhase(Phase.unreachable);
    } else if (e is XControlException && e.code == XErrorCode.locked) {
      _setPhase(Phase.locked);
    } else if (e is XControlException && e.code == XErrorCode.notInitialized) {
      _setPhase(Phase.uninitialized);
    } else if (e is XControlException && e.code == XErrorCode.loginRequired) {
      // The window's session is closed (expired, `logout` in another window): ask for the password again.
      daemon.sessionToken = null;
      _setPhase(Phase.loginRequired);
    }
    _notify();
  }

  void _resetSession() {
    contacts = const [];
    contactsLoaded = false;
    chats.clear();
    clearConversations();
    clearChats();
    clearPictures();
    rekeys.clear();
    invites.clear();
    approvals.clear();
    clearFinishing();
    clearLocal();
    clearTeams();
    clearAgentMap();
    clearApprovers();
    selectedLinkId = null;
    status = null;
    hello = null;
  }

  // Subscription.

  void _startSubscription(int gen) {
    final sub = daemon.subscribe();
    _subscription = sub;
    sub.events.listen((e) {
      if (gen == _gen) handleEvent(e);
    });
    sub.result.then((_) {}, onError: (Object e) async {
      if (gen != _gen || _disposed) return;
      subscribed = false;
      _notify();
      if (e is XControlException && e.code == XErrorCode.locked) {
        _setPhase(Phase.locked);
        status = await daemon.status().catchError((_) => status!);
        _notify();
      } else if (e is XControlException && e.code == XErrorCode.loginRequired) {
        _fail(e);
      } else if (e is XDaemonUnreachable) {
        _fail(e);
      } else {
        // Resubscribe after a second and reload the state: events during the gap may have been lost.
        await Future<void>.delayed(const Duration(seconds: 1));
        if (gen == _gen && phase == Phase.unlocked) {
          _startSubscription(gen);
          await _resync();
        }
      }
    });
  }

  /// Another own computer's requests that one of this computer's agents may answer as an approver (its status names
  /// them, CONTROL §31): an approver running in Code mode here gets one line per request, as its own watch would give.
  @override
  void onDevicesRead(DevicesReply r) {
    for (final d in r.devices) {
      for (final a in d.status?.approvals ?? const <DeviceApproval>[]) {
        for (final name in a.approvers) {
          onCodeToAnswer(name, '${d.contact}/${a.id}');
        }
      }
    }
  }

  /// A subscription event (public for tests and the future embedded core).
  /// The owner answered or set aside a question of [agent]: a Code mode agent gets one line (code_wake.dart).
  @override
  void onQuestionDecided(String agent) => onCodeAnswered(agent);

  void handleEvent(XEvent e) {
    switch (e) {
      case Subscribed():
        subscribed = true;
      case MessageEvent(:final linkId, :final message):
        final t = chats.putIfAbsent(linkId, ChatThread.new);
        final isNew = t.byId(message.id) == null;
        // An outgoing message the UI still shows as "sending": the event may overtake the `send` reply.
        if (message.outgoing && isNew) _adoptPending(t, message);
        applyFileReceipts([message]);
        t.merge([ChatEntry.fromHistory(message)]);
        onMessageArrived(message.id);
        onOutgoingMessage(linkId, message);
        final entry = t.byId(message.id);
        var readNow = false;
        if (!message.outgoing && !message.isReceipt && isNew) {
          onCodeMessage(e.contact, message);
          if (linkId != selectedLinkId) {
            _bumpUnread(linkId);
          } else if (!addressing) {
            readNow = true;
            unawaited(markLinkRead(linkId));
          } else {
            // Chats: only a message of the chat on screen is read; another chat keeps its count.
            if (entry != null && threadOf(entry) == openThreadOf(linkId)) {
              readNow = true;
              unawaited(markIdsRead(linkId, [message.id]));
            } else {
              if (entry != null) entry.unread = true;
              _bumpUnread(linkId);
            }
          }
          if (entry != null && chatNotifies(linkId, entry)) _newMessages.add(ChatNotice(linkId, threadOf(entry)));
        }
        if (isNew && entry != null) noteChatMessage(linkId, message, entry, read: readNow);
        if (message.topic != null && addressing && linkTopics.containsKey(linkId)) unawaited(refreshTopics(linkId));
        if (contactById(linkId) == null) unawaited(refreshContacts());
        contacts = _sorted(contacts);
      case HistoryEvent(:final linkId, :final status):
        _updateContact(linkId, (c) => c.copyWith(history: status));
        if (status.verified || status.state == 'unchecked') rekeys.remove(linkId);
      case RekeyEvent(:final contact, :final state):
        final c = contacts.where((x) => x.label == contact).firstOrNull;
        if (c != null) _onRekeyEvent(c.linkId, state);
      case MessageStatusEvent(:final linkId, :final id, :final status):
        final m = chats[linkId]?.byId(id);
        // The contact's node has no agent by that name (v7): the message stays delivered, and says so
        if (status == 'no_agent' && m != null) m.noAgent = true;
        final d = Delivery.parse(status);
        if (m != null && d != null) m.delivery = d;
        if (d == Delivery.failed) unawaited(refreshContacts());
      case ContactEvent(:final contact):
        final i = contacts.indexWhere((c) => c.linkId == contact.linkId);
        if (i < 0) {
          unawaited(refreshContacts());
        } else {
          contacts = [...contacts]
            ..[i] = contacts[i].copyWith(
                trust: contact.trust, netMode: contact.netMode, presence: contact.presence, peerKind: contact.peerKind);
          // An announced agent: the contact's agent list comes from `contacts`.
          if (contact.peerKind != null) unawaited(refreshContacts());
        }
      case InviteEvent(:final invite):
        // The event carries the phase without the link and code; keep the ones revealed with the password.
        invites[invite.id] = invite.mergedOver(invites[invite.id]);
        if (invite.phase == 'linked') unawaited(refreshContacts());
      case ApprovalEvent(:final approval):
        onApprovalForApprovers(approval);
        if (approval.pending) {
          final isNew = !approvals.containsKey(approval.id);
          approvals[approval.id] = approval;
          if (isNew && approval.byAgent && !approval.quiet) _newApprovals.add(approval);
          // An approver running in Code mode here may answer it: one line for it (code_wake.dart)
          if (isNew) onCodeToAnswerLocal(approval);
        } else {
          // Decided, used up or expired (the daemon closes an unanswered request by itself, D-84). An approved request
          // the daemon finishes itself stays as "finishing" until its outcome.
          if (approval.state == 'approved') {
            _approved(approval);
          } else {
            onApprovalClosed(approval);
          }
          approvals.remove(approval.id);
          if (approval.quiet) unawaited(refreshApprovals());
        }
        _scheduleApprovalsCheck();
      case ApprovalResolvedEvent():
        onApprovalResolved(e);
      case FileEvent():
        onFileEvent(e);
      case MessageStreamEvent():
        onStreamEvent(e);
      case WakeEvent():
        onWakeEvent(e);
        unawaited(refreshWake());
      case UpdateAutoEvent():
        onUpdateAutoEvent(e);
      case AgentEvent():
        // An app's MCP server bound its token, a token was replaced, an agent added or removed: the Agents section
        // and the AI apps rows show it at once (process exits are seen by polling `agent_list`).
        unawaited(refreshAgents());
        onAgentMapEvent();
        if (e.change == 'approver') onApproversChanged();
        onAgentStopped(e);
      case LocalModelEvent() || LocalAgentEvent():
        onLocalEvent(e);
      case TeamEvent():
        onTeamEvent(e);
      case DeviceEvent():
        onDeviceEvent(e);
        onAgentMapEvent();
        if (e.change == 'approvers') onApproversChanged();
      case ChatEvent(:final chat):
        onChatEvent(chat);
      case EscalationEvent(:final escalation):
        onEscalationEvent(escalation);
      case PictureEvent(:final entry):
        onPictureEvent(entry);
      case Lagged():
        unawaited(_resync());
        unawaited(resyncStreams());
      default:
        break;
    }
    _notify();
  }

  void _adoptPending(ChatThread t, HistoryItem m) {
    for (final e in t.entries) {
      if (e.outgoing && e.delivery == Delivery.sending && e.seq == null && e.text == m.text) {
        e.id = m.id;
        return;
      }
    }
  }

  Future<void> _resync() async {
    await refreshContacts();
    if (chatsSupported) {
      await refreshChats();
      for (final id in chats.keys.toList()) {
        for (final k in chats[id]!.pages.keys.toList()) {
          if (chats[id]!.pages[k]!.loaded) await loadChatPage(id, k, reset: true);
        }
      }
    } else {
      for (final id in chats.keys.toList()) {
        if (chats[id]!.loaded) await loadHistory(id, reset: true);
      }
    }
    await Future.wait(
        [refreshApprovals(), refreshQuestions(), refreshPairings(), refreshFiles(), refreshLocalModels(), refreshTeams(),
            refreshDevices(), refreshPictures()]);
  }

  // Contacts.

  @override
  Future<void> refreshContacts() async {
    if (phase != Phase.unlocked) return;
    try {
      final list = await daemon.contacts();
      contacts = _sorted(list);
      contactsLoaded = true;
      if (selectedLinkId != null && !list.any((c) => c.linkId == selectedLinkId)) selectedLinkId = null;
      // A count read elsewhere (another window, `antenna inbox`): the chats are asked again
      reconcileChats();
      _notify();
    } on XClientException catch (e) {
      _fail(e);
    }
  }

  List<ContactInfo> _sorted(List<ContactInfo> list) {
    int activity(ContactInfo c) {
      final last = lastEntry(c.linkId);
      return last?.at.millisecondsSinceEpoch ?? c.createdMs;
    }

    return [...list]..sort((a, b) => activity(b).compareTo(activity(a)));
  }

  @override
  ContactInfo? contactById(String linkId) {
    for (final c in contacts) {
      if (c.linkId == linkId) return c;
    }
    return null;
  }

  @override
  void safeNotify() => _notify();

  @override
  bool hasMessage(String linkId, String messageId) => chats[linkId]?.byId(messageId) != null;

  @override
  DateTime streamNow() => now();

  ContactInfo? get selected => selectedLinkId == null ? null : contactById(selectedLinkId!);

  /// Open a link: [chat], or the chat the owner had open there, or the one with the latest message (D-UI-32: the list
  /// opens a row's own chat; the contact's row is the person chat).
  Future<void> select(String linkId, {ThreadKey? chat}) async {
    selectedLinkId = linkId;
    selectedLocalAgent = null;
    if (chat != null) showThread(linkId, chat);
    _notify();
    if (chatsSupported) {
      openDefaultThread(linkId);
      final k = openThreadOf(linkId);
      final p = chats[linkId]?.pages[k];
      if (p == null || !p.loaded) await loadChatPage(linkId, k);
    } else {
      final t = chats[linkId];
      if (t == null || !t.loaded) await loadHistory(linkId);
      openDefaultThread(linkId);
    }
    if (addressing) await refreshTopics(linkId);
    await markOpenThreadRead(linkId);
  }

  /// How far the conversation on screen was read: the open chat's pages (v7), or the whole link's.
  ChatPage pagingOf(String linkId) {
    final t = chats.putIfAbsent(linkId, ChatThread.new);
    if (!chatsSupported) return t;
    return t.pages.putIfAbsent(openThreadOf(linkId), ChatPage.new);
  }

  /// A page of one chat of a link (`history {chat}`, v7): the latest, or the next older one with [older]; [reset]
  /// forgets what was loaded of this chat first (after `lagged`).
  Future<void> loadChatPage(String linkId, ThreadKey k, {bool older = false, bool reset = false}) async {
    final t = chats.putIfAbsent(linkId, ChatThread.new);
    final p = t.pages.putIfAbsent(k, ChatPage.new);
    if (older && (p.reachedStart || p.loadingOlder || p.nextBefore == null)) return;
    p.loadingOlder = older;
    _notify();
    try {
      final h = await daemon.history(linkId,
          before: older ? p.nextBefore : null, limit: pageSize, chat: ChatListMixin.refOf(k));
      if (reset) t.entries.removeWhere((e) => e.seq != null && threadOf(e) == k);
      applyFileReceipts(h.messages);
      h.messages.map((x) => x.id).forEach(onMessageArrived);
      t
        ..merge(h.messages.map(ChatEntry.fromHistory))
        ..loaded = true;
      p
        ..loaded = true
        ..nextBefore = h.nextBefore
        ..reachedStart = h.nextBefore == null;
      contacts = _sorted(contacts);
    } on XClientException catch (e) {
      _fail(e);
    } finally {
      p.loadingOlder = false;
      _notify();
    }
  }

  /// Unread count (v2: from the daemon, `contacts[].unread`).
  int unreadOf(ContactInfo c) => c.unread;

  void _bumpUnread(String linkId) => _updateContact(linkId, (c) => c.copyWith(unread: c.unread + 1));

  @override
  void updateContact(String linkId, ContactInfo Function(ContactInfo) f) => _updateContact(linkId, f);

  void _updateContact(String linkId, ContactInfo Function(ContactInfo) f) {
    final i = contacts.indexWhere((c) => c.linkId == linkId);
    if (i >= 0) contacts = [...contacts]..[i] = f(contacts[i]);
  }

  /// Mark read up to the last incoming message in the chat (`mark_read`, v2).
  @override
  Future<void> markLinkRead(String linkId) async {
    final entries = chats[linkId]?.entries ?? const <ChatEntry>[];
    int? upTo;
    for (final e in entries) {
      if (e.kind == EntryKind.incoming && e.seq != null && (upTo == null || e.seq! > upTo)) upTo = e.seq;
    }
    if (upTo == null || !sessionsSupported) {
      _updateContact(linkId, (c) => c.copyWith(unread: 0));
      _notify();
      return;
    }
    try {
      final c = await daemon.markRead(linkId, upTo);
      for (final e in entries) {
        if (e.seq != null && e.seq! <= upTo) e.unread = false;
      }
      _updateContact(linkId, (_) => c);
      _notify();
    } on XClientException catch (e) {
      _fail(e);
    }
  }

  @override
  List<ChatEntry> chatOf(String linkId) => chats[linkId]?.entries ?? const [];

  ChatEntry? lastEntry(String linkId) {
    final c = chats[linkId]?.entries;
    if (c == null) return null;
    for (var i = c.length - 1; i >= 0; i--) {
      if (c[i].kind != EntryKind.local && c[i].kind != EntryKind.receipt) return c[i];
    }
    return null;
  }

  /// Presence, subject to trust level (SPEC §4): `true`/`false` for 3–5, `null` when not tracked (1–2).
  bool? presenceOf(ContactInfo c) => switch (c.presence) {
        'online' => true,
        'offline' => false,
        'not_tracked' => null,
        _ => c.trust >= 3 ? c.transport.connected : null, // daemon x-control/0
      };

  /// Change the trust level (the owner's password or one touch, D-131). Returns the error or `null`.
  Future<Object?> setTrust(String linkId, int level, OwnerAuth auth) async {
    try {
      final c = await ownerOp(auth, (d, pw) => d.trust(linkId, level, pw));
      final i = contacts.indexWhere((x) => x.linkId == c.linkId);
      if (i >= 0) contacts = [...contacts]..[i] = c;
      _notify();
      return null;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) _fail(e);
      return e;
    }
  }

  // History and messages.

  /// The latest history page (or the next older one with [older]): of the open chat when the daemon reads by chat.
  Future<void> loadHistory(String linkId, {bool older = false, bool reset = false}) async {
    if (chatsSupported) return loadChatPage(linkId, openThreadOf(linkId), older: older, reset: reset);
    final t = chats.putIfAbsent(linkId, ChatThread.new);
    if (older && (t.reachedStart || t.loadingOlder || t.nextBefore == null)) return;
    t.loadingOlder = older;
    _notify();
    try {
      final h = await daemon.history(linkId, before: older ? t.nextBefore : null, limit: pageSize);
      if (reset) t.entries.removeWhere((e) => e.seq != null);
      applyFileReceipts(h.messages);
      h.messages.map((x) => x.id).forEach(onMessageArrived);
      t
        ..merge(h.messages.map(ChatEntry.fromHistory))
        ..loaded = true
        ..nextBefore = h.nextBefore
        ..reachedStart = h.nextBefore == null;
      contacts = _sorted(contacts);
    } on XClientException catch (e) {
      _fail(e);
    } finally {
      t.loadingOlder = false;
      _notify();
    }
  }

  /// Send text to the selected contact (`antenna send`). [approvalId] is an approved approval request (secret
  /// scanner). [urgent] (CONTROL §33): interrupt the addressed agent of an own computer now (the composer offers it
  /// only there); a retry keeps what its message asked. Returns the daemon's reply (`null`: not sent): with urgent,
  /// `urgent: false` says it went as a normal message.
  Future<SentReply?> send(String text, {String? approvalId, ChatEntry? retry, bool urgent = false}) async {
    final c = selected;
    if (c == null || text.trim().isEmpty) return null;
    final t = chats.putIfAbsent(c.linkId, ChatThread.new);
    // v6: the address and topic chosen in the composer (a retry keeps the ones it was first sent with).
    final topicChoice = topicChoiceOf(c.linkId);
    final address = retry?.address ?? (addressing ? addressFor(recipientOf(c.linkId), topicChoice) : null);
    final entry = retry ??
        ChatEntry(
          id: 'local-${_localSeq++}',
          kind: EntryKind.outgoing,
          text: text,
          at: now(),
          delivery: Delivery.sending,
          to: address?.to,
          toAgent: address?.toAgent,
          topic: address == null || topicChoice.isNone
              ? null
              : TopicRef(id: address.topicId ?? '', title: topicChoice.title ?? ''),
          address: address,
          urgent: urgent,
        );
    final asUrgent = retry?.urgent ?? urgent;
    entry
      ..delivery = Delivery.sending
      ..error = null
      ..errorMessage = null;
    if (retry == null) {
      t.entries.add(entry);
      follow(c.linkId, entry, topicChoice);
    }
    contacts = _sorted(contacts);
    _notify();
    SentReply? reply;
    try {
      final r = reply = await daemon.send(c.linkId, text,
          address: address, approvalId: approvalId, urgent: asUrgent && address?.to == 'agent');
      if (r.to != null) {
        entry
          ..to = r.to
          ..toAgent = r.toAgent;
      }
      if (r.topic != null) {
        entry.topic = r.topic;
        // A new topic now has an ID: the next messages continue it.
        keepNewTopic(c.linkId, topicChoice, r.topic!);
        unawaited(refreshTopics(c.linkId));
      }
      final dup = t.byId(r.id);
      if (dup != null && !identical(dup, entry)) {
        t.entries.remove(entry); // the subscription already delivered this message
      } else {
        entry
          ..id = r.id
          ..lamport = r.lamport;
      }
      final target = dup ?? entry;
      target
        ..delivery = Delivery.later(target.delivery, r.delivered ? Delivery.delivered : Delivery.queued)
        ..approvalId = null
        ..noAgent = target.noAgent || r.noAgent;
      // The flag went, or their Antenna cannot take it and the message went as a normal one.
      if (r.urgent != null) target.urgent = r.urgent!;
    } on XControlException catch (e) {
      entry
        ..delivery = Delivery.failed
        ..error = e.code
        ..errorMessage = e.message;
      if (e.code == XErrorCode.approvalRequired && e.approval != null) {
        final a = ApprovalInfo.fromJson(e.approval!);
        entry.approvalId = a.id;
        approvals[a.id] = a;
      }
      _fail(e);
    } on XClientException catch (e) {
      entry
        ..delivery = Delivery.failed
        ..error = e is XDaemonUnreachable ? 'daemon_unreachable' : 'protocol';
      _fail(e);
    }
    _notify();
    return reply;
  }

  /// The UI's own output in the chat (the result of a slash command). Never sent to the contact and never stored.
  void addLocalNote(String text) {
    final c = selected;
    if (c == null) return;
    chats.putIfAbsent(c.linkId, ChatThread.new).entries.add(ChatEntry(
          id: 'note-${_localSeq++}',
          kind: EntryKind.local,
          text: text,
          at: now(),
          noteThread: openThreadOf(c.linkId),
        ));
    _notify();
  }

  Future<StatusReply?> refreshStatus() async {
    try {
      status = await daemon.status();
      _notify();
      return status;
    } on XClientException catch (e) {
      _fail(e);
      return null;
    }
  }

  // Approvals.

  Future<void> refreshApprovals() async {
    try {
      final r = await daemon.approvals();
      approvals
        ..clear()
        ..addEntries(r.approvals.where((a) => a.pending).map((a) => MapEntry(a.id, a)));
      hiddenQuietApprovals = r.hiddenQuiet;
      _scheduleApprovalsCheck();
      _notify();
    } on XClientException catch (e) {
      _fail(e);
    }
  }

  /// Re-read the requests shortly after the earliest one runs out. The daemon announces the expiry itself (D-84);
  /// this also covers a daemon older than that and a missed event.
  void _scheduleApprovalsCheck() {
    scanApprovalAlerts();
    _approvalsTimer?.cancel();
    _approvalsTimer = null;
    if (!live || _disposed || approvals.isEmpty) return;
    final first = approvals.values.map((a) => a.expiresMs).reduce((a, b) => a < b ? a : b);
    final wait = Duration(milliseconds: first - now().millisecondsSinceEpoch + 1500);
    final clamped = wait < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : (wait > const Duration(minutes: 11) ? const Duration(minutes: 11) : wait);
    _approvalsTimer = Timer(clamped, () {
      if (phase == Phase.unlocked) unawaited(refreshApprovals());
    });
  }

  /// Pending requests from agents shown in the conversation with [linkId]: the contact the request is about, or the
  /// recipient of what it would send (D-84). An older daemon gives no link IDs, so the labels are matched.
  List<ApprovalInfo> approvalsFor(String linkId) {
    final label = contactById(linkId)?.label;
    return approvals.values.where((a) => a.pending && a.byAgent && approvalConcerns(a, linkId, label)).toList()
      ..sort((a, b) => a.createdMs.compareTo(b.createdMs));
  }

  /// [a] is approved: a card the daemon finishes stays as "finishing"; an agent running here gets "Approved —
  /// continue." typed into its terminal once it is idle (D-UI-23). Call before the request leaves [approvals].
  void _approved(ApprovalInfo a) {
    onApproved(a, shown: approvals[a.id]);
    onCodeApproved(a);
  }

  /// Allow once (owner password). Returns the error or `null`.
  Future<Object?> approve(String id, String password) => _decide(id, () => daemon.approve(id, password));

  /// Deny; with [hour], also deny everything from this contact for the next hour. No password (D-84): a refusal only
  /// reduces what happens. [password] is only for a daemon older than that ([denyNeedsPassword]).
  Future<Object?> deny(String id, {bool hour = false, String? password}) =>
      _decide(id, () => daemon.deny(id, hour: hour, password: password));

  /// A daemon older than D-84 still requires the password to deny: it rejects the request without it.
  static bool denyNeedsPassword(Object? err) =>
      err is XControlException && err.code == XErrorCode.badRequest && err.message.contains('password');

  @override
  Future<Object?> decideApproval(String id, Future<ApprovalInfo> Function() op) => _decide(id, op);

  @override
  void applyApprovalResults(List<ApprovalResult> results) => _applyResults(results);

  Future<Object?> _decide(String id, Future<ApprovalInfo> Function() op) async {
    try {
      final a = await op();
      if (a.pending) {
        approvals[a.id] = a;
      } else {
        if (a.state == 'approved') _approved(a);
        approvals.remove(a.id);
      }
      _scheduleApprovalsCheck();
      _notify();
      return null;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) _fail(e);
      // The request is already closed (its time ran out, or it is gone): nothing to show any more.
      if (e is XControlException && (e.code == XErrorCode.approvalExpired || e.code == XErrorCode.notFound)) {
        approvals.remove(id);
        _notify();
      }
      return e;
    }
  }

  /// Approve several requests with the password the owner typed once (v6 `approve_many`: the daemon checks it once and
  /// approves each request on its own, with its fingerprint). An older daemon gets `approve` per request with the same
  /// password, stopping at the first error that is about the password, not the request. Returns one result per
  /// request and the error of the whole call (a wrong password: nothing was approved).
  Future<(List<ApprovalResult>, Object?)> approveMany(List<ApprovalInfo> items, String password) async {
    final results = <ApprovalResult>[];
    try {
      if (addressing) {
        results.addAll(await daemon.approveMany(
          [for (final a in items) ApproveItem(a.id, fingerprint: a.fingerprint)],
          password,
        ));
      } else {
        for (final a in items) {
          try {
            results.add(ApprovalResult(id: a.id, approval: await daemon.approve(a.id, password)));
          } on XControlException catch (e) {
            if (_aboutTheCall(e) && results.isEmpty) rethrow;
            results.add(ApprovalResult(id: a.id, error: e));
            if (_aboutTheCall(e)) break;
          }
        }
      }
      _applyResults(results);
      return (results, null);
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) _fail(e);
      return (results, e);
    }
  }

  /// Deny several requests, no password (v6 `deny_many`; an older daemon: `deny` per request, and [password] only for
  /// a daemon older than D-84, see [denyNeedsPassword]).
  Future<(List<ApprovalResult>, Object?)> denyMany(List<String> ids, {bool hour = false, String? password}) async {
    final results = <ApprovalResult>[];
    try {
      if (addressing) {
        results.addAll(await daemon.denyMany(ids, hour: hour));
      } else {
        for (final id in ids) {
          try {
            results.add(ApprovalResult(id: id, approval: await daemon.deny(id, hour: hour, password: password)));
          } on XControlException catch (e) {
            final stop = denyNeedsPassword(e) || _aboutTheCall(e);
            if (stop && results.isEmpty) rethrow;
            results.add(ApprovalResult(id: id, error: e));
            if (stop) break;
          }
        }
      }
      _applyResults(results);
      return (results, null);
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) _fail(e);
      return (results, e);
    }
  }

  /// An error about the password or the session, not about one request: repeating it per request would only add
  /// wrong attempts (the daemon pauses after three).
  static bool _aboutTheCall(XControlException e) => const {
        XErrorCode.wrongPassword,
        XErrorCode.rateLimited,
        XErrorCode.locked,
        XErrorCode.loginRequired,
        XErrorCode.notInitialized,
      }.contains(e.code);

  /// Decided requests leave the list; a request that is closed already (expired, gone, used) leaves it too.
  void _applyResults(List<ApprovalResult> results) {
    for (final r in results) {
      final a = r.approval;
      if (a != null) {
        if (a.pending) {
          approvals[a.id] = a;
        } else {
          if (a.state == 'approved') _approved(a);
          approvals.remove(a.id);
        }
      } else if (const {
        XErrorCode.approvalExpired,
        XErrorCode.notFound,
        XErrorCode.approvalUsed,
        XErrorCode.approvalDenied,
      }.contains(r.error?.code)) {
        approvals.remove(r.id);
      }
    }
    _scheduleApprovalsCheck();
    _notify();
  }

  // History verification, rekey, link management (x-control/2, CONTROL §12).

  /// Verify history now ([accept] accepts a divergence, with password; [repair] restores our copy).
  /// Returns the error or `null`.
  Future<Object?> verify(String linkId, {bool accept = false, bool repair = false, OwnerAuth? auth}) async {
    try {
      final r = auth == null
          ? await daemon.verify(linkId, accept: accept, repair: repair)
          : await ownerOp(auth, (d, pw) => d.verify(linkId, accept: accept, repair: repair, password: pw));
      _updateContact(linkId, (c) => c.copyWith(history: r.status));
      _notify();
      if (repair) await loadHistory(linkId, reset: true);
      return null;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable || (e is XControlException && e.code == XErrorCode.loginRequired)) _fail(e);
      return e;
    }
  }

  /// Rename a contact (the label is visible only to you). Returns the error or `null`.
  Future<Object?> rename(String linkId, String label) async {
    try {
      final c = await daemon.rename(linkId, label);
      _updateContact(linkId, (_) => c);
      _notify();
      return null;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) _fail(e);
      return e;
    }
  }

  /// Delete a link: keys are wiped, the channel is closed; history optionally. Returns the error or `null`.
  Future<Object?> revoke(String linkId, OwnerAuth auth, {bool deleteHistory = false}) async {
    try {
      await ownerOp(auth, (d, pw) => d.revoke(linkId, pw, deleteHistory: deleteHistory));
      if (deleteHistory) forgetSentPreviews(linkId);
      contacts = contacts.where((c) => c.linkId != linkId).toList();
      chats.remove(linkId);
      rekeys.remove(linkId);
      if (selectedLinkId == linkId) selectedLinkId = contacts.isEmpty ? null : contacts.first.linkId;
      _notify();
      await refreshContacts();
      return null;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) _fail(e);
      return e;
    }
  }

  RekeyFlow rekeyOf(String linkId) => rekeys.putIfAbsent(linkId, RekeyFlow.new);

  void _onRekeyEvent(String linkId, String state) {
    final f = rekeyOf(linkId);
    switch (state) {
      case 'requested_by_contact':
        f
          ..stage = RekeyStage.enterFirstCode
          ..error = null;
      case 'confirm_contact_code':
        f
          ..stage = RekeyStage.enterSecondCode
          ..error = null;
      case 'conflicting_offers':
        f
          ..stage = RekeyStage.conflict
          ..code = null
          ..codeEmoji = null;
      case 'done':
        f
          ..stage = RekeyStage.done
          ..code = null
          ..codeEmoji = null;
        unawaited(refreshContacts());
      default:
        break;
    }
  }

  /// A rekey step: without [code], propose (the side that rolled back); with [code], the code read out by the contact.
  /// Returns the error or `null`.
  Future<Object?> rekey(String linkId, OwnerAuth auth, {String? code}) async {
    final f = rekeyOf(linkId);
    f.busy = true;
    _notify();
    try {
      final r = await ownerOp(auth, (d, pw) => d.rekey(linkId, pw, code: code));
      f.error = null;
      if (r.done) {
        f
          ..stage = RekeyStage.done
          ..code = null
          ..codeEmoji = null;
        await refreshContacts();
      } else {
        // waiting_for_contact: the code this owner now reads out (the first one on the side that rolled back,
        // the second on the accepting side).
        f
          ..code = r.code
          ..codeEmoji = r.codeEmoji
          ..stage = code == null ? RekeyStage.myCodeShown : RekeyStage.secondCodeShown;
      }
      return null;
    } on XClientException catch (e) {
      // A touch that did not go through is not the rekey's error: the screen asks for the password instead.
      if (TouchIdMixin.fallbackFor(e) == TouchIdFallback.none) f.error = e;
      if (e is XDaemonUnreachable) _fail(e);
      return e;
    } finally {
      f.busy = false;
      _notify();
    }
  }

  // The owner's agents.

  /// This node's agents (`antenna agent list`).
  @override
  List<AgentInfo> agents = const [];

  @override
  Future<void> refreshAgents() async {
    try {
      agents = await daemon.agents();
      _notify();
    } on XClientException catch (e) {
      _fail(e);
    }
  }

  /// Issue a token (owner password). The daemon also writes it to the agent's token file (preview.4), so the window
  /// shows the file's path, not the token; an older daemon rejects the field, and then the token is shown once with a
  /// warning. The window does not store it.
  Future<(AgentAddedReply?, Object?)> addAgent({
    required String name,
    required int localLevel,
    required OwnerAuth auth,
    List<String>? links,
    bool everyone = false,
  }) async {
    // v6: whether the agent also reads messages to everyone; never sent to an older daemon (it rejects the field).
    final ev = addressing ? everyone : null;
    try {
      AgentAddedReply r;
      try {
        r = await ownerOp(auth, (d, pw) => d.agentAdd(name,
            localLevel: localLevel, password: pw, links: links, tokenFile: true, everyone: ev));
      } on XControlException catch (e) {
        if (e.code != XErrorCode.badRequest || !e.message.contains('token_file')) rethrow;
        // An older daemon (before token files) takes no proof either: this second call has the password.
        if (auth is! PasswordAuth) rethrow;
        r = await daemon.agentAdd(name, localLevel: localLevel, password: auth.password, links: links, everyone: ev);
      }
      await refreshAgents();
      return (r, null);
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) _fail(e);
      return (null, e);
    }
  }

  /// What an agent reads (v6): turning "messages to everyone" on needs the owner password, off does not. Returns the
  /// error or `null`.
  Future<Object?> setAgentEveryone(String name, {required bool everyone, OwnerAuth? auth}) async {
    try {
      agents = everyone && auth != null
          ? await ownerOp(auth, (d, pw) => d.agentSet(name, everyone: true, password: pw))
          : await daemon.agentSet(name, everyone: everyone);
      _notify();
      return null;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) _fail(e);
      return e;
    }
  }

  /// Revoke an agent's token (the owner's password or one touch). Returns the error or `null`.
  Future<Object?> removeAgent(String name, OwnerAuth auth) async {
    try {
      await ownerOp(auth, (d, pw) => d.agentRemove(name, pw));
      await refreshAgents();
      return null;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) _fail(e);
      return e;
    }
  }

  // Pairing.

  Future<void> refreshPairings() async {
    try {
      final list = await daemon.pairings();
      final old = Map.of(invites);
      invites
        ..clear()
        ..addEntries(list.map((i) => MapEntry(i.id, i.mergedOver(old[i.id]))));
      _notify();
    } on XClientException catch (e) {
      _fail(e);
    }
  }

  /// Reveal the invites' link and code (owner password). Returns the error or `null`.
  Future<Object?> revealInvites(OwnerAuth auth) async {
    try {
      final list = await ownerOp(auth, (d, pw) => d.pairings(password: pw));
      for (final i in list) {
        invites[i.id] = i;
      }
      _notify();
      return null;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) _fail(e);
      return e;
    }
  }

  /// Live invites (not finished and not expired), newest first.
  List<InviteInfo> get pendingInvites {
    final t = now().millisecondsSinceEpoch;
    return invites.values.where((i) => !i.finished && i.expiresMs > t).toList()
      ..sort((a, b) => b.createdMs.compareTo(a.createdMs));
  }

  InviteSession startInvite({required int trust, required Duration ttl, required OwnerAuth auth, String? label}) {
    final (via, pw) = ownerDaemon(auth);
    final d = via.open(InviteRequest(trust: trust, ttlSecs: ttl.inSeconds, label: label, password: pw));
    final s = InviteSession(d, trust: trust, ttl: ttl, label: label);
    _watchPairing(s, () => s.linked);
    return s;
  }

  JoinSession startJoin({required String link, required int trust, required OwnerAuth auth, String? label}) {
    final (via, pw) = ownerDaemon(auth);
    final d = via.open(JoinRequest(link: link.trim(), trust: trust, label: label, password: pw));
    final s = JoinSession(d, trust: trust, label: label);
    _watchPairing(s, () => s.linked);
    return s;
  }

  /// Confirm an invite created outside this window (`antenna invite`): the owner enters [code], the one they read out
  /// and had confirmed; the window never fills it in. Without [code] (D-95) the owner's click is the confirmation,
  /// offered only when the invite says [InviteInfo.confirmWithoutCode]; the password is asked either way. Returns the
  /// error or `null` (`code_required` / `bad_request`: the daemon wants the code after all).
  Future<Object?> confirmInvite(String id, OwnerAuth auth, {String? code}) async {
    if (code != null && code.trim().isEmpty) return const XControlException(XErrorCode.badRequest, 'no code entered');
    try {
      final r = await ownerOp(auth, (d, pw) => d.pairingConfirm(id, pw, code: code?.trim()));
      await refreshContacts();
      await select(r.linkId);
      return null;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) _fail(e);
      return e;
    } finally {
      unawaited(refreshPairings());
    }
  }

  /// Burn an invite.
  Future<Object?> cancelInvite(String id, OwnerAuth auth) async {
    try {
      final list = await ownerOp(auth, (d, pw) => d.pairingCancel(id, pw));
      for (final i in list) {
        invites[i.id] = i;
      }
      _notify();
      return null;
    } on XClientException catch (e) {
      if (e is XDaemonUnreachable) _fail(e);
      return e;
    }
  }

  void _watchPairing(ChangeNotifier s, LinkedReply? Function() linked) {
    void l() {
      final r = linked();
      if (r != null) {
        s.removeListener(l);
        unawaited(refreshContacts().then((_) => select(r.linkId)));
      }
    }

    s.addListener(l);
  }

  // Internals.

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    _sessionGen++;
    final os = _ownerSession;
    if (os != null) unawaited(os.cancel());
    _factsTimer?.cancel();
    _reconnectTimer?.cancel();
    _approvalsTimer?.cancel();
    clearFinishing();
    unawaited(_newApprovals.close());
    disposeApprovalAlerts();
    disposeQuestions();
    unawaited(_newMessages.close());
    final s = _subscription;
    if (s != null) unawaited(s.cancel());
    if (updater != null) manifestChecks?.dispose();
    disposeCodeShots();
    closeAgentWatches();
    disposeTeams();
    disposeCodeWake();
    disposeRuns();
    disposeAiApps();
    disposeAgentMap();
    clearApprovers();
    super.dispose();
  }
}

/// Progress of a two-code rekey (CONTROL §12, PROTOCOL §17).
enum RekeyStage {
  idle,

  /// The side that rolled back proposed: our first code is shown, to be read out to the contact.
  myCodeShown,

  /// The contact accepted the proposal: enter their second code.
  enterSecondCode,

  /// The contact requests a rekey: enter their first code.
  enterFirstCode,

  /// The first code was accepted: our second code is shown, to be read back.
  secondCodeShown,

  /// Two different proposals or answers: both burned.
  conflict,
  done,
}

class RekeyFlow {
  RekeyStage stage = RekeyStage.idle;
  String? code;
  String? codeEmoji;
  Object? error;
  bool busy = false;
}

/// A new message the owner may be told about: the link and its chat (never the text).
final class ChatNotice {
  const ChatNotice(this.linkId, this.chat);
  final String linkId;
  final ThreadKey chat;
}
