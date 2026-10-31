// SPDX-License-Identifier: AGPL-3.0-only
/// Client for the control protocol of the `antennad` daemon (x-control/1, docs/CONTROL.md). Pure Dart, no Flutter:
/// reused by the mobile build and by utilities. The specification is crates/antenna-proto/src/control.rs.
library;

export 'src/agent_stop_api.dart';
export 'src/bridge_mux.dart'
    show
        BridgeChannel,
        BridgeConnection,
        BridgeException,
        BridgeFrame,
        BridgeMux,
        BridgeStarter,
        ProcessBridgeChannel,
        bridgeIdLimit,
        bridgeMaxConnections,
        bridgeMaxFrame,
        daemonUntrustedCode,
        windowBridgeCommand;
export 'src/client.dart' show XControlClient;
export 'src/daemon.dart';
export 'src/daemon_calls.dart' show XDaemonCalls, expectReply;
export 'src/errors.dart';
export 'src/models.dart';
export 'src/proving_daemon.dart';
export 'src/requests.dart';
export 'src/sas.dart';
export 'src/socket_path.dart';
export 'src/teams_api.dart';
