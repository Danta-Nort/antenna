// SPDX-License-Identifier: AGPL-3.0-only
// Code mode texts built from state: program names, a run's status, errors in words.

import '../../l10n/app_localizations.dart';
import '../../state/agent_launch.dart';
import '../../state/agent_setup.dart';
import '../../state/code_mode.dart';
import '../../state/messages.dart';

String programName(AppLocalizations l, AgentCli cli) => switch (cli) {
      AgentCli.claude => 'Claude Code',
      AgentCli.codex => 'Codex',
      AgentCli.custom => l.codeProgramCustom,
    };

/// The folder with the home directory as `~`.
String shortFolder(String path, String home) =>
    home.length > 1 && (path == home || path.startsWith('$home/')) ? '~${path.substring(home.length)}' : path;

/// "running", "exited with code 1", "stopped"…
String runStateText(AppLocalizations l, AgentRun r) => switch (r.state) {
      AgentRunState.running => l.codeStateRunning,
      AgentRunState.stopping => l.codeStateStopping,
      AgentRunState.failed => l.codeStateFailed,
      AgentRunState.exited when r.stoppedFrom != null => l.codeStateStoppedFrom(r.stoppedFrom!),
      AgentRunState.exited when r.stoppedByOwner => l.codeStateStopped,
      AgentRunState.exited => switch (r.exitCode) {
          null => l.codeStateEnded,
          final c when c < 0 => l.codeStateSignal(-c),
          final c => l.codeStateExited(c),
        },
    };

/// A Code mode error in words (launch problems, the agent busy elsewhere, daemon errors).
String describeCodeError(AppLocalizations l, Object e) => switch (e) {
      AgentLaunchException(reason: AgentLaunchFailure.noShell) => l.codeErrNoShell,
      AgentLaunchException(reason: AgentLaunchFailure.noProgram, :final detail) => l.codeErrNoProgram(detail),
      AgentLaunchException(reason: AgentLaunchFailure.shimOnly, :final detail) => l.codeErrShimOnly(detail),
      AgentLaunchException(reason: AgentLaunchFailure.noFolder, :final detail) => l.codeErrNoFolder(detail),
      AgentLaunchException(reason: AgentLaunchFailure.badCommand) => l.codeErrBadCommand,
      AgentLaunchException(reason: AgentLaunchFailure.noCli) => l.codeErrNoCli,
      AgentLaunchException(reason: AgentLaunchFailure.noTerminal) => l.codeErrNoTerminal,
      AgentBusyElsewhere(:final boundTo) => l.codeAgentBusy(boundTo),
      AgentNeedsPassword() => l.codeErrNeedsPassword,
      AgentSetupException() => describeSetupError(l, e),
      _ => describeError(l, e),
    };

/// Why "Set up this folder" could not be planned or done.
String describeSetupError(AppLocalizations l, AgentSetupException e) => switch (e.reason) {
      AgentSetupFailure.notFolder => l.setupErrNotFolder(e.path),
      AgentSetupFailure.settingsNotJson => l.setupErrNotJson(e.path),
      AgentSetupFailure.settingsNotObject => l.setupErrNotObject(e.path),
      AgentSetupFailure.permissionsNotObject => l.setupErrPermissions(e.path),
      AgentSetupFailure.allowNotList => l.setupErrAllow(e.path),
      AgentSetupFailure.io => l.setupErrIo(e.path, e.detail),
      AgentSetupFailure.commandFailed => switch (e.exitCode) {
          final c? => l.setupErrCommandExit(e.path, c),
          null => l.setupErrCommandRun(e.path, e.detail),
        },
    };
