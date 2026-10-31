// SPDX-License-Identifier: AGPL-3.0-only
// "Install the antenna command in the terminal" (D-58): real symlinks in a temporary $HOME; the macOS password prompt
// (osascript) and the login shell run on a stand-in executor (there is no macOS here). App version = pubspec = Cargo.toml.

import 'dart:io';

import 'package:antenna_desktop/host/cli_install.dart';
import 'package:antenna_desktop/version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late String home;
  late String cli;

  setUp(() {
    root = Directory.systemTemp.createTempSync('cli-install-');
    home = '${root.path}/home';
    Directory(home).createSync();
    final app = Directory('${root.path}/Antenna.app/Contents/Helpers')..createSync(recursive: true);
    cli = '${app.path}/antenna';
    File(cli).writeAsStringSync('#!/bin/sh\necho "antenna 0.1.0-preview.1 (test)"\n');
    Process.runSync('chmod', ['+x', cli]);
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// The owner's login shell: PATH with [dirs].
  CliCommandRunner shellWith(List<String> dirs, {List<List<String>>? calls}) =>
      (exe, args, {required timeout}) async {
        calls?.add([exe, ...args]);
        return ProcessResult(1, 0, 'Welcome!\n__ANTENNA_PATH__${dirs.join(':')}\n', '');
      };

  test('installs ~/.local/bin/antenna → the CLI inside the app, without admin rights; the command runs', () async {
    final i = CliInstaller(cliPath: cli, home: home, os: 'linux', shell: '/bin/bash', runner: shellWith(['/usr/bin']));
    var s = await i.status();
    expect(s.state, CliLinkState.absent);
    expect(Directory('$home/.local/bin').existsSync(), isFalse);

    s = await i.installUser();
    expect(s.state, CliLinkState.installed);
    expect(Link(i.userLink).targetSync(), cli);
    expect(s.inPath, isFalse, reason: '~/.local/bin is not in the PATH of the login shell');
    expect(i.pathHint(), "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc");
    final r = Process.runSync(i.userLink, ['--version']);
    expect('${r.stdout}', contains('antenna 0.1.0-preview.1'));

    // Repeating gives the same link without errors; PATH is already set.
    final again = CliInstaller(
        cliPath: cli, home: home, os: 'linux', shell: '/bin/bash', runner: shellWith(['$home/.local/bin', '/usr/bin']));
    expect((await again.installUser()).inPath, isTrue);
  });

  test('replaces a link to another place (moved app), never a regular file', () async {
    final i = CliInstaller(cliPath: cli, home: home, os: 'macos', shell: '/bin/zsh', runner: shellWith([]));
    Directory('$home/.local/bin').createSync(recursive: true);
    Link(i.userLink).createSync('/Volumes/Antenna/Antenna.app/Contents/Helpers/antenna');
    var s = await i.status();
    expect(s.state, CliLinkState.otherLink);
    expect(s.currentTarget, '/Volumes/Antenna/Antenna.app/Contents/Helpers/antenna');
    s = await i.installUser();
    expect(s.state, CliLinkState.installed);
    expect(i.pathHint(), contains('~/.zprofile'));

    // A regular file (for example from the install.sh archive) is left alone.
    Link(i.userLink).deleteSync();
    File(i.userLink).writeAsStringSync('binary from install.sh');
    expect((await i.status()).state, CliLinkState.otherFile);
    await expectLater(
      i.installUser(),
      throwsA(isA<CliInstallException>()
          .having((e) => e.reason, 'reason', CliInstallFailure.userFileExists)
          .having((e) => e.path, 'path', i.userLink)),
    );
    expect(File(i.userLink).readAsStringSync(), 'binary from install.sh');
  });

  test('the dangling ~/.local/bin/x of the preview build is removed, any other x stays', () async {
    final i = CliInstaller(cliPath: cli, home: home, os: 'macos', shell: '/bin/zsh', runner: shellWith([]));
    Directory('$home/.local/bin').createSync(recursive: true);
    Link('$home/.local/bin/x').createSync('/Applications/x.app/Contents/Helpers/x');
    await i.installUser();
    expect(FileSystemEntity.typeSync('$home/.local/bin/x', followLinks: false), FileSystemEntityType.notFound);

    Link('$home/.local/bin/x').createSync('/opt/other/x');
    await i.installUser();
    expect(Link('$home/.local/bin/x').targetSync(), '/opt/other/x');
  });

  test('/usr/local/bin on macOS: the standard macOS password prompt via osascript; cancel is not an error', () async {
    final calls = <List<String>>[];
    var cancel = false;
    final sys = '${root.path}/usr-local-bin';
    final i = CliInstaller(
      cliPath: cli,
      home: home,
      os: 'macos',
      shell: '/bin/zsh',
      systemDir: sys,
      runner: (exe, args, {required timeout}) async {
        calls.add([exe, ...args]);
        if (exe == '/usr/bin/osascript') {
          return cancel
              ? ProcessResult(1, 1, '', '0:96: execution error: User canceled. (-128)')
              : ProcessResult(1, 0, '', '');
        }
        return ProcessResult(1, 0, '__ANTENNA_PATH__/usr/bin\n', '');
      },
    );
    expect(i.offersSystemInstall, isTrue);
    expect(await i.installSystem(prompt: 'Antenna is installing the antenna command into $sys'), isTrue);
    final osa = calls.firstWhere((c) => c.first == '/usr/bin/osascript');
    expect(osa[1], '-e');
    final script = osa[2];
    expect(script, startsWith('do shell script "/bin/mkdir -p " & quoted form of "$sys"'));
    expect(script, contains('" && /bin/ln -sfn " & quoted form of "$cli" & " " & quoted form of "$sys/antenna"'));
    expect(script, contains('with prompt "Antenna is installing the antenna command into $sys"'));
    expect(script, endsWith('with administrator privileges'));
    cancel = true;
    expect(await i.installSystem(prompt: 'x'), isFalse);

    // Quotes and backslashes in the path do not break the AppleScript string.
    final odd = CliInstaller(cliPath: r'/Apps/My "A\B"/antenna', home: home, os: 'macos', runner: shellWith([]));
    expect(odd.adminScript('p'), contains(r'quoted form of "/Apps/My \"A\\B\"/antenna"'));
    // The password prompt text (in the app language) is escaped the same way.
    expect(odd.adminScript('say "hi"'), contains(r'with prompt "say \"hi\""'));

    // Linux has no such option.
    expect(CliInstaller(cliPath: cli, home: home, os: 'linux').offersSystemInstall, isFalse);
  });

  test('version of the window = pubspec.yaml = Cargo.toml workspace version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final pv = RegExp(r'^version: (\S+)$', multiLine: true).firstMatch(pubspec)!.group(1)!;
    expect(pv.split('+').first, appVersion);
    final cargo = File('../../Cargo.toml').readAsStringSync();
    final cv = RegExp(r'^\[workspace\.package\]\s*\nversion = "([^"]+)"', multiLine: true).firstMatch(cargo)!.group(1)!;
    expect(cv, appVersion);
    expect(appVersionLine, startsWith('Antenna $appVersion ('));
  });
}
