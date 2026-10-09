; Windows installer for Uppies (Inno Setup 6).
;
;     jai build.jai - bundle    release build, then bin\Uppies-<version>-setup.exe
;
; build.jai runs this script with Inno Setup's command-line compiler (ISCC),
; passing the version from build.jai, so it lives in one place. To compile it
; by hand (from the Inno Setup IDE, say), build first and give the version:
;
;     ISCC /DAppVersion=1.0.0 installer\uppies.iss
;
; Uppies installs per user by default, into %LOCALAPPDATA%\Programs\Uppies,
; without asking for administrator rights; the first page offers to install
; for all users instead. Its data is per user anyway (%APPDATA%\Uppies).

#ifndef AppVersion
  #error AppVersion is not defined: build with "jai build.jai - bundle", or pass /DAppVersion=x.y.z to ISCC.
#endif

#define AppName "Uppies"
#define AppExe  "uppies.exe"
#define AppURL  "https://github.com/rubenbala/uppies"

[Setup]
; Never change AppId: it is how Windows, and the next version's installer,
; know Uppies is installed, so an upgrade replaces it in place.
AppId={{5F7D1832-5A50-4EFA-ADD2-913CBA7C85CC}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Ruben Bala
AppCopyright=Copyright (C) 2026 Ruben Bala
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
VersionInfoVersion={#AppVersion}
VersionInfoDescription={#AppName} Setup

; Every path below is relative to the repository root.
SourceDir=..
OutputDir=bin
OutputBaseFilename={#AppName}-{#AppVersion}-setup
; Written by build.jai from assets\icon.png.
SetupIconFile=.build\uppies.ico

PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExe}

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

; Light or dark, following Windows.
WizardStyle=modern dynamic
Compression=lzma2/max
SolidCompression=yes

[Tasks]
Name: "startmenuicon"; Description: "Create a &Start Menu shortcut"; GroupDescription: "{cm:AdditionalIcons}"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "bin\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "bin\freetype.dll"; DestDir: "{app}"; Flags: ignoreversion
; Optional fonts (see README); nothing is there by default.
Source: "bin\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
Source: "LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"
Source: "THIRD_PARTY.md"; DestDir: "{app}"; DestName: "THIRD_PARTY.txt"
; The FreeType License, which freetype.dll requires alongside it (see THIRD_PARTY.md).
Source: "installer\FTL.TXT"; DestDir: "{app}"; Flags: skipifsourcedoesntexist

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: startmenuicon
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Code]
// Uninstalling leaves %APPDATA%\Uppies (the token, the local copy, settings,
// hidden recurring payments and custom themes) unless the user says
// otherwise, so a reinstall picks up where it left off. A silent uninstall
// always keeps it.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Dir: String;
begin
  if CurUninstallStep <> usPostUninstall then Exit;
  Dir := ExpandConstant('{userappdata}\Uppies');
  if UninstallSilent or not DirExists(Dir) then Exit;
  if MsgBox('Also delete your Uppies data from this PC?' + #13#10#13#10 +
            'This removes the saved access token, the downloaded copy of your transactions, ' +
            'your settings and your own themes, in:' + #13#10 + Dir + #13#10#13#10 +
            'Choose No to keep them for when you install Uppies again.',
            mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    DelTree(Dir, True, True, True);
end;
