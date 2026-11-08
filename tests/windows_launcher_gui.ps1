# OfficeFlow.exe as a windowless app, with a disposable workspace (CI runner):
#  - OfficeFlow.exe is a GUI-subsystem program with the OfficeFlow icon and version details, so
#    Windows opens no console for it; while it starts, no visible window appears for it, its
#    java.exe or any console host under them (sampled every 50 ms);
#  - the first start opens the browser on the setup screen with a one-time token, which works
#    once and appears on no command line or log; a second launch only opens the browser;
#  - "OfficeFlow.exe --quit" and the browser's Quit button (POST /api/quit) both stop OfficeFlow
#    cleanly: OfficeFlow.exe and java.exe exit with code 0, port 8080 is released, and
#    officeflow.log records "stopped cleanly; database closed". Nothing is force-killed here;
#  - a returning start opens sign-in, and the data is still there;
#  - when port 8080 is taken, OfficeFlow.exe reports a readable error instead of starting.
# OFFICEFLOW_TEST_OUTPUT makes OfficeFlow.exe write the browser address and its messages to
# files instead of opening a browser or a message box.
param([Parameter(Mandatory = $true)][string]$Zip)
$ErrorActionPreference = "Stop"
$temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$work = Join-Path $temp "OfficeFlow launcher test"
$base = "http://127.0.0.1:8080"
$password = "Windowless setup password 4"
$launched = @()

function Notice([string]$Message) { Write-Output "::notice title=Windowless launcher test::$Message" }
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
function Get-Lines([string]$Name) { $file = Join-Path $output $Name; @(if (Test-Path $file) { Get-Content $file }) }
function Wait-Lines([string]$Name, [int]$Count) {
  # @() keeps a single line as a one-item array, so [-1] is the last line, not its last character.
  for ($i = 0; $i -lt 120; $i++) { $lines = @(Get-Lines $Name); if ($lines.Count -ge $Count) { return $lines[-1] }; Start-Sleep -Milliseconds 250 }
  throw "OfficeFlow.exe wrote no line $Count to $Name"
}
function Get-Tree([int]$Parent) {
  $all = @(Get-CimInstance Win32_Process); $found = @(); $queue = @($Parent)
  while ($queue.Count) { $current, $queue = $queue; foreach ($child in $all | Where-Object { $_.ParentProcessId -eq $current }) { $found += $child; $queue += [int]$child.ProcessId } }
  return $found
}

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class LauncherProbe {
  delegate bool EnumProc(IntPtr window, IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadLibraryEx(string file, IntPtr reserved, uint flags);
  delegate bool EnumNameProc(IntPtr module, IntPtr type, IntPtr name, IntPtr data);
  [DllImport("kernel32.dll")] static extern bool EnumResourceNames(IntPtr module, IntPtr type, EnumNameProc callback, IntPtr data);
  [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
  // Process IDs that own a visible top-level window.
  public static HashSet<uint> VisibleWindowOwners() {
    var owners = new HashSet<uint>();
    EnumWindows((window, data) => { if (IsWindowVisible(window)) { uint id; GetWindowThreadProcessId(window, out id); owners.Add(id); } return true; }, IntPtr.Zero);
    return owners;
  }
  // Number of icon groups (RT_GROUP_ICON = 14) in the file itself.
  public static int IconGroups(string file) {
    IntPtr module = LoadLibraryEx(file, IntPtr.Zero, 0x2); // LOAD_LIBRARY_AS_DATAFILE
    if (module == IntPtr.Zero) return 0;
    int count = 0;
    try { EnumResourceNames(module, (IntPtr)14, (m, t, n, d) => { count++; return true; }, IntPtr.Zero); }
    finally { FreeLibrary(module); }
    return count;
  }
}
"@

# Starts OfficeFlow.exe as a shell launch (like the Start menu) and watches for visible windows
# from it and its children until the server answers.
function Start-Launcher([string]$Folder) {
  $process = Start-Process -FilePath (Join-Path $Folder "OfficeFlow.exe") -WorkingDirectory $env:SystemRoot -PassThru
  $script:launched += $process
  # Samples from the moment of launch for at least 5 seconds and until port 8080 accepts
  # connections, using a fast TCP probe so the first sample is taken at once.
  $samples = 0; $seen = @(); $clock = [Diagnostics.Stopwatch]::StartNew(); $listening = $false
  while ($clock.Elapsed.TotalSeconds -lt 90 -and ($clock.Elapsed.TotalSeconds -lt 5 -or -not $listening)) {
    $owners = [LauncherProbe]::VisibleWindowOwners()
    $ids = @($process.Id) + @(Get-Tree $process.Id | ForEach-Object { [int]$_.ProcessId })
    foreach ($id in $ids) { if ($owners.Contains([uint32]$id)) { $seen += (Get-Process -Id $id -ErrorAction SilentlyContinue).ProcessName } }
    $samples++
    if (-not $listening) {
      $probe = [Net.Sockets.TcpClient]::new()
      try { $listening = $probe.ConnectAsync("127.0.0.1", 8080).Wait(100) -and $probe.Connected } catch { } finally { $probe.Dispose() }
    }
    Start-Sleep -Milliseconds 50
  }
  for ($i = 0; $i -lt 120 -and -not (Test-Ready); $i++) { Start-Sleep -Milliseconds 250 }
  Assert ($samples -ge 10) "the window check sampled the start ($samples samples)"
  Assert (Test-Ready) "OfficeFlow answers after a shell launch"
  Assert ($seen.Count -eq 0) "no visible window from OfficeFlow.exe, java.exe or a console host while starting (seen: $($seen -join ', '))"
  return [pscustomobject]@{ Process = $process; Samples = $samples }
}

function Assert-CleanStop($Process, [int]$JavaPid, [int]$Before, [string]$How) {
  Assert ($Process.WaitForExit(30000)) "OfficeFlow.exe exits after $How"
  Assert ($Process.ExitCode -eq 0) "OfficeFlow.exe exits with code 0 after $How (got $($Process.ExitCode))"
  for ($i = 0; $i -lt 60 -and (Get-Process -Id $JavaPid -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
  Assert (-not (Get-Process -Id $JavaPid -ErrorAction SilentlyContinue)) "java.exe exits after $How"
  for ($i = 0; $i -lt 40 -and -not (Test-PortFree); $i++) { Start-Sleep -Milliseconds 250 }
  Assert (Test-PortFree) "port 8080 is released after $How"
  Assert ((Get-CleanStops) -eq $Before + 1) "officeflow.log records a clean stop after $How"
  return (Get-Content $log)[-1]
}

Get-ChildItem Env: | Where-Object { $_.Name -in "OFFICEFLOW_ADMIN_PASSWORD", "OFFICEFLOW_NO_BROWSER" } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
$env:LOCALAPPDATA = Join-Path $work "LocalAppData"
$output = Join-Path $work "Launcher output"
New-Item -ItemType Directory -Force $env:LOCALAPPDATA, $output | Out-Null
$env:OFFICEFLOW_TEST_OUTPUT = $output
$log = Join-Path $env:LOCALAPPDATA "OfficeFlow\officeflow.log"

try {
  $name = [IO.Path]::GetFileNameWithoutExtension($Zip)
  Expand-Archive -LiteralPath $Zip -DestinationPath (Join-Path $work "Copy")
  $folder = Join-Path (Join-Path $work "Copy") $name
  $exe = Join-Path $folder "OfficeFlow.exe"

  # 1. A GUI program with the OfficeFlow icon and version details.
  $bytes = [IO.File]::ReadAllBytes($exe)
  $pe = [BitConverter]::ToInt32($bytes, 0x3C)
  $subsystem = [BitConverter]::ToUInt16($bytes, $pe + 24 + 68)
  Assert ($subsystem -eq 2) "OfficeFlow.exe uses the Windows GUI subsystem, so no console opens (subsystem $subsystem)"
  Assert ([LauncherProbe]::IconGroups($exe) -ge 1) "OfficeFlow.exe contains the OfficeFlow icon"
  $info = (Get-Item $exe).VersionInfo
  Assert ($info.ProductName -eq "OfficeFlow" -and $info.FileDescription -eq "OfficeFlow") "OfficeFlow.exe carries its product name ($($info.ProductName))"
  Notice "OfficeFlow.exe: GUI subsystem (no console), icon resource present, version $($info.ProductVersion) '$($info.FileDescription)'"

  # 2. First start: no visible window, the browser opens on the setup screen.
  $start = Start-Launcher $folder
  $launcher = $start.Process
  $opened = Wait-Lines "opened-url.txt" 1
  Assert ($opened -match '^http://127\.0\.0\.1:8080/#setup=([A-Za-z0-9_-]{32,128})$') "the first start opens the setup screen ($opened)"
  $token = $Matches[1]
  $tree = @(Get-Tree $launcher.Id)
  $names = @($tree | ForEach-Object { $_.Name.ToLowerInvariant() } | Sort-Object -Unique)
  Assert ($names -contains "java.exe") "OfficeFlow.exe runs the bundled java.exe"
  Assert (-not ($names | Where-Object { $_ -in "cmd.exe", "powershell.exe", "pwsh.exe" })) "no cmd.exe or PowerShell ($($names -join ', '))"
  $java = $tree | Where-Object Name -eq "java.exe" | Select-Object -First 1
  foreach ($line in @($java.CommandLine, (Get-CimInstance Win32_Process -Filter "ProcessId = $($launcher.Id)").CommandLine)) {
    Assert (-not ([string]$line).Contains($token)) "the setup token is on no command line"
  }
  Assert ((Invoke-Api "/api/setup").status -eq "ready") "setup waits for the administrator password"
  Invoke-Api "/api/login" @{ id = "001"; password = $password } -Expected 403 | Out-Null
  Invoke-Api "/api/setup" @{ token = $token; password = $password; confirmPassword = $password } | Out-Null
  Invoke-Api "/api/setup" @{ token = $token; password = "Another password 12" } -Expected 409 | Out-Null
  Invoke-Api "/api/command" @{ action = "saveSupply"; data = @{
      name = "Windowless check folders"; category = "Stationery"; quantity = "6"; threshold = "2"; unit = "packs" } } (Login) | Out-Null
  Notice "First start: $($start.Samples) samples (every ~50 ms from launch until the server listened, at least 5 s) showed no visible window from OfficeFlow.exe, java.exe or a console host; browser opened the setup screen; admin created once (a second setup was refused with 409); item saved; process tree: $($names -join ', ')"

  # 3. A second launch while OfficeFlow runs only opens the browser.
  $again = Start-Process -FilePath $exe -WorkingDirectory $env:SystemRoot -PassThru
  Assert ($again.WaitForExit(20000)) "a second OfficeFlow.exe exits by itself"
  Assert ($again.ExitCode -eq 0) "the second launch exits with code 0"
  Assert ((Wait-Lines "opened-url.txt" 2) -eq "$base/") "the second launch opens OfficeFlow's address without a setup link"
  Assert (-not $launcher.HasExited) "the first OfficeFlow keeps running"

  # 4. Quit with the Start menu's "Quit OfficeFlow" (OfficeFlow.exe --quit).
  $before = Get-CleanStops
  $quit = Start-Process -FilePath $exe -ArgumentList "--quit" -WorkingDirectory $env:SystemRoot -Wait -PassThru
  Assert ($quit.ExitCode -eq 0) "OfficeFlow.exe --quit exits with code 0"
  $line = Assert-CleanStop $launcher $java.ProcessId $before "OfficeFlow.exe --quit"
  Assert ((Wait-Lines "notice.txt" 1) -eq "OfficeFlow has stopped. Your workspace is saved.") "--quit confirms the stop"
  $launcherLog = Get-Content -Raw (Join-Path $env:LOCALAPPDATA "OfficeFlow\launcher.log")
  Assert (-not $launcherLog.Contains($token) -and -not $launcherLog.Contains($password)) "neither the token nor the password is in launcher.log"
  Notice "Quit OfficeFlow (--quit): OfficeFlow.exe and java.exe exited with code 0, port 8080 released; log: $line"

  # 5. Returning start: sign-in, data kept. Quit with the browser's Quit button.
  $launcher = (Start-Launcher $folder).Process
  Assert ((Wait-Lines "opened-url.txt" 3) -eq "$base/") "a returning start opens sign-in, not setup"
  Assert ((Invoke-Api "/api/setup").status -eq "done") "setup stays closed"
  Assert ((Get-Supplies) -contains "Windowless check folders") "the item is still there after quitting and reopening"
  $java = Get-Tree $launcher.Id | Where-Object Name -eq "java.exe" | Select-Object -First 1
  $before = Get-CleanStops
  Invoke-Api "/api/quit" @{} | Out-Null
  $line = Assert-CleanStop $launcher $java.ProcessId $before "the browser's Quit button"
  Notice "Reopened: sign-in (no setup link), item still there; the browser's Quit button stopped OfficeFlow cleanly; log: $line"

  # 6. A readable error when port 8080 is taken; nothing starts and the workspace is untouched.
  $hash = (Get-FileHash (Join-Path $env:LOCALAPPDATA "OfficeFlow\officeflow.mv.db")).Hash
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 8080)
  $listener.Start()
  try {
    $blocked = Start-Process -FilePath $exe -WorkingDirectory $env:SystemRoot -PassThru
    Assert ($blocked.WaitForExit(30000)) "OfficeFlow.exe ends when it cannot start"
    Assert ($blocked.ExitCode -eq 1) "OfficeFlow.exe reports the failure with exit code 1"
    $message = Wait-Lines "error.txt" 1
    Assert ($message -like "Another program is using port 8080*") "the error explains the problem ($message)"
  } finally { $listener.Stop() }
  Assert ((Get-FileHash (Join-Path $env:LOCALAPPDATA "OfficeFlow\officeflow.mv.db")).Hash -eq $hash) "the workspace file is unchanged"
  Notice "Port 8080 taken: OfficeFlow.exe exited with code 1 and showed: $message"
  Write-Output "Windowless launcher test passed."
}
catch {
  Write-Output "::error title=Windowless launcher test failed::$($_.Exception.Message -replace "`r?`n", ' | ')"
  throw
}
finally {
  # Cleanup only. A test that reaches this with OfficeFlow still running has already failed.
  foreach ($process in $launched) { if (-not $process.HasExited) { taskkill /PID $process.Id /T /F 2>$null | Out-Null } }
  Remove-Item Env:OFFICEFLOW_TEST_OUTPUT -ErrorAction SilentlyContinue
}
