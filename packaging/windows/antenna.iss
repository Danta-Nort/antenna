; SPDX-License-Identifier: AGPL-3.0-only
; The per-user installer of Antenna for Windows (W4 of the Windows port, D-134; the installer choice is D-139).
; Built by packaging\windows\build-installer.ps1 from the folder of build-folder.ps1, with Inno Setup 6:
;
;   ISCC.exe /DAppVersion=0.1.0 /DNumericVersion=0.1.0.0 /DSourceDir=<folder> /DOutputDir=<dir> antenna.iss
;
; Per user, never elevated: the files go to %LOCALAPPDATA%\Programs\Antenna (the folder build-folder.ps1 -Install used,
; so an earlier copy there is replaced in place), the Start menu entry to the user's own Programs, the uninstall entry
; to HKCU. The data folder %LOCALAPPDATA%\Antenna (keys, history) and the logs %LOCALAPPDATA%\AntennaLogs are made by
; antennad, not by this installer, and the uninstaller leaves them: removing the app must never remove an identity.

#ifndef AppVersion
  #error AppVersion is not defined (build-installer.ps1 passes /DAppVersion)
#endif
#ifndef NumericVersion
  #error NumericVersion is not defined (four numbers, such as 0.1.0.0)
#endif
#ifndef SourceDir
  #error SourceDir is not defined (the folder of build-folder.ps1)
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
; The AppId names this program to Windows (its uninstall entry); it never changes between versions.
AppId={{2000E7EC-91B9-4770-8AF3-9E744C7C702B}
AppName=Antenna
AppVersion={#AppVersion}
AppVerName=Antenna {#AppVersion}
AppPublisher=Antenna
VersionInfoVersion={#NumericVersion}
VersionInfoProductName=Antenna
VersionInfoDescription=Antenna setup
UninstallDisplayName=Antenna
UninstallDisplayIcon={app}\antenna_desktop.exe
SetupIconFile=..\..\apps\antenna_desktop\windows\runner\resources\app_icon.ico
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=
DefaultDirName={localappdata}\Programs\Antenna
DisableDirPage=yes
DefaultGroupName=Antenna
DisableProgramGroupPage=yes
DisableReadyPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Windows 10 22H2 and later (D-134)
MinVersion=10.0.19045
; The window holds the daemon on its stdin (--exit-with-stdin, WP-13): closing the window stops the daemon too, so the
; Restart Manager only has to close the window before files are replaced or removed.
CloseApplications=yes
RestartApplications=no
WizardStyle=modern
ShowLanguageDialog=no
LanguageDetectionMethod=uilanguage
OutputDir={#OutputDir}
OutputBaseFilename=Antenna-{#AppVersion}-windows-x86_64-setup
Compression=lzma2/max
SolidCompression=yes

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Antenna"; Filename: "{app}\antenna_desktop.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\Antenna"; Filename: "{app}\antenna_desktop.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\antenna_desktop.exe"; Description: "{cm:LaunchProgram,Antenna}"; Flags: nowait postinstall skipifsilent
