# SPDX-License-Identifier: AGPL-3.0-only
# Checks the per-user installer of Antenna for Windows (W4, D-139) on a Windows computer: a silent install, the files,
# the Start menu entry, the uninstall entry, the version of both executables; with -Uninstall also a silent uninstall
# that leaves the data folder, and with -Reinstall an install again afterwards. One line per check, `ok` or `FAIL`;
# the exit code is the number of failures.
#
#   .\packaging\windows\check-install.ps1 -Setup dist\Antenna-<v>-windows-x86_64-setup.exe [-Uninstall] [-Reinstall]
#
# It refuses to run while Antenna is open (it would close the person's window); nothing is installed elevated.
param(
  [Parameter(Mandatory = $true)][string]$Setup,
  [switch]$Uninstall,
  [switch]$Reinstall
)
$ErrorActionPreference = 'Continue'
$fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "ok   $what $detail" } else { Write-Host "FAIL $what $detail"; $script:fail++ }
}

$appId = '{2000E7EC-91B9-4770-8AF3-9E744C7C702B}_is1'
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appId"
$dir = Join-Path $env:LOCALAPPDATA 'Programs\Antenna'
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Antenna.lnk'
$data = Join-Path $env:LOCALAPPDATA 'Antenna'
$setupName = Split-Path -Leaf $Setup
if ($setupName -notmatch '^Antenna-(.+)-windows-x86_64-setup\.exe$') { throw "not an Antenna installer name: $setupName" }
$version = $Matches[1]

if (Get-Process -Name antenna_desktop, antennad -ErrorAction SilentlyContinue) {
  throw 'Antenna is running: close it first (this check never closes it for you)'
}
$dataBefore = Test-Path $data

function Install {
  $p = Start-Process -FilePath $Setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-' -Wait -PassThru
  Check 'install exit code' ($p.ExitCode -eq 0) "($($p.ExitCode))"
  foreach ($f in @('antenna_desktop.exe', 'antennad.exe', 'antenna.exe', 'flutter_windows.dll', 'unins000.exe')) {
    Check "file $f" (Test-Path (Join-Path $dir $f))
  }
  Check 'Start menu entry' (Test-Path $menu) $menu
  $entry = Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue
  Check 'uninstall entry (per user)' ($null -ne $entry) $uninstallKey
  if ($entry) { Check 'uninstall entry version' ($entry.DisplayVersion -eq $version) "($($entry.DisplayVersion))" }
  Check 'no machine-wide entry' (-not (Test-Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appId"))
  foreach ($exe in @('antenna.exe', 'antennad.exe')) {
    $got = & (Join-Path $dir $exe) --version 2>&1 | Select-Object -First 1
    Check "$exe --version" ("$got" -like "* $version (*") "($got)"
  }
}

Install
if ($Uninstall) {
  $p = Start-Process -FilePath (Join-Path $dir 'unins000.exe') -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
  Check 'uninstall exit code' ($p.ExitCode -eq 0) "($($p.ExitCode))"
  # The uninstaller finishes from a copy of itself in %TEMP%: give it a moment to remove the folder.
  for ($i = 0; $i -lt 30 -and (Test-Path (Join-Path $dir 'antenna.exe')); $i++) { Start-Sleep -Milliseconds 500 }
  Check 'program files removed' (-not (Test-Path (Join-Path $dir 'antenna.exe')))
  Check 'Start menu entry removed' (-not (Test-Path $menu))
  Check 'uninstall entry removed' (-not (Test-Path $uninstallKey))
  Check 'data folder left as it was' ((Test-Path $data) -eq $dataBefore) "($data)"
  if ($Reinstall) { Install }
}
Write-Host "failures: $fail"
exit $fail
