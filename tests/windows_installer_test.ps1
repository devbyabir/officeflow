# Tests the OfficeFlow installer on a disposable Windows machine (CI runner): install, Start menu
# shortcuts and icons, first start from the Start menu with browser setup, saving an inventory
# item, quitting with the "Quit OfficeFlow" shortcut, restart, an upgrade while OfficeFlow runs
# (setup asks it to quit cleanly first), a reinstall with OfficeFlow stopped, and uninstall
# keeping the workspace. The runner's own per-user folders are used, as a real installation
# would. Nothing is force-killed to stop OfficeFlow.
param(
  [Parameter(Mandatory = $true)][string]$Installer,
  [Parameter(Mandatory = $true)][string]$UpgradeInstaller
)
$ErrorActionPreference = "Stop"
$base = "http://127.0.0.1:8080"
$password = "install-pass"
$appId = "{694B07A4-E3EF-4976-94E2-2A9FAB580EE2}_is1"
$installDir = Join-Path $env:LOCALAPPDATA "Programs\OfficeFlow"
$dataDir = Join-Path $env:LOCALAPPDATA "OfficeFlow"
$database = Join-Path $dataDir "officeflow.mv.db"
$log = Join-Path $dataDir "officeflow.log"
$programs = [Environment]::GetFolderPath("Programs")
$shortcut = Join-Path $programs "OfficeFlow.lnk"
$quitShortcut = Join-Path $programs "Quit OfficeFlow.lnk"
$work = Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }) "OfficeFlow installer test"
$output = Join-Path $work "Launcher output"
New-Item -ItemType Directory -Force $work, $output | Out-Null
# OfficeFlow.exe writes the browser address and its messages here instead of opening them.
$env:OFFICEFLOW_TEST_OUTPUT = $output

function Notice([string]$Message) { Write-Output "::notice title=Installer test::$Message" }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "Check failed: $Message" } }
function Invoke-Api([string]$Path, $Body = $null, [string]$Token = "", [int]$Expected = 200) {
  $parameters = @{ Uri = "$base$Path"; Method = "Get"; SkipHttpErrorCheck = $true; StatusCodeVariable = "status" }
  if ($Token) { $parameters.Headers = @{ Authorization = "Bearer $Token" } }
  if ($null -ne $Body) { $parameters.Method = "Post"; $parameters.ContentType = "application/json"; $parameters.Body = $Body | ConvertTo-Json -Depth 5 }
  $result = Invoke-RestMethod @parameters
  if ($status -ne $Expected) { throw "$Path returned $status, expected ${Expected}" }
  return $result
}
function Test-Ready { try { (Invoke-RestMethod "$base/api/health" -TimeoutSec 2).service -eq "officeflow" } catch { $false } }
function Test-PortFree { -not (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue) }
function Login { (Invoke-Api "/api/login" @{ username = "installer.admin"; password = $password }).token }
function Get-Supplies { @((Invoke-Api "/api/state" -Token (Login)).supplies | ForEach-Object { $_.name }) }
function Get-CleanStops { if (Test-Path $log) { @(Get-Content $log | Where-Object { $_ -match 'stopped cleanly; database closed' }).Count } else { 0 } }
function Get-DisplayVersion { (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appId" -ErrorAction SilentlyContinue).DisplayVersion }
function Get-Launcher { Get-CimInstance Win32_Process -Filter "Name = 'OfficeFlow.exe'" | Where-Object { $_.ExecutablePath -like "$installDir\*" } | Select-Object -First 1 }
function Wait-Opened([int]$Count) {
  $file = Join-Path $output "opened-url.txt"
  for ($i = 0; $i -lt 120; $i++) { $lines = @(if (Test-Path $file) { Get-Content $file }); if ($lines.Count -ge $Count) { return $lines[-1] }; Start-Sleep -Milliseconds 250 }
  throw "OfficeFlow.exe did not open the browser (address $Count)"
}
$script:opened = 0

function Invoke-Setup([string]$Path, [string]$Name) {
  $setupLog = Join-Path $work "$Name.log"
  $process = Start-Process -FilePath $Path -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/LOG=`"$setupLog`"" -Wait -PassThru
  return $process.ExitCode
}

# Opens the Start menu shortcut (a shell launch, like clicking it); returns OfficeFlow.exe and
# the address it opened in the browser.
function Start-FromShortcut {
  Start-Process -FilePath $shortcut | Out-Null
  for ($i = 0; $i -lt 240; $i++) {
    $launcher = Get-Launcher
    if ($launcher -and (Test-Ready)) {
      $script:opened++
      return [pscustomobject]@{ Launcher = $launcher; Url = (Wait-Opened $script:opened) }
    }
    Start-Sleep -Milliseconds 500
  }
  throw "OfficeFlow did not start from the Start menu shortcut"
}

# Waits for OfficeFlow.exe and its java.exe to end cleanly after a quit request.
function Assert-CleanStop($Launcher, [int]$CleanStopsBefore, [string]$How) {
  for ($i = 0; $i -lt 120 -and (Get-Process -Id $Launcher.ProcessId -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
  Assert (-not (Get-Process -Id $Launcher.ProcessId -ErrorAction SilentlyContinue)) "OfficeFlow.exe exits after $How"
  Assert (-not (Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" | Where-Object { $_.ExecutablePath -like "$installDir\*" })) "the bundled java.exe exits after $How"
  for ($i = 0; $i -lt 40 -and -not (Test-PortFree); $i++) { Start-Sleep -Milliseconds 250 }
  Assert (Test-PortFree) "port 8080 is released after $How"
  Assert ((Get-CleanStops) -eq $CleanStopsBefore + 1) "officeflow.log records a clean stop after $How"
}

# Quits with the "Quit OfficeFlow" Start menu shortcut.
function Stop-FromShortcut($Launcher) {
  $before = Get-CleanStops
  Start-Process -FilePath $quitShortcut | Out-Null
  Assert-CleanStop $Launcher $before "the Quit OfficeFlow shortcut"
}

try {
  $os = Get-CimInstance Win32_OperatingSystem
  $runtime = Get-Item (Join-Path $env:SystemRoot "System32\vcruntime140.dll") -ErrorAction SilentlyContinue
  $systemJava = Get-Command java -ErrorAction SilentlyContinue
  Notice ("Environment: $($os.Caption) build $($os.BuildNumber); x64 Visual C++ runtime " +
    "$(if ($runtime) { $runtime.VersionInfo.FileVersion } else { 'absent' }) (so setup's download step is not exercised); " +
    "system Java on PATH: $(if ($systemJava) { $systemJava.Source + ' (not used: OfficeFlow runs its bundled runtime)' } else { 'none' })")
  Assert (-not (Test-Path $installDir)) "no earlier installation"
  Assert (-not (Test-Path $dataDir)) "no earlier workspace"

  # Install.
  $code = Invoke-Setup $Installer "install"
  Assert ($code -eq 0) "setup exits with code 0 (got $code)"
  foreach ($file in "OfficeFlow.exe", "runtime\bin\java.exe", "app\officeflow.jar", "app\site\index.html", "app\site\officeflow-icon.svg", "TERMS.txt", "Quick Start.txt", "unins000.exe") {
    Assert (Test-Path (Join-Path $installDir $file)) "installed $file"
  }
  $shell = New-Object -ComObject WScript.Shell
  $exe = Join-Path $installDir "OfficeFlow.exe"
  $link = $shell.CreateShortcut($shortcut)
  Assert ($link.TargetPath -eq $exe) "the Start menu shortcut opens OfficeFlow.exe ($($link.TargetPath))"
  Assert ($link.IconLocation -eq "$exe,0") "the Start menu shortcut uses OfficeFlow.exe's embedded icon ($($link.IconLocation))"
  $quitLink = $shell.CreateShortcut($quitShortcut)
  Assert ($quitLink.TargetPath -eq $exe -and $quitLink.Arguments -eq "--quit") "the Quit OfficeFlow shortcut runs OfficeFlow.exe --quit"
  Assert ((Get-DisplayVersion) -eq "1.0.2") "Apps & features lists OfficeFlow 1.0.2"
  # The installed terms must be TERMS.md from this commit; only CRLF versus LF may differ.
  $installedTerms = Join-Path $installDir "TERMS.txt"
  $repoTerms = Join-Path (Split-Path $PSScriptRoot -Parent) "TERMS.md"
  Assert (Test-Path $installedTerms) "TERMS.txt is installed"
  $installedText = [IO.File]::ReadAllText($installedTerms) -replace "`r`n", "`n"
  $repoText = [IO.File]::ReadAllText($repoTerms) -replace "`r`n", "`n"
  Assert ($installedText -ceq $repoText) "the installed TERMS.txt matches TERMS.md from this commit"
  $termsHash = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($repoText))) -Algorithm SHA256).Hash.ToLowerInvariant()
  Notice "Installed TERMS.txt matches TERMS.md from this commit ($($repoText.Length) characters, LF-normalised SHA-256 $termsHash)"
  Notice "Installed per user to $installDir without administrator rights; shortcuts 'OfficeFlow' ($($link.IconLocation)) and 'Quit OfficeFlow' (--quit); listed as OfficeFlow $(Get-DisplayVersion)"

  # First start from the Start menu: the browser opens on the setup screen.
  $start = Start-FromShortcut
  Assert ($start.Url -match '^http://127\.0\.0\.1:8080/#setup=([A-Za-z0-9_-]{32,128})$') "the first start opens the setup screen ($($start.Url))"
  $token = $Matches[1]
  $created = Invoke-Api "/api/setup" @{ token = $token; username = "Installer.Admin"; password = $password; confirmPassword = $password; hint = "office clue" }
  Assert ($created.actor.username -eq "installer.admin" -and $created.token) "Create account signs the administrator in"
  Assert ((Invoke-Api "/api/setup").status -eq "done") "setup is closed after the first administrator"
  Assert (Test-Path $database) "the workspace is created at $database"
  Assert (-not (Test-Path (Join-Path $installDir "officeflow.mv.db"))) "no data inside the install folder"
  Invoke-Api "/api/command" @{ action = "saveSupply"; data = @{
      name = "Installer check paper"; category = "Paper & print"; quantity = "8"; threshold = "2"; unit = "reams" } } (Login) | Out-Null
  Assert ((Get-Supplies) -contains "Installer check paper") "the inventory item is saved"
  Stop-FromShortcut $start.Launcher
  Notice "First start from the Start menu: setup screen with a one-time token, admin created, workspace at $database (outside the install folder), item saved; the Quit OfficeFlow shortcut stopped it cleanly"

  # Reopen from the Start menu: sign-in, item still there.
  $start = Start-FromShortcut
  Assert ($start.Url -eq "$base/") "a returning start opens sign-in, not setup ($($start.Url))"
  Assert ((Get-Supplies) -contains "Installer check paper") "the item survives quitting and reopening"
  Assert ((Invoke-Api "/api/login" @{ username = "001"; password = $password }).actor.username -eq "installer.admin") "the account ID 001 still logs in"

  # Upgrade while OfficeFlow runs: setup asks it to quit cleanly, then replaces the files.
  $before = Get-CleanStops
  $code = Invoke-Setup $UpgradeInstaller "upgrade-while-running"
  Assert ($code -eq 0) "the upgrade exits with code 0 (got $code)"
  Assert-CleanStop $start.Launcher $before "the upgrade's quit request"
  Assert ((Get-DisplayVersion) -eq "1.0.3") "Apps & features lists the upgraded version 1.0.3"
  $start = Start-FromShortcut
  Assert ($start.Url -eq "$base/") "after the upgrade OfficeFlow opens sign-in"
  Assert ((Get-Supplies) -contains "Installer check paper") "the item and the admin account survive the upgrade"
  Stop-FromShortcut $start.Launcher
  Notice "Upgrade to 1.0.3 while OfficeFlow ran: setup stopped it cleanly first (clean stop logged), exit code 0; admin account and item still there; quit cleanly"

  # Reinstall with OfficeFlow stopped: the workspace file is not touched.
  $hashBefore = (Get-FileHash $database).Hash
  $code = Invoke-Setup $UpgradeInstaller "reinstall"
  Assert ($code -eq 0) "the reinstall exits with code 0 (got $code)"
  Assert ((Get-FileHash $database).Hash -eq $hashBefore) "installing leaves the workspace file byte-for-byte unchanged"
  Notice "Reinstall with OfficeFlow stopped: exit code 0, workspace file byte-for-byte unchanged"

  # Uninstall while OfficeFlow runs: it is stopped cleanly, the workspace is kept.
  $start = Start-FromShortcut
  $before = Get-CleanStops
  $uninstaller = Join-Path $installDir "unins000.exe"
  Start-Process -FilePath $uninstaller -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait | Out-Null
  Assert-CleanStop $start.Launcher $before "uninstall's quit request"
  for ($i = 0; $i -lt 120 -and (Test-Path $exe); $i++) { Start-Sleep -Milliseconds 500 }
  Assert (-not (Test-Path $exe)) "uninstall removes the program"
  Assert (-not (Test-Path $shortcut) -and -not (Test-Path $quitShortcut)) "uninstall removes the Start menu shortcuts"
  Assert ((Test-Path $database) -and (Test-Path $log)) "uninstall keeps the workspace and its log"
  Notice "Uninstall while running: OfficeFlow stopped cleanly first; program and shortcuts removed; workspace kept at $database"
  Write-Output "Installer test passed."
}
catch {
  Write-Output "::error title=Installer test failed::$($_.Exception.Message -replace "`r?`n", ' | ')"
  throw
}
finally {
  Remove-Item Env:OFFICEFLOW_TEST_OUTPUT -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name = 'OfficeFlow.exe'" | ForEach-Object { taskkill /PID $_.ProcessId /T /F 2>$null | Out-Null }
}
