# Tests the OfficeFlow installer on a disposable Windows machine (CI runner): install, Start menu
# launch, first start, saving an inventory item, a clean Ctrl+C stop, restart, an upgrade to a
# newer build (blocked while OfficeFlow runs), and uninstall keeping the workspace.
# The runner's own per-user folders are used, as a real installation would.
param(
  [Parameter(Mandatory = $true)][string]$Installer,
  [Parameter(Mandatory = $true)][string]$UpgradeInstaller
)
$ErrorActionPreference = "Stop"
$base = "http://127.0.0.1:8080"
$password = "Installer test password 3"
$helper = Join-Path $PSScriptRoot "windows_console_helper.ps1"
$appId = "{694B07A4-E3EF-4976-94E2-2A9FAB580EE2}_is1"
$installDir = Join-Path $env:LOCALAPPDATA "Programs\OfficeFlow"
$dataDir = Join-Path $env:LOCALAPPDATA "OfficeFlow"
$database = Join-Path $dataDir "officeflow.mv.db"
$log = Join-Path $dataDir "officeflow.log"
$shortcut = Join-Path ([Environment]::GetFolderPath("Programs")) "OfficeFlow.lnk"
$work = Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }) "OfficeFlow installer test"
New-Item -ItemType Directory -Force $work | Out-Null

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
function Login { (Invoke-Api "/api/login" @{ id = "001"; password = $password }).token }
function Get-Supplies { @((Invoke-Api "/api/state" -Token (Login)).supplies | ForEach-Object { $_.name }) }
function Get-CleanStops { if (Test-Path $log) { @(Get-Content $log | Where-Object { $_ -match 'stopped cleanly; database closed' }).Count } else { 0 } }
function Get-DisplayVersion { (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appId" -ErrorAction SilentlyContinue).DisplayVersion }

function Invoke-Setup([string]$Path, [string]$Name) {
  $setupLog = Join-Path $work "$Name.log"
  $process = Start-Process -FilePath $Path -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/LOG=`"$setupLog`"" -Wait -PassThru
  return $process.ExitCode
}

# Opens the Start menu shortcut (a shell launch, like clicking it) and returns OfficeFlow.exe.
function Start-FromShortcut {
  Start-Process -FilePath $shortcut | Out-Null
  for ($i = 0; $i -lt 120; $i++) {
    $launcher = Get-CimInstance Win32_Process -Filter "Name = 'OfficeFlow.exe'" | Where-Object { $_.ExecutablePath -like "$installDir\*" } | Select-Object -First 1
    if ($launcher -and (Test-Ready)) { return $launcher }
    Start-Sleep -Milliseconds 500
  }
  throw "OfficeFlow did not start from the Start menu shortcut"
}

function Stop-WithCtrlC($Launcher) {
  $before = Get-CleanStops
  $java = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Launcher.ProcessId) AND Name = 'java.exe'" | Select-Object -First 1
  $out = Join-Path $work "helper.txt"
  Start-Process powershell.exe -WindowStyle Hidden -Wait -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", "`"$helper`"", "-Action", "ctrlc", "-TargetPid", $Launcher.ProcessId, "-OutFile", "`"$out`"" | Out-Null
  $result = Get-Content -Raw $out; Remove-Item $out
  if ($result.StartsWith("ERROR")) { throw "Ctrl+C helper: $result" }
  for ($i = 0; $i -lt 60 -and (Get-Process -Id $Launcher.ProcessId -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
  Assert (-not (Get-Process -Id $Launcher.ProcessId -ErrorAction SilentlyContinue)) "OfficeFlow.exe exits after Ctrl+C"
  if ($java) { Assert (-not (Get-Process -Id $java.ProcessId -ErrorAction SilentlyContinue)) "java.exe exits after Ctrl+C" }
  for ($i = 0; $i -lt 20 -and -not (Test-PortFree); $i++) { Start-Sleep -Milliseconds 500 }
  Assert (Test-PortFree) "port 8080 is released"
  Assert ((Get-CleanStops) -eq $before + 1) "officeflow.log records a clean stop"
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
  foreach ($file in "OfficeFlow.exe", "runtime\bin\java.exe", "app\officeflow.jar", "app\site\index.html", "TERMS.txt", "Quick Start.txt", "unins000.exe") {
    Assert (Test-Path (Join-Path $installDir $file)) "installed $file"
  }
  Assert (Test-Path $shortcut) "the Start menu shortcut exists"
  $target = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut).TargetPath
  Assert ($target -eq (Join-Path $installDir "OfficeFlow.exe")) "the shortcut opens OfficeFlow.exe ($target)"
  Assert ((Get-DisplayVersion) -eq "1.0.0") "Apps & features lists OfficeFlow 1.0.0"
  Notice "Installed per user to $installDir without administrator rights; Start menu shortcut -> $target; listed as OfficeFlow $(Get-DisplayVersion)"

  # First launch from the Start menu, save an inventory item, stop with Ctrl+C.
  $env:OFFICEFLOW_ADMIN_PASSWORD = $password
  $env:OFFICEFLOW_NO_BROWSER = "1"
  $launcher = Start-FromShortcut
  Remove-Item Env:OFFICEFLOW_ADMIN_PASSWORD
  Assert (Test-Path $database) "the workspace is created at $database"
  Assert (-not (Test-Path (Join-Path $installDir "officeflow.mv.db"))) "no data inside the install folder"
  Invoke-Api "/api/command" @{ action = "saveSupply"; data = @{
      name = "Installer check paper"; category = "Paper & print"; quantity = "8"; threshold = "2"; unit = "reams" } } (Login) | Out-Null
  Assert ((Get-Supplies) -contains "Installer check paper") "the inventory item is saved"
  Stop-WithCtrlC $launcher
  Notice "First launch from the Start menu: workspace created at $database (outside the install folder), inventory item saved; Ctrl+C stopped OfficeFlow cleanly"

  # Restart from the Start menu.
  $launcher = Start-FromShortcut
  Assert ((Get-Supplies) -contains "Installer check paper") "the item survives a restart"

  # Upgrade while running is refused, so files are never replaced under a running OfficeFlow.
  $code = Invoke-Setup $UpgradeInstaller "upgrade-while-running"
  Assert ($code -ne 0) "setup refuses to upgrade while OfficeFlow runs (exit code $code)"
  Assert ((Get-DisplayVersion) -eq "1.0.0") "the installed version is unchanged after the refused upgrade"
  Assert ((Get-Supplies) -contains "Installer check paper") "OfficeFlow keeps running after the refused upgrade"
  Stop-WithCtrlC $launcher
  Notice "Restart from the Start menu: item still there. Upgrade while running was refused (setup exit code $code); clean stop"

  # Upgrade with OfficeFlow stopped.
  $hashBefore = (Get-FileHash $database).Hash
  $code = Invoke-Setup $UpgradeInstaller "upgrade"
  Assert ($code -eq 0) "the upgrade exits with code 0 (got $code)"
  Assert ((Get-DisplayVersion) -eq "1.0.1") "Apps & features lists the upgraded version 1.0.1"
  Assert ((Get-FileHash $database).Hash -eq $hashBefore) "the upgrade leaves the workspace file unchanged"
  $launcher = Start-FromShortcut
  Assert ((Get-Supplies) -contains "Installer check paper") "the item survives the upgrade"
  Stop-WithCtrlC $launcher
  Notice "Upgrade to 1.0.1 with OfficeFlow stopped: exit code 0, workspace file byte-for-byte unchanged, item still there after launching from the Start menu"

  # Uninstall keeps the workspace.
  $uninstaller = Join-Path $installDir "unins000.exe"
  Start-Process -FilePath $uninstaller -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait | Out-Null
  for ($i = 0; $i -lt 120 -and (Test-Path (Join-Path $installDir "OfficeFlow.exe")); $i++) { Start-Sleep -Milliseconds 500 }
  Assert (-not (Test-Path (Join-Path $installDir "OfficeFlow.exe"))) "uninstall removes the program"
  Assert (-not (Test-Path $shortcut)) "uninstall removes the Start menu shortcut"
  Assert ((Test-Path $database) -and (Test-Path $log)) "uninstall keeps the workspace and its log"
  Notice "Uninstall removed the program and shortcut and kept the workspace at $database"
  Write-Output "Installer test passed."
}
catch {
  Write-Output "::error title=Installer test failed::$($_.Exception.Message -replace "`r?`n", ' | ')"
  throw
}
finally {
  Get-CimInstance Win32_Process -Filter "Name = 'OfficeFlow.exe'" | ForEach-Object { taskkill /PID $_.ProcessId /T /F 2>$null | Out-Null }
}
