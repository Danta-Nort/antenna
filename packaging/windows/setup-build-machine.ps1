# SPDX-License-Identifier: AGPL-3.0-only
# One-time setup of a Windows 10 22H2+ / 11 x64 machine that builds Antenna itself: a self-hosted runner or a hands-on
# test PC (docs/PORTABILITY-WINDOWS.md). The primary Windows build machine is the GitHub-hosted runner
# of .github/workflows/windows.yml, which needs none of this.
#
#   powershell -ExecutionPolicy Bypass -File packaging\windows\setup-build-machine.ps1 [-VisualStudio 2026] [-Cuda]
#
# Idempotent: what is installed is skipped, the Flutter checkout is moved to the pinned tag. It stores no secrets and
# signs in to nothing. winget asks for elevation per package where the installer needs it (Visual Studio, CUDA);
# Developer Mode (symlinks for Flutter plugins) needs an elevated shell, otherwise the script opens the settings page.
# Every winget ID was checked against microsoft/winget-pkgs (manifests/<letter>/<Publisher>/<Name>) on 2026-10-13.
[CmdletBinding()]
param(
    [ValidateSet('2022', '2026')] [string] $VisualStudio = '2022',   # 2022: the host compiler CUDA 12/13 documents
    [switch] $Cuda,                                                  # NVIDIA CUDA Toolkit, for the local model runtime
    [string] $FlutterDir = (Join-Path $env:USERPROFILE 'flutter')
)
$ErrorActionPreference = 'Stop'
$FlutterTag = '3.47.6'   # the version .github/workflows/release.yml and windows.yml pin

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Add-UserPath([string] $dir) {
    if (-not (Test-Path $dir)) { return }
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($user -split ';') -notcontains $dir) {
        [Environment]::SetEnvironmentVariable('Path', ($user.TrimEnd(';') + ';' + $dir), 'User')
        Write-Host "  added to the user PATH: $dir"
    }
    Update-SessionPath
}

function Install-Winget([string] $id, [string[]] $extra = @()) {
    $listed = winget list --id $id --exact --accept-source-agreements | Out-String
    if ($LASTEXITCODE -eq 0 -and $listed -match [regex]::Escape($id)) { Write-Host "ok       $id (installed)"; return }
    Write-Host "install  $id"
    winget install --id $id --exact --source winget --silent --accept-package-agreements --accept-source-agreements @extra
    # 0x8A15002B: already installed (a version winget list did not report); anything else non-zero is a failure.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) { throw "winget install $id failed: $LASTEXITCODE" }
    Update-SessionPath
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget (App Installer) is missing: install it from the Microsoft Store first' }

# Visual Studio Build Tools with the C++ workload: MSVC x64, the Windows 11 SDK, CMake for Flutter's runner
# (flutter_tools checks VC.Tools.x86.x64 and VC.CMake.Project for both the VS and the Build Tools workloads).
$vsComponents = '--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools ' +
    '--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.CMake.Project ' +
    '--add Microsoft.VisualStudio.Component.Windows11SDK.26100 --includeRecommended'
$vsId = if ($VisualStudio -eq '2026') { 'Microsoft.VisualStudio.BuildTools' } else { 'Microsoft.VisualStudio.2022.BuildTools' }

Install-Winget 'Git.Git'
Install-Winget $vsId @('--override', $vsComponents)
Install-Winget 'Rustlang.Rustup'
Install-Winget 'Kitware.CMake'
Install-Winget 'Ninja-build.Ninja'
Install-Winget 'NASM.NASM'
Install-Winget 'StrawberryPerl.StrawberryPerl'
Install-Winget 'Google.Protobuf'
Install-Winget 'LLVM.LLVM'
if ($Cuda) { Install-Winget 'Nvidia.CUDA' }

# Installers that do not put themselves on PATH by default.
Add-UserPath (Join-Path $env:ProgramFiles 'NASM')
Add-UserPath (Join-Path $env:ProgramFiles 'LLVM\bin')
Add-UserPath (Join-Path $env:USERPROFILE '.cargo\bin')

# Rust: the version rust-toolchain.toml pins, MSVC host.
rustup set default-host x86_64-pc-windows-msvc
rustup toolchain install 1.99.0 --profile minimal --component clippy --component rustfmt
if ($LASTEXITCODE -ne 0) { throw 'rustup toolchain install failed' }

# Flutter from git at the pinned tag (the same checkout is reused and moved to the tag on later runs).
if (-not (Test-Path (Join-Path $FlutterDir '.git'))) {
    git clone --depth 1 --branch $FlutterTag https://github.com/flutter/flutter.git $FlutterDir
} else {
    git -C $FlutterDir fetch --depth 1 origin "refs/tags/${FlutterTag}:refs/tags/$FlutterTag"
    git -C $FlutterDir checkout --quiet $FlutterTag
}
if ($LASTEXITCODE -ne 0) { throw "Flutter $FlutterTag checkout failed" }
Add-UserPath (Join-Path $FlutterDir 'bin')

# Developer Mode: Flutter links plugins with symlinks, which a normal user may create only with it on.
$devKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$devOn = (Get-ItemProperty -Path $devKey -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense -eq 1
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($devOn) { Write-Host 'ok       Developer Mode' }
elseif ($admin) {
    New-Item -Path $devKey -Force | Out-Null
    Set-ItemProperty -Path $devKey -Name AllowDevelopmentWithoutDevLicense -Type DWord -Value 1
    Write-Host 'enabled  Developer Mode'
} else {
    Write-Warning 'Developer Mode is off and this shell is not elevated: turn on "Developer Mode" in the page that opens'
    Start-Process 'ms-settings:developers'
}

flutter config --no-analytics | Out-Null
flutter config --enable-windows-desktop | Out-Null
flutter doctor -v

# Windows PowerShell 5.1 turns redirected native stderr into errors; from here on a missing tool is reported, not fatal.
$ErrorActionPreference = 'Continue'
Write-Host "`n== Versions"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$checks = [ordered]@{
    'git'           = { git --version }
    'rustup'        = { rustup --version }
    'rustc'         = { rustc +1.99.0 -vV | Select-String '^(rustc|host)' }
    'Visual Studio' = { & $vswhere -latest -products * -property catalog_productDisplayVersion }
    'cmake'         = { cmake --version | Select-Object -First 1 }
    'ninja'         = { ninja --version }
    'nasm'          = { nasm -v }
    'perl'          = { perl -e 'print "$^V\n"' }
    'protoc'        = { protoc --version }
    'clang'         = { clang --version | Select-Object -First 1 }
    'flutter'       = { flutter --version | Select-Object -First 1 }
    'nvcc'          = { if ($Cuda) { nvcc --version | Select-Object -Last 1 } else { '(not requested)' } }
}
foreach ($name in $checks.Keys) {
    try { $v = (& $checks[$name] | Out-String).Trim() } catch { $v = "MISSING ($($_.Exception.Message))" }
    if (-not $v) { $v = 'MISSING' }
    '{0,-14} {1}' -f $name, ($v -replace '\s+', ' ')
}
