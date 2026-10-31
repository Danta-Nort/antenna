// SPDX-License-Identifier: AGPL-3.0-only
// Files for the fake daemon (x-control/3): quarantine in different states, offer messages in history, previews.

import 'dart:io';
import 'dart:typed_data';

import 'package:antenna_desktop/protocol/x_control.dart';

import 'fake_daemon.dart';
import 'fixtures.dart';

const _sandbox = 'landlock=full seccomp=on rlimits=as:1GiB,cpu:30s,nofile:64';

FileInfo demoFile(
  int seed, {
  required ContactInfo from,
  required String name,
  required int size,
  required String mime,
  required String state,
  required DateTime at,
  String direction = 'in',
  String? verdict,
  List<FileFinding> findings = const [],
  String? dest,
  String? savedAs,
  String? savedPath,
  DateTime? expires,
  String? reason,
  List<String> labels = const [],
}) =>
    FileInfo(
      id: hex(0xF11E + seed, 32),
      contact: from.label,
      linkId: from.linkId,
      direction: direction,
      name: name,
      size: size,
      blake3: hex(0xB3B3 + seed),
      senderMime: mime,
      senderVerdict: 'clean',
      state: state,
      verdict: verdict,
      mime: verdict == null ? null : mime,
      findings: findings,
      sandbox: verdict == null ? null : _sandbox,
      dest: dest,
      savedAs: savedAs,
      savedPath: savedPath,
      labels: labels,
      messageId: hex(0xF11E + seed + 7),
      createdMs: ms(at),
      expiresMs: expires == null ? null : ms(expires),
      reason: reason,
    );

/// The history message a file arrived (or left) with: `kind: file`; the text is the daemon's string.
HistoryItem fileMsg(int seq, FileInfo f, DateTime at, {String? viaAgent}) => HistoryItem(
      seq: seq,
      id: f.messageId!,
      direction: f.direction,
      kind: 'file',
      text: 'file: ${f.name} (${f.size} bytes, ${f.senderMime}, blake3 ${f.blake3.substring(0, 16)})',
      ts: ms(at),
      localMs: ms(at),
      lamport: seq,
      status: f.direction == 'out' ? 'delivered' : 'received',
      viaAgent: viaAgent,
    );

FileInfo get contractPdf => demoFile(1,
    from: emily,
    name: 'contract_v7.pdf',
    size: 421888,
    mime: 'application/pdf',
    state: 'checked',
    verdict: 'clean',
    at: ago(minutes: 2),
    findings: const [FileFinding(code: 'pdf_pages', severity: 'info', detail: '6 pages rendered to PNG')]);

FileInfo get macroSheet => demoFile(2,
    from: ryan,
    name: 'bank-details.xlsm',
    size: 58113,
    mime: 'application/vnd.ms-excel.sheet.macroEnabled.12',
    state: 'checked',
    verdict: 'suspicious',
    at: ago(minutes: 9),
    findings: const [
      FileFinding(code: 'office_macros', severity: 'warn', detail: 'workbook contains VBA macros (not executed)'),
    ]);

FileInfo get disguisedExe => demoFile(3,
    from: jordan,
    name: 'build-tools.txt',
    size: 1843200,
    mime: 'text/plain',
    state: 'checked',
    verdict: 'threat',
    at: ago(minutes: 30),
    expires: ago(days: -7),
    findings: const [
      FileFinding(code: 'executable_disguised', severity: 'threat', detail: 'ELF executable under a .txt name'),
    ]);

FileInfo get downloadingLog => demoFile(4,
    from: jordan, name: 'test-log.txt', size: 7340032, mime: 'text/plain', state: 'offered', at: ago(minutes: 1));

FileInfo get sentNotes => demoFile(5,
    from: jordan,
    direction: 'out',
    name: 'release-notes.md',
    size: 12800,
    mime: 'text/markdown',
    state: 'sent',
    verdict: 'clean',
    at: ago(minutes: 6));

FileInfo get acceptedScan => demoFile(6,
    from: emily,
    name: 'schema_v2.png',
    size: 245760,
    mime: 'image/png',
    state: 'accepted',
    verdict: 'clean',
    dest: 'shared',
    savedAs: 'schema_v2.png',
    at: ago(days: 1, hours: 1));

/// A PDF page rebuilt by the daemon (for goldens, a pre-drawn image).
Uint8List previewPagePng() => File('test/goldens/assets/preview_page.png').readAsBytesSync();

/// Put the demo files into the fake: quarantine, previews, history messages.
void addDemoFiles(FakeDaemon d) {
  for (final f in [contractPdf, macroSheet, disguisedExe, downloadingLog, sentNotes, acceptedScan]) {
    d.fileMap[f.id] = f;
  }
  d.previewMap[contractPdf.id] = FilePreview(kind: 'pdf', imagesPng: [previewPagePng()], truncated: true);
  d.previewMap[macroSheet.id] = FilePreview(
    kind: 'document',
    text: 'Beneficiary: North Wind LLC\nAccount: 000123456789\nRouting: 000000000',
  );
  d.historyMap[emily.linkId] = [...?d.historyMap[emily.linkId], fileMsg(9, contractPdf, ago(minutes: 2))];
  d.historyMap[ryan.linkId] = [...?d.historyMap[ryan.linkId], fileMsg(31, macroSheet, ago(minutes: 9))];
  d.historyMap[jordan.linkId] = [
    ...?d.historyMap[jordan.linkId],
    fileMsg(25, disguisedExe, ago(minutes: 30)),
    fileMsg(26, sentNotes, ago(minutes: 6)),
    fileMsg(27, downloadingLog, ago(minutes: 1)),
  ]..sort((a, b) => a.seq.compareTo(b.seq));
}

/// A `withdraw_file` / `withdrawn` receipt (preview.5) for the offer [messageId]: [out] is this node's own (it
/// withdrew a file it sent), otherwise the contact withdrew a file it had sent here.
HistoryItem withdrawReceiptMsg(int seq, bool out, String messageId, DateTime at) => HistoryItem(
      seq: seq,
      id: hex(seq * 11 + 5),
      direction: out ? 'out' : 'in',
      kind: 'receipt',
      text: 'withdraw_file withdrawn',
      ts: ms(at),
      localMs: ms(at),
      lamport: seq,
      status: out ? 'delivered' : 'received',
      receipt: ReceiptInfo(
        seq: seq,
        ts: ms(at),
        actor: 'owner',
        action: 'withdraw_file',
        decision: 'withdrawn',
        reason: '',
        source: 'dag',
        author: out ? 'me' : 'contact',
        refs: [messageId],
      ),
    );

/// The approval request the daemon creates when it finds a secret in a file being sent.
ApprovalInfo shareApproval(String id, {required ContactInfo to}) => ApprovalInfo.fromJson({
      'id': id,
      'state': 'pending',
      'quiet': false,
      'requester': 'owner',
      'contact': to.label,
      'contact_trust': to.trust,
      'action': 'share_file',
      'target': 'keys-backup.txt',
      'reasons': ['secret:private_key'],
      'grants': {'read': null, 'write': null, 'commands': null, 'send': 'file keys-backup.txt'},
      'quote': '',
      'fingerprint': 'blake3 5e11…c0de',
      'created_ms': ms(fixedNow),
      'expires_ms': ms(fixedNow.add(const Duration(minutes: 10))),
    });
