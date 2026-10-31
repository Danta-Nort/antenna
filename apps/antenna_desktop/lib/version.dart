// SPDX-License-Identifier: AGPL-3.0-only
// The app version equals `version` in pubspec.yaml and `workspace.package.version` in Cargo.toml (a test checks all three).

/// App version.
const String appVersion = '0.1.0';

/// Build commit: `--dart-define=ANTENNA_COMMIT=<hash>` (packaging), otherwise `dev` (`flutter run`, tests).
const String appCommit = String.fromEnvironment('ANTENNA_COMMIT', defaultValue: 'dev');

/// «Antenna 0.1.0-preview.11 (1c63cc92d7bf)».
const String appVersionLine = 'Antenna $appVersion ($appCommit)';
