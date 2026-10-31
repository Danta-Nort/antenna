// SPDX-License-Identifier: AGPL-3.0-only
// Composer slash commands: only those the daemon actually has (x-control/1). Plain text means `antenna send`.
// SPEC §12 commands the daemon cannot do yet (verify, share, files, rotate, revoke…) are not shown here.
// `antenna inbox` is left out on purpose: it marks messages as read, and unread messages are the queue of the CLI and
// agents.

import '../../l10n/app_localizations.dart';
import '../../state/format.dart';

enum SlashKind { invite, join, trust, agent, approvals, pairings, log, contacts, status, lock }

final class SlashCommand {
  const SlashCommand(this.kind, this.name, this.cli);

  final SlashKind kind;
  final String name;

  /// The same command in the CLI.
  final String cli;

  /// Arguments for the hint (argument names are in the app language).
  String args(AppLocalizations l) => switch (kind) {
        SlashKind.invite => '[--trust 1–5] [--ttl 10m] [--label ${l.slashArgName}]',
        SlashKind.join => l.commonLinkPlaceholder,
        SlashKind.trust => '<1–5>',
        _ => '',
      };

  /// Help text (in the app language).
  String help(AppLocalizations l) => switch (kind) {
        SlashKind.invite => l.slashHelpInvite,
        SlashKind.join => l.slashHelpJoin,
        SlashKind.trust => l.slashHelpTrust,
        SlashKind.agent => l.slashHelpAgent,
        SlashKind.approvals => l.approvalsTitle,
        SlashKind.pairings => l.slashHelpPairings,
        SlashKind.log => l.slashHelpLog,
        SlashKind.contacts => l.slashHelpContacts,
        SlashKind.status => l.slashHelpStatus,
        SlashKind.lock => l.slashHelpLock,
      };

  static const all = <SlashCommand>[
    SlashCommand(SlashKind.invite, '/invite', 'antenna invite'),
    SlashCommand(SlashKind.join, '/join', 'antenna join'),
    SlashCommand(SlashKind.trust, '/trust', 'antenna trust'),
    SlashCommand(SlashKind.agent, '/agent', 'antenna agent add'),
    SlashCommand(SlashKind.approvals, '/approvals', 'antenna approvals'),
    SlashCommand(SlashKind.pairings, '/pairings', 'antenna pairing'),
    SlashCommand(SlashKind.log, '/log', 'antenna log'),
    SlashCommand(SlashKind.contacts, '/contacts', 'antenna contacts'),
    SlashCommand(SlashKind.status, '/status', 'antenna status'),
    SlashCommand(SlashKind.lock, '/lock', 'antenna lock'),
  ];

  /// Commands matching the typed prefix (`/in` → invite).
  static List<SlashCommand> matching(String input) {
    final word = input.split(RegExp(r'\s')).first.toLowerCase();
    if (!word.startsWith('/')) return const [];
    return all.where((c) => c.name.startsWith(word)).toList();
  }
}

/// What is wrong with a command's arguments (the text is [ParsedSlash.errorText], in the app language).
enum SlashError { trustRange, ttlRange, unknownArg, levelRange, noArgs }

/// A parsed command.
final class ParsedSlash {
  const ParsedSlash(this.command, {this.trust, this.ttl, this.label, this.link, this.error, this.errorArg = ''});

  final SlashCommand command;

  /// For `/trust`, the new level; for `/invite`, the initial one.
  final int? trust;
  final Duration? ttl;
  final String? label;
  final String? link;
  final SlashError? error;

  /// The argument parsing stopped at (for [SlashError.unknownArg]).
  final String errorArg;

  /// Parse error for the owner; `null` means no error.
  String? errorText(AppLocalizations l) => switch (error) {
        null => null,
        SlashError.trustRange => l.slashErrTrust,
        SlashError.ttlRange => l.slashErrTtl,
        SlashError.unknownArg => l.slashErrUnknownArg(errorArg),
        SlashError.levelRange => l.slashErrLevel,
        SlashError.noArgs => l.slashErrNoArgs(command.name),
      };
}

/// Parses a line. `null` means it is not a command (plain text, including the `//escape`).
ParsedSlash? parseSlash(String input) {
  final s = input.trim();
  if (!s.startsWith('/') || s.startsWith('//')) return null;
  final parts = s.split(RegExp(r'\s+'));
  final name = parts.first.toLowerCase();
  final cmd = SlashCommand.all.where((c) => c.name == name).firstOrNull;
  if (cmd == null) return null;
  final rest = parts.skip(1).toList();
  switch (cmd.kind) {
    case SlashKind.invite:
      int? trust;
      Duration? ttl;
      String? label;
      for (var i = 0; i < rest.length; i++) {
        final a = rest[i];
        String? val() => i + 1 < rest.length ? rest[++i] : null;
        switch (a) {
          case '--trust':
            trust = int.tryParse(val() ?? '');
            if (trust == null || trust < 1 || trust > 5) {
              return ParsedSlash(cmd, error: SlashError.trustRange);
            }
          case '--ttl':
            ttl = parseDuration(val() ?? '');
            if (ttl == null || ttl.inSeconds < 1 || ttl > const Duration(hours: 24)) {
              return ParsedSlash(cmd, error: SlashError.ttlRange);
            }
          case '--label':
            label = val();
          default:
            return ParsedSlash(cmd, error: SlashError.unknownArg, errorArg: a);
        }
      }
      return ParsedSlash(cmd, trust: trust, ttl: ttl, label: label);
    case SlashKind.join:
      return ParsedSlash(cmd, link: rest.isEmpty ? null : rest.first);
    case SlashKind.trust:
      final level = rest.length == 1 ? int.tryParse(rest.first) : null;
      if (level == null || level < 1 || level > 5) return ParsedSlash(cmd, error: SlashError.levelRange);
      return ParsedSlash(cmd, trust: level);
    default:
      return rest.isEmpty ? ParsedSlash(cmd) : ParsedSlash(cmd, error: SlashError.noArgs);
  }
}
