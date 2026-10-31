// SPDX-License-Identifier: AGPL-3.0-only
// The typed calls of [XDaemon] over its two primitives, `call` and `open`: shared by the socket client
// ([XControlClient]) and the daemon that signs one request with an owner proof ([ProvingDaemon], D-131).

import 'daemon.dart';
import 'errors.dart';
import 'models.dart';
import 'requests.dart';

/// [r] as the reply type the request expects; anything else is a protocol violation.
T expectReply<T extends Reply>(Reply r) {
  if (r is T) return r;
  throw XProtocolException('expected ${T.toString()}, got ${r.runtimeType}');
}

/// Every typed request of [XDaemon] in terms of [XDaemon.call] and [XDaemon.open].
mixin XDaemonCalls implements XDaemon {

  @override
  Future<StatusReply> status() async => expectReply<StatusReply>(await call(const StatusRequest()));

  @override
  Future<DaemonState> init(String password) async => expectReply<DoneReply>(await call(InitRequest(password))).state;

  @override
  Future<DaemonState> unlock(String password) async =>
      expectReply<DoneReply>(await call(UnlockRequest(password))).state;

  @override
  Future<DaemonState> lock() async => expectReply<DoneReply>(await call(const LockRequest())).state;

  @override
  Future<List<ContactInfo>> contacts() async =>
      expectReply<ContactsReply>(await call(const ContactsRequest())).contacts;

  @override
  Future<SentReply> send(String contact, String text,
          {Duration wait = const Duration(seconds: 2),
          MessageAddress? address,
          String? approvalId,
          bool urgent = false}) async =>
      expectReply<SentReply>(await call(SendRequest(
        contact: contact,
        text: text,
        waitMs: wait.inMilliseconds,
        address: address,
        approvalId: approvalId,
        urgent: urgent,
      )));

  @override
  Future<List<InboxMessage>> inbox({bool wait = false, Duration? timeout}) async => expectReply<InboxReply>(
        await call(InboxRequest(wait: wait, timeoutMs: timeout?.inMilliseconds)),
      ).messages;

  @override
  Future<HistoryReply> history(String contact, {int? before, int? limit, ChatRef? chat}) async =>
      expectReply<HistoryReply>(await call(HistoryRequest(contact: contact, before: before, limit: limit, chat: chat)));

  @override
  XDialog subscribe() => open(const SubscribeRequest());

  @override
  Future<ContactInfo> trust(String contact, int level, String password) async =>
      _one(await call(TrustRequest(contact: contact, level: level, password: password)));

  @override
  Future<List<InviteInfo>> pairings({String? password}) async =>
      expectReply<PairingsReply>(await call(PairingsRequest(password: password))).invites;

  @override
  Future<LinkedReply> pairingConfirm(String id, String password, {String? code}) async =>
      expectReply<LinkedReply>(await call(PairingConfirmRequest(id: id, password: password, code: code)));

  @override
  Future<List<InviteInfo>> pairingCancel(String id, String password) async =>
      expectReply<PairingsReply>(await call(PairingCancelRequest(id: id, password: password))).invites;

  @override
  Future<ApprovalsReply> approvals({bool all = false}) async =>
      expectReply<ApprovalsReply>(await call(ApprovalsRequest(all: all)));

  @override
  Future<ApprovalInfo> approve(String id, String password) async =>
      expectReply<ApprovalReply>(await call(ApproveRequest(id: id, password: password))).approval;

  @override
  Future<ApprovalInfo> deny(String id, {bool hour = false, String? password}) async =>
      expectReply<ApprovalReply>(await call(DenyRequest(id: id, password: password, hour: hour))).approval;

  @override
  XDialog login(String password) => open(LoginRequest(password));

  @override
  Future<void> logout() async => expectReply<DoneReply>(await call(const LogoutRequest()));

  @override
  Future<ContactInfo> markRead(String contact, int upToSeq, {List<String>? ids, ChatRef? chat}) async =>
      _one(await call(MarkReadRequest(contact: contact, upToSeq: upToSeq, ids: ids, chat: chat)));

  @override
  Future<List<ApprovalResult>> approveMany(List<ApproveItem> items, String password) async =>
      expectReply<ApprovalsDecidedReply>(await call(ApproveManyRequest(items: items, password: password))).results;

  @override
  Future<List<ApprovalResult>> denyMany(List<String> ids, {bool hour = false}) async =>
      expectReply<ApprovalsDecidedReply>(await call(DenyManyRequest(ids: ids, hour: hour))).results;

  @override
  Future<List<AgentInfo>> agentSet(String name, {required bool everyone, String? password}) async =>
      expectReply<AgentsReply>(await call(AgentSetRequest(name: name, everyone: everyone, password: password))).agents;

  @override
  Future<TopicsReply> topics(String contact) async => expectReply<TopicsReply>(await call(TopicsRequest(contact)));

  @override
  Future<List<ChatInfo>> chats({String? contact}) async =>
      expectReply<ChatsReply>(await call(ChatsRequest(contact: contact))).chats;

  @override
  Future<ChatInfo> chatSet(String contact, {String? agent, String? name, String? notify, bool? archived}) async =>
      expectReply<ChatReply>(await call(
              ChatSetRequest(contact: contact, agent: agent, name: name, notify: notify, archived: archived)))
          .chat;

  @override
  Future<List<EscalationInfo>> escalations({bool all = false}) async =>
      expectReply<EscalationsReply>(await call(EscalationsRequest(all: all))).escalations;

  @override
  Future<EscalationInfo> escalationAnswer(String id, {String? answer, bool dismiss = false}) async =>
      expectReply<EscalationReply>(await call(EscalationAnswerRequest(id: id, answer: answer, dismiss: dismiss)))
          .escalation;

  @override
  Future<List<AgentInfo>> agentEscalate(String name, String password, {String? to}) async =>
      expectReply<AgentsReply>(await call(AgentEscalateRequest(name: name, password: password, to: to))).agents;

  @override
  Future<List<PictureEntry>> pictures() async =>
      expectReply<PicturesReply>(await call(const PicturesRequest())).pictures;

  @override
  Future<List<PictureEntry>> pictureSet({String? agent, String? drawn, String? photo, bool remove = false}) async =>
      expectReply<PicturesReply>(await call(PictureSetRequest(agent: agent, drawn: drawn, photo: photo, remove: remove)))
          .pictures;

  @override
  Future<PicturePhotoReply> picturePhoto(String id) async =>
      expectReply<PicturePhotoReply>(await call(PicturePhotoRequest(id)));

  @override
  Future<HistoryStatusReply> historyStatus(String contact) async =>
      expectReply<HistoryStatusReply>(await call(HistoryStatusRequest(contact)));

  @override
  Future<HistoryStatusReply> verify(String contact, {bool accept = false, bool repair = false, String? password}) async =>
      expectReply<HistoryStatusReply>(
        await call(VerifyRequest(contact: contact, accept: accept, repair: repair, password: password)),
      );

  @override
  Future<RevokedReply> revoke(String contact, String password, {bool deleteHistory = false}) async =>
      expectReply<RevokedReply>(await call(RevokeRequest(contact: contact, password: password, deleteHistory: deleteHistory)));

  @override
  Future<ContactInfo> rename(String contact, String label) async =>
      _one(await call(RenameRequest(contact: contact, label: label)));

  @override
  Future<RekeyReply> rekey(String contact, String password, {String? code}) async =>
      expectReply<RekeyReply>(await call(RekeyRequest(contact: contact, password: password, code: code)));

  @override
  Future<FileInfo> shareFile(String contact, String path,
          {String? name, String? approvalId, String? to, String? toAgent}) async =>
      expectReply<FileReply>(
        await call(ShareFileRequest(
            contact: contact, path: path, name: name, approvalId: approvalId, to: to, toAgent: toAgent)),
      ).file;

  @override
  Future<List<FileInfo>> filesPending({String? contact, bool all = false}) async =>
      expectReply<FilesReply>(await call(FilesPendingRequest(contact: contact, all: all))).files;

  @override
  Future<FilePreviewReply> filePreview(String id) async => expectReply<FilePreviewReply>(await call(FilePreviewRequest(id)));

  @override
  Future<FileInfo> fileAccept(String id,
          {String? name, bool force = false, bool allowSpecial = false, String? approvalId, String? password}) async =>
      expectReply<FileReply>(
        await call(FileAcceptRequest(id,
            name: name, force: force, allowSpecial: allowSpecial, approvalId: approvalId, password: password)),
      ).file;

  @override
  Future<FileInfo> fileReject(String id) async => expectReply<FileReply>(await call(FileRejectRequest(id))).file;

  @override
  Future<FileInfo> fileWithdraw(String id) async => expectReply<FileReply>(await call(FileWithdrawRequest(id))).file;

  @override
  Future<List<StreamView>> streams() async => expectReply<StreamsReply>(await call(const StreamsRequest())).streams;

  @override
  Future<WakeReply> wakeSet(WakeSetRequest request) async => expectReply<WakeReply>(await call(request));

  @override
  Future<WakeReply> wakeList() async => expectReply<WakeReply>(await call(const WakeListRequest()));

  @override
  Future<WakeReply> wakeOff(String contact) async => expectReply<WakeReply>(await call(WakeOffRequest(contact)));

  @override
  XDialog wakeSay(String contact, String text, {bool toContact = false, bool interrupt = false}) =>
      open(WakeSayRequest(contact: contact, text: text, toContact: toContact, interrupt: interrupt));

  @override
  Future<ResidentSessionReply> wakeSession(String contact, ResidentAction action, {String? password}) async =>
      expectReply<ResidentSessionReply>(
          await call(WakeSessionRequest(contact: contact, action: action, password: password)));

  @override
  Future<LanReply> lanSet({required bool enabled, String? password}) async =>
      expectReply<LanReply>(await call(LanSetRequest(enabled: enabled, password: password)));

  @override
  Future<LanReply> lanStatus() async => expectReply<LanReply>(await call(const LanStatusRequest()));

  @override
  Future<LocalModelsReply> localModels() async => expectReply<LocalModelsReply>(await call(const LocalModelsRequest()));

  @override
  Future<LocalModelInfo> modelInstall(String model, {String? fromFile}) async =>
      expectReply<LocalModelReply>(await call(ModelInstallRequest(model, fromFile: fromFile))).model;

  @override
  Future<LocalModelInfo> modelRemove(String model) async =>
      expectReply<LocalModelReply>(await call(ModelRemoveRequest(model))).model;

  @override
  Future<LocalAgentInfo> localAgentAdd(String name, {required String model, required String password}) async =>
      expectReply<LocalAgentReply>(await call(LocalAgentAddRequest(name: name, model: model, password: password))).agent;

  @override
  XDialog localSay(String agent, String text, {bool interrupt = false}) =>
      open(LocalSayRequest(agent: agent, text: text, interrupt: interrupt));

  @override
  Future<LocalHistoryReply> localHistory(String agent, {int? limit, int? before}) async =>
      expectReply<LocalHistoryReply>(await call(LocalHistoryRequest(agent, limit: limit, before: before)));

  @override
  Future<LocalAgentInfo> localSession(String agent, String action) async =>
      expectReply<LocalAgentReply>(await call(LocalSessionRequest(agent, action))).agent;

  @override
  Future<UpdateAutoInfo> updateAutoStatus() async =>
      expectReply<UpdateAutoReply>(await call(const UpdateAutoStatusRequest())).info;

  @override
  Future<UpdateAutoInfo> updateAutoSet({required bool enabled, required String password}) async =>
      expectReply<UpdateAutoReply>(await call(UpdateAutoSetRequest(enabled: enabled, password: password))).info;

  @override
  Future<UpdateAutoInfo> updateAutoNow({String? password}) async =>
      expectReply<UpdateAutoReply>(await call(UpdateAutoNowRequest(password: password))).info;

  @override
  Future<UpdateAutoInfo> updateAutoLater() async =>
      expectReply<UpdateAutoReply>(await call(const UpdateAutoLaterRequest())).info;

  @override
  XDialog agentWatch(String agent) => open(AgentWatchRequest(agent));

  @override
  Future<FileNameCheck> fileNameCheck(String id, {String? name}) async =>
      expectReply<FileNameCheck>(await call(FileNameCheckRequest(id, name: name)));

  @override
  Future<FileSaveDirsReply> fileSaveDir(String contact, {String? agent, String? path, String? password}) async =>
      expectReply<FileSaveDirsReply>(
          await call(FileSaveDirRequest(contact, agent: agent, path: path, password: password)));

  @override
  Future<FileAllowReply> fileAllow(String contact, List<String> entries, {String? password}) async =>
      expectReply<FileAllowReply>(await call(FileAllowRequest(contact, entries, password: password)));

  @override
  Future<FileAllowReply> fileDisallow(String contact, {List<String>? entries}) async =>
      expectReply<FileAllowReply>(await call(FileDisallowRequest(contact, entries: entries)));

  @override
  Future<OwnerChallengeReply> ownerChallenge({bool enroll = false}) async =>
      expectReply<OwnerChallengeReply>(await call(OwnerChallengeRequest(enroll: enroll)));

  @override
  Future<OwnerKeysReply> ownerKeyList() async => expectReply<OwnerKeysReply>(await call(const OwnerKeyListRequest()));

  @override
  Future<void> ownerKeyRemove(String keyId) async => expectReply<DoneReply>(await call(OwnerKeyRemoveRequest(keyId)));

  @override
  Future<DaemonState> unlockWithSlot(String keyId, String slotKey) async =>
      expectReply<DoneReply>(await call(UnlockRequest('', keyId: keyId, slotKey: slotKey))).state;

  static ContactInfo _one(Reply r) {
    final c = expectReply<ContactsReply>(r).contacts;
    if (c.isEmpty) throw const XProtocolException('expected one contact');
    return c.first;
  }

  @override
  Future<AgentAddedReply> agentAdd(String name,
          {required int localLevel,
          required String password,
          List<String>? links,
          bool tokenFile = false,
          bool? everyone}) async =>
      expectReply<AgentAddedReply>(
        await call(AgentAddRequest(
            name: name,
            localLevel: localLevel,
            password: password,
            links: links,
            tokenFile: tokenFile,
            everyone: everyone)),
      );

  @override
  Future<AgentAddedReply> agentToken(String name, String password, {bool tokenFile = false}) async =>
      expectReply<AgentAddedReply>(await call(AgentTokenRequest(name: name, password: password, tokenFile: tokenFile)));

  @override
  Future<void> agentTasks(String name, String password, {List<String>? contacts}) async {
    await call(AgentTasksRequest(name: name, password: password, contacts: contacts));
  }

  @override
  Future<List<AgentInfo>> agents() async => expectReply<AgentsReply>(await call(const AgentListRequest())).agents;

  @override
  Future<void> agentRemove(String name, String password) async =>
      expectReply<DoneReply>(await call(AgentRemoveRequest(name: name, password: password)));

  @override
  Future<List<ReceiptInfo>> log(String contact, {int? limit}) async =>
      expectReply<LogReply>(await call(LogRequest(contact: contact, limit: limit))).entries;
}
