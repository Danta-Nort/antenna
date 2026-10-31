// SPDX-License-Identifier: AGPL-3.0-only
// The step-by-step guide for each AI app: step 1, step 2… in plain words, with copy buttons for the command, the
// arguments and the app's configuration entry. Menu names are the vendors' own, as their documentation gives them
// (docs/CONNECT-APPS.md, checked 2026-10-03). The token file's path is filled in; the token itself appears only for
// an older daemon without token files, with a warning above the guide.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/ai_apps.dart';
import '../../state/mcp_config.dart';
import '../../theme/x_theme.dart';
import 'connect_widgets.dart' show CodeBlock, CopyButton;

/// One step: what to do, then values to copy (label → value) and a block to paste.
final class GuideStep {
  const GuideStep(this.text, {this.values = const [], this.block, this.blockLabel});
  final String text;
  final List<(String, String)> values;
  final String? block;
  final String? blockLabel;
}

String _sh(String s) => RegExp(r'^[A-Za-z0-9_./:=@%+-]+$').hasMatch(s) ? s : "'${s.replaceAll("'", "'\\''")}'";

/// The steps for [app]. [server] is Antenna's MCP server with the token file (or, for an older daemon, with the
/// token in its environment).
List<GuideStep> appGuideSteps(AppLocalizations l, AiAppDef app, McpServer server,
    {required bool macos, WindowsPlace? windows}) {
  final cmd = server.command;
  final args = server.args;
  final argsLine = args.map(_sh).join(' ');
  final full = [cmd, ...args].map(_sh).join(' ');
  final envFlags = [for (final e in server.env.entries) '--env ${e.key}=${_sh(e.value)}'].join(' ');
  final entry = entryText(app, server);
  final path = app.config?.pathFor('~', macos: macos, windows: windows);
  final fields = [
    (l.guideFieldName, mcpServerName),
    (l.guideFieldCommand, cmd),
    (l.guideFieldArgs, argsLine),
    for (final e in server.env.entries) (l.guideFieldEnv, '${e.key}=${e.value}'),
  ];
  final last = GuideStep(l.guideFinal(app.name));
  return switch (app.id) {
    AiApp.chatgpt => [
        GuideStep(l.guideChatgpt1),
        GuideStep(l.guideChatgpt2, values: fields),
        GuideStep(l.guideChatgpt3),
        GuideStep(l.guideChatgpt4),
        GuideStep(l.guideSharedFile(path ?? '', 'Codex'), block: entry, blockLabel: path),
      ],
    AiApp.codex => [
        GuideStep(l.guideCodex1,
            block: 'codex mcp add $mcpServerName${envFlags.isEmpty ? '' : ' $envFlags'} -- $full',
            blockLabel: l.guideTerminal),
        GuideStep(l.guideOrFile(path ?? ''), block: entry, blockLabel: path),
        GuideStep(l.guideCodex3),
        last,
      ],
    AiApp.claudeDesktop => [
        GuideStep(l.guideClaudeDesktop1),
        GuideStep(l.guideClaudeDesktop2, block: entry, blockLabel: path),
        GuideStep(l.guideClaudeDesktop3),
        GuideStep(l.guideClaudeDesktop4),
      ],
    AiApp.claudeCode => [
        GuideStep(l.guideClaudeCode1,
            block: 'claude mcp add --scope user --transport stdio${envFlags.isEmpty ? '' : ' $envFlags'} '
                '$mcpServerName -- $full',
            blockLabel: l.guideTerminal),
        GuideStep(l.guideClaudeCode2),
        GuideStep(l.guideClaudeCode3),
      ],
    AiApp.geminiCli => [
        GuideStep(l.guideGemini1,
            block: 'gemini mcp add -s user${server.env.entries.map((e) => ' -e ${e.key}=${_sh(e.value)}').join()} '
                '$mcpServerName ${_sh(cmd)} ${_sh(args.first)} -- ${args.skip(1).map(_sh).join(' ')}',
            blockLabel: l.guideTerminal),
        GuideStep(l.guideOrFile(path ?? ''), block: entry, blockLabel: path),
        GuideStep(l.guideGemini3),
        last,
      ],
    AiApp.cursor => [
        GuideStep(l.guideCursor1),
        GuideStep(l.guideOrFile(path ?? ''), block: entry, blockLabel: path),
        GuideStep(l.guideCursor3),
        last,
      ],
    AiApp.vscode => [
        GuideStep(l.guideVscode1),
        GuideStep(l.guideVscode2, block: entry, blockLabel: 'mcp.json'),
        GuideStep(l.guideVscode3,
            block: "code --add-mcp '${jsonEncodeForShell({'name': mcpServerName, ..._typed(server)})}'",
            blockLabel: l.guideTerminal),
        GuideStep(l.guideVscode4),
        last,
      ],
    AiApp.windsurf => [
        GuideStep(l.guideOrFile(path ?? ''), block: entry, blockLabel: path),
        GuideStep(l.guideDevin2,
            block: 'devin mcp add -s user $mcpServerName -- $full', blockLabel: l.guideTerminal),
        GuideStep(l.guideDevin3),
        last,
      ],
    AiApp.zed => [
        GuideStep(l.guideZed1),
        GuideStep(l.guideZed2, values: fields, block: entry, blockLabel: path),
        GuideStep(l.guideZed3),
        last,
      ],
    AiApp.lmStudio => [
        GuideStep(l.guideLmStudio1),
        GuideStep(l.guideLmStudio2, block: entry, blockLabel: path),
        last,
      ],
    AiApp.grok => [
        GuideStep(l.guideGrok1, block: 'grok mcp add $mcpServerName -- $full', blockLabel: l.guideTerminal),
        GuideStep(l.guideOrFile(path ?? ''), block: entry, blockLabel: path),
        GuideStep(l.guideGrok3),
        last,
      ],
  };
}

Map<String, Object?> _typed(McpServer s) => jsonEntry(s, JsonEntryStyle.typed);

/// JSON for a single-quoted shell argument.
String jsonEncodeForShell(Map<String, Object?> j) => jsonEncode(j).replaceAll("'", "'\\''");

/// The guide: numbered steps.
class AppGuide extends StatelessWidget {
  const AppGuide(
      {super.key, required this.app, required this.server, required this.macos, this.token, this.cli = 'antenna'});
  final AiAppDef app;

  /// The `antenna` CLI's path (when there is no [server] yet).
  final String cli;

  /// `null`: the agent has no token file yet; the guide shows `<token file>` where its path goes.
  final McpServer? server;
  final bool macos;

  /// An older daemon: the token goes into the app's environment instead of a file.
  final String? token;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final s = server ??
        (token != null
            ? McpServer(command: cli, args: const ['mcp'], env: {'ANTENNA_AGENT_TOKEN': token!})
            : McpServer.antenna(cli: cli, tokenFile: l.guideTokenFilePlaceholder));
    final steps = appGuideSteps(l, app, s,
        macos: macos, windows: Platform.isWindows ? windowsPlace(Platform.environment) : null);
    return Column(
      key: Key('guide-${app.id.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, step) in steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: XColors.accentSoft, shape: BoxShape.circle),
                child: Text('${i + 1}', style: XText.label.copyWith(color: XColors.accent, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(step.text, key: Key('guide-step-${i + 1}'), style: XText.body.copyWith(fontSize: 14)),
                  ),
                  for (final (label, value) in step.values)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(children: [
                        SizedBox(width: 110, child: Text(label, style: XText.label)),
                        Expanded(
                          child: SelectableText(value,
                              style: XText.mono.copyWith(color: XColors.text, fontSize: 11)),
                        ),
                        CopyButton(value),
                      ]),
                    ),
                  if (step.block != null) ...[
                    const SizedBox(height: 8),
                    CodeBlock(step.block!, label: step.blockLabel),
                  ],
                ]),
              ),
            ]),
          ),
      ],
    );
  }
}
