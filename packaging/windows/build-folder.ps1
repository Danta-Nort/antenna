# SPDX-License-Identifier: AGPL-3.0-only
# Antenna for Windows as one folder (W1 of the Windows port, D-134, D-135): the window (Flutter) with the core next to
# it, antennad.exe (the daemon, which the window starts as its child) and antenna.exe (the CLI, and the window's bridge
# to the daemon's pipe). No installer yet (W4): the folder runs where it is put.
#
#   .\packaging\windows\build-folder.ps1 [-Out dist] [-Install]
#
# -Install also copies the folder to %LOCALAPPDATA%\Programs\Antenna (per user, no administrator) and puts an
# "Antenna" shortcut on the desktop and in the Start menu. Run it from a normal (not elevated) PowerShell, in the build
# environment of packaging\windows\setup-build-machine.ps1 (Rust, MSVC, NASM, protoc, Flutter).
param(
  [string]$Out = '',
  [switch]$Install
)
# Native tools write progress to stderr, which Windows PowerShell 5.1 turns into errors under 'Stop': their exit codes
# are checked instead, and the file steps stop on their own errors.
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Out) { $Out = Join-Path $root 'dist' }
$version = (Select-String -Path (Join-Path $root 'Cargo.toml') -Pattern '^version = "(.+)"' | Select-Object -First 1).Matches[0].Groups[1].Value
$commit = (git -C $root rev-parse --short=12 HEAD)
$env:ANTENNA_COMMIT = $commit
$app = Join-Path $root 'apps\antenna_desktop'
$name = "antenna-desktop-$version-windows-x64"
$dest = Join-Path $Out $name

Write-Host "==> core (cargo build --release)"
Push-Location $root
try {
  cargo build --release --locked -p antennad -p antenna-cli 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
} finally { Pop-Location }
$core = Join-Path $root 'target\release'
$got = & (Join-Path $core 'antenna.exe') --version
if ($got -ne "antenna $version ($commit)") { throw "core version '$got' does not match $version ($commit)" }

Write-Host "==> window (flutter build windows --release)"
Push-Location $app
try {
  $numeric = ($version -split '-')[0]
  flutter build windows --release --build-name $numeric --build-number 1 --dart-define "ANTENNA_COMMIT=$commit" 2>&1 |
    ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed ($LASTEXITCODE)" }
} finally { Pop-Location }
$runner = Join-Path $app 'build\windows\x64\runner\Release'

Write-Host "==> $dest"
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest -ErrorAction Stop }
New-Item -ItemType Directory -Force $dest -ErrorAction Stop | Out-Null
Copy-Item -Recurse -Path (Join-Path $runner '*') -Destination $dest -ErrorAction Stop
Copy-Item (Join-Path $core 'antennad.exe'), (Join-Path $core 'antenna.exe') $dest -ErrorAction Stop
Copy-Item (Join-Path $root 'LICENSE-AGPL-3.0'), (Join-Path $root 'LICENSE-APACHE-2.0') $dest -ErrorAction Stop
@"
Antenna $version ($commit) for Windows: a first version (W1).

Open antenna_desktop.exe (or the Antenna shortcut). The window starts the daemon (antennad.exe) itself and stops it
when it closes; your data lives in %LOCALAPPDATA%\Antenna, made for you alone, and the daemon's log in
%LOCALAPPDATA%\AntennaLogs. antenna.exe is the command line: antenna.exe --help.

Not run as administrator: Antenna refuses to start elevated.

In this version: messages, contacts, invites, approvals, and agents through MCP: in the window, Agents -> Connect
gives Claude Code its `claude mcp add` command (run it in PowerShell), writes Claude Desktop's configuration file, and
shows the manual steps for the other apps.
In a terminal, each owner command that needs a session (contacts, send, history, connect) asks for the password:
Windows has no terminal session to keep it for (antenna login explains).
Not yet: Code mode in the window (W2), files (refused with a message until the Windows file check, W3), Windows Hello
(W5).
Known issues:
- A console window may flash when the window runs the command line for updates or app connections.
"@ | Set-Content -Encoding utf8 (Join-Path $dest 'README.txt')

if ($Install) {
  $target = Join-Path $env:LOCALAPPDATA 'Programs\Antenna'
  Write-Host "==> install to $target"
  if (Test-Path $target) { Remove-Item -Recurse -Force $target -ErrorAction Stop }
  New-Item -ItemType Directory -Force $target -ErrorAction Stop | Out-Null
  Copy-Item -Recurse -Path (Join-Path $dest '*') -Destination $target -ErrorAction Stop
  $shell = New-Object -ComObject WScript.Shell
  foreach ($dir in @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('Programs')) ''))) {
    $lnk = $shell.CreateShortcut((Join-Path $dir 'Antenna.lnk'))
    $lnk.TargetPath = Join-Path $target 'antenna_desktop.exe'
    $lnk.WorkingDirectory = $target
    $lnk.IconLocation = (Join-Path $target 'antenna_desktop.exe') + ',0'
    $lnk.Description = 'Antenna'
    $lnk.Save()
    Write-Host "    shortcut: $(Join-Path $dir 'Antenna.lnk')"
  }
}
Write-Host "done: $dest"
