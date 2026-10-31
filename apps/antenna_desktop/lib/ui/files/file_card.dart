// SPDX-License-Identifier: AGPL-3.0-only
// File card: an incoming file in quarantine (manifest → download → check → preview → owner's decision) or a sent one.
// The name and type from the sender are contact data: shown as text, without markup; our own check decides. A sent
// file the contact has not answered can be withdrawn (preview.5); a withdrawn one says so on both sides.

import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/x_control.dart';
import '../../state/files.dart';
import '../../state/format.dart';
import '../../state/updates.dart';
import '../../theme/x_theme.dart';
import '../app_scope.dart';
import '../updates/update_dialog.dart';
import 'file_actions.dart';
import 'image_thumbnail.dart';

/// A received Antenna release manifest the daemon saved: its card asks the CLI whether it is signed and offers Install
/// (D-UI-29), so it keeps the full card wherever files are shown.
bool isReleaseManifest(FileInfo f) {
  final saved = f.incoming && f.state == 'accepted' ? f.savedPath : null;
  return saved != null && releaseManifestVersion(saved.split('/').last) != null;
}

/// Human-readable size: `412 KB`, `3.4 MB`.
String fileSizeLabel(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final s = i == 0 || v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '$s ${units[i]}';
}

/// Icon by type (by our signature check; before the check, by the sender's claim).
IconData fileIcon(FileInfo f) {
  final m = f.mime ?? f.senderMime;
  if (m.startsWith('image/')) return Icons.image_outlined;
  if (m == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (m.startsWith('text/')) return Icons.description_outlined;
  if (m.contains('zip') || m.contains('tar') || m.contains('compressed')) return Icons.folder_zip_outlined;
  if (m.startsWith('audio/')) return Icons.audio_file_outlined;
  if (m.startsWith('video/')) return Icons.video_file_outlined;
  return Icons.insert_drive_file_outlined;
}

/// Check verdict: label and color.
(String, Color, IconData) verdictLook(AppLocalizations l, String? v) => switch (v) {
      'clean' => (l.filesVerdictClean, XColors.ok, Icons.verified_outlined),
      'suspicious' => (l.filesVerdictSuspicious, XColors.warn, Icons.gpp_maybe_outlined),
      'threat' => (l.filesVerdictThreat, XColors.danger, Icons.dangerous_outlined),
      'failed' => (l.filesVerdictFailed, XColors.danger, Icons.report_gmailerrorred_outlined),
      _ => (l.filesVerdictChecking, XColors.textMute, Icons.hourglass_top_rounded),
    };

/// Stage of an incoming file (0…4) for the progress strip: offer, download, check, preview, decision.
int _stage(FileInfo f) => switch (f.state) {
      'offered' => 1,
      'downloaded' => 2,
      'checked' => 4,
      'accepted' || 'rejected' => 5,
      _ => 0,
    };

class FileCard extends StatelessWidget {
  const FileCard(this.f, {super.key, this.compact = false, this.showContact = false, this.imageGallery});
  final FileInfo f;

  /// In the chat timeline: narrower, and without the stage strip once decided.
  final bool compact;

  /// In the Files section: show whose file it is.
  final bool showContact;

  /// The conversation's other images, oldest first, so the viewer's Previous/Next can move between them; just this
  /// one file when omitted (the Files section, or a lone image).
  final List<FileInfo>? imageGallery;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final c = m.contactById(f.linkId);
    final level = c?.trust ?? 0;
    final (vLabel, vColor, vIcon) = f.state == 'offered'
        ? (l.filesStateDownloading, XColors.textMute, Icons.downloading_rounded)
        : verdictLook(l, f.verdict);
    final mime = f.mime ?? (f.senderMime.isEmpty ? null : l.filesMimeFromSender(f.senderMime));
    final when = DateTime.fromMillisecondsSinceEpoch(f.createdMs);
    // A received Antenna release manifest: the CLI decides whether it is signed (the window only asks).
    final saved = f.incoming && f.state == 'accepted' ? f.savedPath : null;
    final heldByRule = f.awaitingDecision && (f.held?.holdsByRule ?? false);
    final manifest = saved != null && releaseManifestVersion(saved.split('/').last) != null ? saved : null;
    final status = FileStatusNote.of(context, f) ?? const SizedBox.shrink();
    return Container(
      key: Key('file-${f.id.substring(0, 8)}'),
      constraints: BoxConstraints(maxWidth: compact ? 520 : 760),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: xPanel(
        fill: XColors.bg1,
        radius: XRadius.l,
        border: heldByRule
            ? XColors.warn.withValues(alpha: 0.45)
            : (f.awaitingDecision && f.verdict != 'clean' ? vColor.withValues(alpha: 0.45) : XColors.line),
        glow: 0.5,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        // A picture's thumbnail, the same width as the card: the safe preview once checked (incoming) or the
        // window's preview copy of what it sent (outgoing); a quiet placeholder before the check. Everything below
        // (name, size, verdict, the decision buttons while one is still needed) stays as it reads for any other file.
        if (showsThumbnail(m, f)) ImageThumbnail(f, height: compact ? 180 : 240, gallery: imageGallery, gap: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 42,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: XColors.accentSoft, borderRadius: BorderRadius.circular(XRadius.m)),
            child: Icon(fileIcon(f), color: XColors.accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // The name is contact data: one line, no markup.
              Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: XText.title.copyWith(fontSize: 14)),
              const SizedBox(height: 4),
              Text(
                [
                  fileSizeLabel(f.size),
                  ?mime,
                  if (showContact) f.incoming ? l.filesFrom(f.contact) : l.filesTo(f.contact),
                  hhmm(when),
                ].join(' · '),
                style: XText.meta,
              ),
            ]),
          ),
          const SizedBox(width: 8),
          if (f.incoming && f.state != 'refused' && !f.withdrawn) _VerdictChip(vLabel, vColor, vIcon),
        ]),
        // D-129: code and markup are saved as files; Antenna never runs them.
        if (f.incoming && f.fileClass == 'code') ...[
          const SizedBox(height: 8),
          _Note(Icons.code_rounded, XColors.textMute, l.filesClassCode, key: Key('file-code-${f.id.substring(0, 8)}')),
        ],
        // D-130: what the check noted without holding the file: quiet labels, never a verdict.
        if (f.incoming && f.labels.isNotEmpty) ...[
          const SizedBox(height: 8),
          _Labels(f),
        ],
        if (f.incoming && !f.decided && f.state != 'refused') ...[
          const SizedBox(height: 16),
          _Stages(_stage(f), verdictColor: f.state == 'checked' ? vColor : null),
        ],
        if (f.incoming && f.state == 'offered') ...[
          const SizedBox(height: 8),
          Text(l.filesDownloadingNote, style: XText.meta),
        ],
        if (f.incoming && f.state == 'downloaded') ...[
          const SizedBox(height: 8),
          Text(l.filesCheckingNote, style: XText.meta),
        ],
        if (f.findings.isNotEmpty && (!compact || f.awaitingDecision)) ...[
          const SizedBox(height: 12),
          for (final x in f.findings) _FindingRow(x),
        ],
        if (f.awaitingDecision && !compact && f.sandbox != null) ...[
          const SizedBox(height: 8),
          Text(l.filesSandbox(f.sandbox!), style: XText.monoSmall),
        ],
        if (status is! SizedBox) ...[const SizedBox(height: 8), status],
        // The file itself on this computer, whether or not a picture of it could be shown.
        if (m.localFileOf(f) case final path?) ...[const SizedBox(height: 4), _LocalFileRow(f, path)],
        if (manifest != null) UpdateManifestNotice(path: manifest),
        if (f.incoming && (f.state == 'downloaded' || f.state == 'checked')) UpdateAssetNotice(blake3: f.blake3),
        if (f.awaitingDecision) ...[
          // The daemon says the same file is already in the folder under this name: Accept saves nothing new.
          if (m.sameNameCheck(f)?.sameFile ?? false) ...[
            const SizedBox(height: 8),
            _Note(Icons.inventory_2_outlined, XColors.ok, l.filesSameAlready,
                key: Key('file-same-${f.id.substring(0, 8)}')),
          ],
          const SizedBox(height: 8),
          Text(
            heldByRule ? l.filesHeldKeepNote : (f.needsForce ? l.filesForceOnly : levelRuleLabel(l, level)),
            style: XText.meta,
          ),
          if ((f.needsForce || heldByRule) && f.expiresMs != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l.filesExpires(formatDate(l, DateTime.fromMillisecondsSinceEpoch(f.expiresMs!))),
                style: XText.meta.copyWith(color: XColors.danger),
              ),
            ),
          const SizedBox(height: 12),
          FileDecisionButtons(f, level: level),
        ],
      ]),
    );
  }
}

/// Open and Show in Finder for a received file the daemon saved on this computer.
class _LocalFileRow extends StatelessWidget {
  const _LocalFileRow(this.f, this.path);
  final FileInfo f;
  final String path;

  Future<void> _run(BuildContext context, Future<bool> Function(String) action) async {
    final failed = context.l.filesOpenFailed;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!await action(path)) messenger?.showSnackBar(SnackBar(content: Text(failed)));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = AppScope.read(context);
    final id = f.id.substring(0, 8);
    return Wrap(spacing: 4, children: [
      TextButton.icon(
        key: Key('file-open-$id'),
        onPressed: () => _run(context, m.openLocalFile),
        icon: const Icon(Icons.open_in_new_rounded, size: 16),
        label: Text(l.filesOpenFile),
      ),
      TextButton.icon(
        key: Key('file-reveal-$id'),
        onPressed: () => _run(context, m.revealLocalFile),
        icon: const Icon(Icons.folder_open_outlined, size: 16),
        label: Text(Platform.isMacOS ? l.filesShowInFinder : l.filesShowInFolder),
      ),
    ]);
  }
}

/// What a file's card says about its state (the fate of a sent file, where a received one was saved, why one waits),
/// the same words on a compact row's second line; `null` when there is nothing more to say than the state itself.
abstract final class FileStatusNote {
  static Widget? of(BuildContext context, FileInfo f) {
    final l = context.l;
    if (!f.incoming) {
      return _OutStatus(f);
    } else if (f.state == 'refused') {
      return _Note(Icons.block, XColors.danger, refusedLabel(l, f.reason));
    } else if (f.state == 'accepted' && f.duplicate) {
      // preview.8: the same file was already there under this name; nothing new was saved.
      return _Note(Icons.check_circle_outline, XColors.ok, l.filesAcceptedSame(f.dest ?? '?'),
          key: Key('file-duplicate-${f.id.substring(0, 8)}'));
    } else if (f.state == 'accepted' && f.renamed) {
      // D-128: another file had the name, so the daemon saved this one under the next free number.
      return _Note(Icons.check_circle_outline, XColors.ok, l.filesSavedAsNumbered(f.savedAs!, f.dest ?? '?'),
          key: Key('file-saved-as-${f.id.substring(0, 8)}'));
    } else if (f.state == 'accepted') {
      return _Note(Icons.check_circle_outline, XColors.ok,
          f.savedAs == null ? l.filesAcceptedInto(f.dest ?? '?') : l.filesAcceptedAs(f.dest ?? '?', f.savedAs!));
    } else if (f.held case final h? when f.awaitingDecision && h.holdsByRule) {
      // D-130: the own-computer rules hold it (a program, an installer, an archive not opened whole, a threat, a failed
      // check): what the danger is, as a browser's download warning says it.
      final grave = h.code == 'threat' || h.code == 'check_failed';
      return Column(
        key: Key('file-warning-${f.id.substring(0, 8)}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Note(grave ? Icons.dangerous_outlined : Icons.warning_amber_rounded, grave ? XColors.danger : XColors.warn,
              heldWarningText(l, f)),
          if (h.rules.isNotEmpty) _RulesLine(h.rules),
        ],
      );
    } else if (f.held case final h? when f.awaitingDecision) {
      // D-128: a file from an own computer the daemon could not save by itself waits here, with the reason.
      return _Note(Icons.info_outline, XColors.warn,
          l.filesHeld(describeFileError(l, XControlException(h.code, h.message))),
          key: Key('file-held-${f.id.substring(0, 8)}'));
    } else if (f.state == 'rejected') {
      return _Note(Icons.do_not_disturb_on_outlined, XColors.textMute, l.filesRejectedNote);
    } else if (f.withdrawn) {
      return _Note(Icons.undo_rounded, XColors.textMute, l.filesInWithdrawn);
    }
    return null;
  }
}

/// Why the daemon refused the manifest (nothing was downloaded or stored).
String refusedLabel(AppLocalizations l, String? reason) => switch (reason) {
      'level_forbids_files' => l.filesRefusedLevel,
      'file_quota_exceeded' => l.filesRefusedQuota,
      'bad_manifest' => l.filesRefusedManifest,
      null => l.filesRefusedOther,
      final r => l.filesRefusedReason(r),
    };

/// Acceptance rules by level (CONTROL §14).
String levelRuleLabel(AppLocalizations l, int level) => switch (level) {
      2 => l.filesRuleLevel2,
      3 || 4 => l.filesRuleLevel34(level),
      5 => l.filesRuleLevel5,
      _ => '',
    };

class _VerdictChip extends StatelessWidget {
  const _VerdictChip(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        decoration: BoxDecoration(
          color: Color.alphaBlend(color.withValues(alpha: 0.10), XColors.bg1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: XText.meta.copyWith(color: color, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _Stages extends StatelessWidget {
  const _Stages(this.stage, {this.verdictColor});
  final int stage;
  final Color? verdictColor;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final labels = [l.filesStageOffer, l.filesStageDownload, l.filesStageCheck, l.filesStagePreview, l.filesStageDecision];
    return Row(children: [
        for (var i = 0; i < labels.length; i++) ...[
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 4,
                  width: double.infinity,
                  child: i == stage && stage < 3
                      // In progress: the daemon does not report bytes, so the indicator is indeterminate.
                      ? LinearProgressIndicator(color: XColors.accentFill, backgroundColor: XColors.accentSoft)
                      : ColoredBox(
                          color: i < stage
                              ? XColors.ok
                              : (i == stage ? (verdictColor ?? XColors.accentFill) : XColors.line),
                        ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                labels[i],
                style: XText.meta.copyWith(
                  fontSize: 11,
                  color: i == stage ? XColors.text : (i < stage ? XColors.textDim : XColors.textMute),
                  fontWeight: i == stage ? FontWeight.w600 : null,
                ),
              ),
            ]),
          ),
          if (i < labels.length - 1) const SizedBox(width: 8),
        ],
      ]);
  }
}

class _FindingRow extends StatelessWidget {
  const _FindingRow(this.x);
  final FileFinding x;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (x.severity) {
      'threat' => (Icons.dangerous_outlined, XColors.danger),
      'warn' => (Icons.warning_amber_rounded, XColors.warn),
      _ => (Icons.info_outline, XColors.textMute),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 14, color: color)),
        const SizedBox(width: 8),
        SizedBox(width: 170, child: Text(x.code, style: XText.monoSmall.copyWith(color: color))),
        Expanded(child: Text(x.detail, style: XText.meta.copyWith(color: XColors.textDim))),
      ]),
    );
  }
}

/// The rules of a check that held a file (finding codes, never file content), small and under the note.
class _RulesLine extends StatelessWidget {
  const _RulesLine(this.rules);
  final List<String> rules;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 24, top: 4),
        child: Text(context.l.filesRules(rules.join(', ')), style: XText.monoSmall),
      );
}

/// The check's labels (D-130): finding codes that did not hold the file.
class _Labels extends StatelessWidget {
  const _Labels(this.f);
  final FileInfo f;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: context.l.filesLabelsTooltip,
        child: Wrap(key: Key('file-labels-${f.id.substring(0, 8)}'), spacing: 4, runSpacing: 4, children: [
          for (final code in f.labels)
            Container(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
              decoration: BoxDecoration(color: XColors.bg2, borderRadius: BorderRadius.circular(XRadius.s)),
              child: Text(code, style: XText.monoSmall),
            ),
        ]),
      );
}

class _Note extends StatelessWidget {
  const _Note(this.icon, this.color, this.text, {super.key});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: XText.meta.copyWith(color: color == XColors.textMute ? XColors.textDim : color))),
      ]);
}

/// A sent file's fate reason (D-129, a receipt's `why`) in words; an unknown word (a newer node's) reads as a problem
/// the check found.
String fileFateReason(AppLocalizations l, String why) => switch (why) {
      'threat' => l.filesFateThreat,
      'executable' => l.filesFateExecutable,
      'installer' => l.filesFateInstaller,
      'uninspected' => l.filesFateUninspected,
      'check_failed' => l.filesFateCheckFailed,
      'review' => l.filesFateReview,
      'not_saved' => l.filesFateNotSaved,
      'damaged' => l.filesFateDamaged,
      'limit' => l.filesFateLimit,
      _ => l.filesFateOther,
    };

/// What the contact's node did with a sent file it holds or blocked (D-129): never "declined", which only the
/// contact's owner or agent says (`rejected`). A block is the contact's check (a threat waits there for its owner) or
/// its limits; an older node says neither, so the card says both.
String sentFateText(AppLocalizations l, FileInfo f, String contact) {
  final why = f.held?.code;
  if (f.state == 'held') {
    return why == null ? l.filesOutHeld(contact) : l.filesOutHeldWhy(contact, fileFateReason(l, why));
  }
  return switch (why) {
    null => l.filesOutBlockedUnknown(contact),
    'damaged' || 'limit' => l.filesOutRefused(contact, fileFateReason(l, why)),
    _ => l.filesOutBlocked(contact, fileFateReason(l, why)),
  };
}

/// Outgoing: the daemon prepared the ciphertext and sent the offer; the contact downloads it when online. Until the
/// contact answers, the owner can withdraw it (preview.5; hidden once the daemon said it cannot). Then the card says
/// the file's fate as the contact's node told it (D-129): saved, held for its owner, blocked, or declined.
class _OutStatus extends StatelessWidget {
  const _OutStatus(this.f);
  final FileInfo f;

  @override
  Widget build(BuildContext context) => switch (f.state) {
        'accepted' => _Note(Icons.check_circle_outline, XColors.ok,
            f.renamed ? context.l.filesOutAcceptedAs(f.savedAs!) : context.l.filesOutAccepted,
            key: Key('file-out-accepted-${f.id.substring(0, 8)}')),
        'held' || 'blocked' => _fate(context),
        'rejected' => _Note(Icons.do_not_disturb_on_outlined, XColors.textMute, context.l.filesOutRejected,
            key: Key('file-out-rejected-${f.id.substring(0, 8)}')),
        'withdrawn' => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Note(Icons.undo_rounded, XColors.textMute, context.l.filesOutWithdrawn),
            if (f.withdrawal == 'contact_cannot_withdraw') ...[
              const SizedBox(height: 4),
              _Note(Icons.info_outline, XColors.warn, context.l.filesOutWithdrawnOld),
            ],
          ]),
        _ when f.state == 'sent' && AppScope.of(context).fileWithdrawSupported => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [_progress(context), const SizedBox(height: 8), _WithdrawRow(f)],
          ),
        _ => _progress(context),
      };

  Widget _fate(BuildContext context) {
    final l = context.l;
    final contact = AppScope.of(context).contactById(f.linkId)?.label ?? f.contact;
    final rules = f.held?.rules ?? const <String>[];
    return Column(
      key: Key('file-out-${f.state}-${f.id.substring(0, 8)}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Note(f.state == 'held' ? Icons.hourglass_top_rounded : Icons.gpp_maybe_outlined, XColors.warn,
            sentFateText(l, f, contact)),
        // Finding codes of the contact's check (never file content): plain text, they are the contact's data.
        if (rules.isNotEmpty) _RulesLine(rules),
        // An older node's block says no reason: most often a threat its check holds; its limits refuse the same way.
        if (f.state == 'blocked' && f.held == null)
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 4),
            child: Text(l.filesOutBlockedOldNote, style: XText.meta),
          ),
      ],
    );
  }

  Widget _progress(BuildContext context) => Row(children: [
            SizedBox(
              width: 90,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                    minHeight: 4, color: XColors.accentFill, backgroundColor: XColors.accentSoft),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(context.l.filesOutSent, style: XText.meta),
            ),
          ]);
}

/// "Cancel sending", and for a contact whose node cannot delete its copy, what that means.
class _WithdrawRow extends StatelessWidget {
  const _WithdrawRow(this.f);
  final FileInfo f;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = AppScope.of(context).contactById(f.linkId);
    return Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      OutlinedButton.icon(
        key: Key('file-withdraw-${f.id.substring(0, 8)}'),
        onPressed: () => withdrawFileFlow(context, f),
        icon: const Icon(Icons.undo_rounded, size: 16),
        label: Text(l.filesWithdraw),
      ),
      if (c != null && !c.peerFileWithdraw) Text(l.filesWithdrawOldContact, style: XText.meta),
    ]);
  }
}

/// A send the daemon has not accepted yet (hashing and encrypting) or has held (secret → approval needed).
class OutgoingFileCard extends StatelessWidget {
  const OutgoingFileCard(this.o, {super.key});
  final OutgoingFile o;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final Widget body;
    if (o.busy) {
      body = Row(children: [
        SizedBox(
          width: 90,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(minHeight: 4, color: XColors.accentFill, backgroundColor: XColors.accentSoft),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(l.filesPreparing, style: XText.meta)),
      ]);
    } else if (o.approvalId != null) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Note(Icons.gpp_maybe_outlined, XColors.warn, l.filesSecretHeld),
        const SizedBox(height: 8),
        Row(children: [
          TextButton(onPressed: () => AppScope.read(context).dismissOutgoing(o.localId), child: Text(l.filesDontSend)),
          const SizedBox(width: 8),
          FilledButton(
            key: const Key('file-approve-send'),
            onPressed: () => approveAndShare(context, o),
            child: Text(l.filesApproveAndSend),
          ),
        ]),
      ]);
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Note(Icons.error_outline, XColors.danger, l.filesNotSent(describeFileError(l, o.error))),
        const SizedBox(height: 8),
        Row(children: [
          TextButton(onPressed: () => AppScope.read(context).dismissOutgoing(o.localId), child: Text(l.filesDismiss)),
          TextButton(
            onPressed: () => AppScope.read(context).shareFile(o.linkId, o.path, retry: o),
            child: Text(l.filesRetry),
          ),
        ]),
      ]);
    }
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: xPanel(fill: XColors.bg1, radius: XRadius.l, glow: 0.5),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Container(
            width: 42,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: XColors.accentSoft, borderRadius: BorderRadius.circular(XRadius.m)),
            child: Icon(Icons.upload_file_outlined, color: XColors.accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(o.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: XText.title.copyWith(fontSize: 14)),
              // Where the person's file is; the window's own copy (a pasted or dropped image) has no place to show.
              if (o.origin ?? (o.staged ? null : o.path) case final shown?) ...[
                const SizedBox(height: 4),
                Text(shown, maxLines: 1, overflow: TextOverflow.ellipsis, style: XText.monoSmall),
              ],
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        body,
      ]),
    );
  }
}
