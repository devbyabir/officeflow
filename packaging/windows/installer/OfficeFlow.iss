; OfficeFlow Windows x64 installer (Inno Setup 6). Per-user install, no administrator rights.
; Build after packaging/windows/build-zip.ps1 has staged the app folder:
;   iscc /DAppVersion=1.0.0 /DSourceDir=<staged folder> /DOutputDir=<output> OfficeFlow.iss
; Signing (prepared, off until a certificate exists): add /DSignTool=officeflow and
;   /Sofficeflow="<signing command> $f" to sign the setup and its uninstaller.
;
; The workspace stays in %LOCALAPPDATA%\OfficeFlow, outside {app}: installing, upgrading and
; uninstalling never touch it.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<folder staged by build-zip.ps1>
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
AppId={{694B07A4-E3EF-4976-94E2-2A9FAB580EE2}
AppName=OfficeFlow
AppVersion={#AppVersion}
AppVerName=OfficeFlow {#AppVersion}
AppPublisher=devbyabir
AppPublisherURL=https://github.com/devbyabir/officeflow
AppSupportURL=https://github.com/devbyabir/officeflow
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\OfficeFlow
DisableDirPage=yes
DefaultGroupName=OfficeFlow
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
LicenseFile={#SourceDir}\TERMS.txt
OutputDir={#OutputDir}
OutputBaseFilename=OfficeFlow-Setup-{#AppVersion}-x64
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\icon\officeflow.ico
UninstallDisplayIcon={app}\OfficeFlow.exe
UninstallDisplayName=OfficeFlow
; OfficeFlow runs without a window, so instead of asking the user to close it, setup and
; uninstall ask it to quit cleanly (see StopOfficeFlow below). OfficeFlow.exe holds the
; "OfficeFlow.Launcher" mutex while it runs.
CloseApplications=no
SetupLogging=yes
#ifdef SignTool
SignTool={#SignTool}
SignedUninstaller=yes
#endif

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; Flags: unchecked

[InstallDelete]
; Replace the program folders completely on upgrade, so no stale runtime files remain.
Type: filesandordirs; Name: "{app}\runtime"
Type: filesandordirs; Name: "{app}\app"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
; The icon embedded in OfficeFlow.exe (packaging/windows/icon/officeflow.ico).
Name: "{autoprograms}\OfficeFlow"; Filename: "{app}\OfficeFlow.exe"; WorkingDir: "{app}"; IconFilename: "{app}\OfficeFlow.exe"; IconIndex: 0; Comment: "Open OfficeFlow in your browser"
Name: "{autoprograms}\Quit OfficeFlow"; Filename: "{app}\OfficeFlow.exe"; Parameters: "--quit"; WorkingDir: "{app}"; IconFilename: "{app}\OfficeFlow.exe"; IconIndex: 0; Comment: "Stop OfficeFlow on this computer; your workspace is saved"
Name: "{autodesktop}\OfficeFlow"; Filename: "{app}\OfficeFlow.exe"; WorkingDir: "{app}"; IconFilename: "{app}\OfficeFlow.exe"; IconIndex: 0; Tasks: desktopicon

[Run]
Filename: "{app}\OfficeFlow.exe"; WorkingDir: "{app}"; Description: "Start OfficeFlow now"; Flags: nowait postinstall skipifsilent

[Code]
const
  RedistUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe';
  RuntimeKey = 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64';

var
  DownloadPage: TDownloadWizardPage;

{ True when Microsoft's x64 Visual C++ runtime 14.40.33810 or newer is installed. }
function VisualCppRuntimeOK: Boolean;
var
  Installed, Major, Minor, Build: Cardinal;
begin
  Result := False;
  if RegQueryDWordValue(HKLM64, RuntimeKey, 'Installed', Installed) and (Installed = 1) and
     RegQueryDWordValue(HKLM64, RuntimeKey, 'Major', Major) and
     RegQueryDWordValue(HKLM64, RuntimeKey, 'Minor', Minor) and
     RegQueryDWordValue(HKLM64, RuntimeKey, 'Bld', Build) then
    Result := (Major > 14) or ((Major = 14) and ((Minor > 40) or ((Minor = 40) and (Build >= 33810))));
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage('Microsoft Visual C++ Redistributable',
    'Downloading vc_redist.x64.exe from Microsoft...', nil);
end;

{ OfficeFlow does not redistribute Microsoft's files: if the runtime is missing, setup downloads
  Microsoft's official installer from Microsoft and runs it with the user's approval. }
procedure InstallVisualCppRuntime;
var
  ResultCode: Integer;
begin
  if SuppressibleMsgBox('OfficeFlow needs the Microsoft Visual C++ Redistributable for Visual Studio ' +
       '2015-2022 (x64), version 14.40 or newer, and it is not installed.' + #13#10#13#10 +
       'Setup can download Microsoft''s official installer from ' + RedistUrl + ' and run it now. ' +
       'Windows will ask for administrator permission.' + #13#10#13#10 +
       'Download and install it now?', mbConfirmation, MB_YESNO, IDNO) <> IDYES then
  begin
    SuppressibleMsgBox('OfficeFlow will be installed. Before starting it, install the X64 Visual C++ ' +
      'Redistributable from https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist. ' +
      'OfficeFlow will also show this link if the runtime is missing.', mbInformation, MB_OK, IDOK);
    exit;
  end;
  DownloadPage.Clear;
  DownloadPage.Add(RedistUrl, 'vc_redist.x64.exe', '');
  DownloadPage.Show;
  try
    try
      DownloadPage.Download;
      if not ShellExec('runas', ExpandConstant('{tmp}\vc_redist.x64.exe'), '/install /passive /norestart',
           '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
        SuppressibleMsgBox('Microsoft''s installer could not be started (' + SysErrorMessage(ResultCode) + ').',
          mbError, MB_OK, IDOK);
    except
      SuppressibleMsgBox('The download from Microsoft failed: ' + GetExceptionMessage, mbError, MB_OK, IDOK);
    end;
  finally
    DownloadPage.Hide;
  end;
  if not VisualCppRuntimeOK then
    SuppressibleMsgBox('The Visual C++ Redistributable is still not installed. OfficeFlow will be installed, ' +
      'and it will show how to install the runtime when it starts.', mbInformation, MB_OK, IDOK);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpReady) and not VisualCppRuntimeOK then
    InstallVisualCppRuntime;
end;

{ OfficeFlow runs without a window. Before files are replaced or removed, ask a running
  OfficeFlow to quit cleanly through its local address (as its "Quit OfficeFlow" button does),
  then wait until OfficeFlow.exe has exited. Returns False if it is still running. }
function StopOfficeFlow(Silent: Boolean): Boolean;
var
  Request: Variant;
  Waited: Integer;
begin
  Result := not CheckForMutexes('OfficeFlow.Launcher');
  if Result then
    exit;
  if not Silent then
    if MsgBox('OfficeFlow is running. Setup will stop it first; your workspace is saved.' + #13#10#13#10 +
         'Continue?', mbConfirmation, MB_OKCANCEL) <> IDOK then
      exit;
  try
    Request := CreateOleObject('WinHttp.WinHttpRequest.5.1');
    Request.Open('POST', 'http://127.0.0.1:8080/api/quit', False);
    Request.SetRequestHeader('Content-Type', 'application/json');
    Request.Send('{}');
    Log('Asked OfficeFlow to quit: HTTP ' + IntToStr(Request.Status));
  except
    Log('Could not ask OfficeFlow to quit: ' + GetExceptionMessage);
  end;
  Waited := 0;
  while CheckForMutexes('OfficeFlow.Launcher') and (Waited < 30000) do
  begin
    Sleep(250);
    Waited := Waited + 250;
  end;
  Result := not CheckForMutexes('OfficeFlow.Launcher');
  Log('OfficeFlow stopped before file changes: ' + IntToStr(Ord(Result)));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not StopOfficeFlow(WizardSilent) then
    Result := 'OfficeFlow is still running. Use "Quit OfficeFlow" in OfficeFlow or the Start menu, then run setup again.';
end;

function InitializeUninstall: Boolean;
begin
  Result := StopOfficeFlow(UninstallSilent);
  if not Result then
    SuppressibleMsgBox('OfficeFlow is still running. Use "Quit OfficeFlow" in OfficeFlow or the Start menu, ' +
      'then uninstall again.', mbError, MB_OK, IDOK);
end;
