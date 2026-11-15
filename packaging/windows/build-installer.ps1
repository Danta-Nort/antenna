# SPDX-License-Identifier: AGPL-3.0-only
# The per-user installer of Antenna for Windows (W4, D-134; Inno Setup by D-139): builds the folder with
# build-folder.ps1, then packs it with antenna.iss into dist\Antenna-<version>-windows-x86_64-setup.exe and its .sha256.
#
#   .\packaging\windows\build-installer.ps1 [-Out dist] [-CodeMode] [-Folder <a built folder>]
#
# -CodeMode is passed to build-folder.ps1 (the build for Code mode's hands-on check). -Folder packs a folder that is
# already built instead of building one. Needs Inno Setup 6 (ISCC.exe); without an administrator:
#   winget install --id JRSoftware.InnoSetup -e --scope user --silent --accept-package-agreements --accept-source-agreements
# The installer is not signed yet (Authenticode is an open question): Windows SmartScreen warns before it runs.
param(
  [string]$Out = '',
  [switch]$CodeMode,
  [string]$Folder = ''
)
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Out) { $Out = Join-Path $root 'dist' }
New-Item -ItemType Directory -Force $Out -ErrorAction Stop | Out-Null
$version = (Select-String -Path (Join-Path $root 'Cargo.toml') -Pattern '^version = "(.+)"' | Select-Object -First 1).Matches[0].Groups[1].Value

# Inno Setup's version resource takes four numbers: 0.1.0-preview.12 is 0.1.0.12, a release 0.1.0 is 0.1.0.0.
$parts = $version -split '-', 2
$numeric = $parts[0]
$pre = 0
if ($parts.Count -eq 2 -and $parts[1] -match '\.(\d+)$') { $pre = [int]$Matches[1] }
$numeric = "$numeric.$pre"

$iscc = $null
foreach ($c in @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'))) {
  if ($c -and (Test-Path $c)) { $iscc = $c; break }
}
if (-not $iscc) {
  $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($cmd) { $iscc = $cmd.Source }
}
if (-not $iscc) {
  throw "Inno Setup 6 is not installed: winget install --id JRSoftware.InnoSetup -e --scope user --silent --accept-package-agreements --accept-source-agreements"
}

if (-not $Folder) {
  $folderArgs = @{ Out = $Out }
  if ($CodeMode) { $folderArgs.CodeMode = $true }
  & (Join-Path $PSScriptRoot 'build-folder.ps1') @folderArgs
  if (-not $?) { throw 'build-folder.ps1 failed' }
  $Folder = Join-Path $Out "antenna-desktop-$version-windows-x64"
}
foreach ($f in @('antenna_desktop.exe', 'antennad.exe', 'antenna.exe')) {
  if (-not (Test-Path (Join-Path $Folder $f))) { throw "$f is missing in $Folder" }
}

Write-Host "==> installer ($iscc)"
& $iscc /Qp "/DAppVersion=$version" "/DNumericVersion=$numeric" "/DSourceDir=$((Resolve-Path $Folder).Path)" `
  "/DOutputDir=$((Resolve-Path $Out).Path)" (Join-Path $PSScriptRoot 'antenna.iss') 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }
$setup = Join-Path $Out "Antenna-$version-windows-x86_64-setup.exe"
if (-not (Test-Path $setup)) { throw "$setup was not made" }
$hash = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLowerInvariant()
# The same line format as the other platforms' .sha256 files (sha256sum -c reads it).
[IO.File]::WriteAllText("$setup.sha256", "$hash  $(Split-Path -Leaf $setup)`n")
Write-Host "done: $setup ($((Get-Item $setup).Length) bytes, sha256 $hash)"
