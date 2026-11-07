# Launcher behaviour in a real console window, with a disposable workspace (CI runner):
#  - the first-run password typed as key presses is not shown on screen;
#  - the browser opens only after the server answers;
#  - Ctrl+C and closing the window both stop OfficeFlow cleanly: java.exe exits, port 8080 is
#    released, officeflow.log records "stopped cleanly; database closed", and the data is still
#    there after a restart. OfficeFlow is never force-killed here.
param([Parameter(Mandatory = $true)][string]$Zip)
$ErrorActionPreference = "Stop"
$temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$work = Join-Path $temp "OfficeFlow console test"
$base = "http://127.0.0.1:8080"
$password = "Console masked password 9"
$helper = Join-Path $PSScriptRoot "windows_console_helper.ps1"
$launched = @()

function Notice([string]$Message) { Write-Output "::notice title=Launcher console test::$Message" }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "Check failed: $Message" } }

function Invoke-Api([string]$Path, $Body = $null, [string]$Token = "", [int]$Expected = 200) {
  $parameters = @{ Uri = "$base$Path"; Method = "Get"; SkipHttpErrorCheck = $true; StatusCodeVariable = "status" }
  if ($Token) { $parameters.Headers = @{ Authorization = "Bearer $Token" } }
  if ($null -ne $Body) {
    $parameters.Method = "Post"; $parameters.ContentType = "application/json"
    $parameters.Body = $Body | ConvertTo-Json -Depth 5
  }
  $result = Invoke-RestMethod @parameters
  if ($status -ne $Expected) { throw "$Path returned $status, expected ${Expected}" }
  return $result
}
function Test-Ready { try { (Invoke-RestMethod "$base/api/health" -TimeoutSec 2).service -eq "officeflow" } catch { $false } }
function Wait-Ready { for ($i = 0; $i -lt 120; $i++) { if (Test-Ready) { return } ; Start-Sleep -Milliseconds 500 }; throw "OfficeFlow did not answer" }
function Test-PortFree { -not (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue) }
function Login { (Invoke-Api "/api/login" @{ id = "001"; password = $password }).token }
function Get-Supplies { @((Invoke-Api "/api/state" -Token (Login)).supplies | ForEach-Object { $_.name }) }
function Add-Supply([string]$Name) {
  Invoke-Api "/api/command" @{ action = "saveSupply"; data = @{
      name = $Name; category = "Stationery"; quantity = "3"; threshold = "1"; unit = "boxes" } } (Login) | Out-Null
}
function Get-Java([int]$Launcher) {
  Get-CimInstance Win32_Process -Filter "ParentProcessId = $Launcher AND Name = 'java.exe'" | Select-Object -First 1
}
function Get-BrowserWithUrl {
  @(Get-CimInstance Win32_Process | Where-Object {
      $_.CommandLine -match '127\.0\.0\.1:8080' -and $_.Name -notin "OfficeFlow.exe", "java.exe", "pwsh.exe", "powershell.exe" })
}

# Drives the launcher's console window through the helper, in a separate hidden process.
function Invoke-Console([string]$Action, [int]$Target, [string]$Text = "") {
  $out = Join-Path $work "helper-$([guid]::NewGuid()).txt"
  $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$helper`"", "-Action", $Action,
                 "-TargetPid", $Target, "-OutFile", "`"$out`"")
  if ($Text) {
    $textFile = Join-Path $work "helper-text.txt"
    [IO.File]::WriteAllText($textFile, $Text)
    $arguments += @("-TextFile", "`"$textFile`"")
  }
  Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -Wait | Out-Null
  if ($Text) { Remove-Item (Join-Path $work "helper-text.txt") }
  $result = Get-Content -Raw $out
  Remove-Item $out
  if ($result.StartsWith("ERROR")) { throw "Console helper ($Action): $result" }
  return $result
}
function Wait-Screen([int]$Target, [string]$Expected) {
  for ($i = 0; $i -lt 60; $i++) {
    $screen = Invoke-Console "read" $Target
    if ($screen.Contains($Expected)) { return $screen }
    Start-Sleep -Milliseconds 500
  }
  throw "The launcher window never showed '$Expected'. Screen:`n$screen"
}

function Start-Launcher([string]$Folder) {
  $process = Start-Process -FilePath (Join-Path $Folder "OfficeFlow.exe") -WorkingDirectory $env:SystemRoot -PassThru
  $script:launched += $process
  return $process
}

# Waits for a clean stop: launcher and java.exe gone, port free, and a new clean-stop log line.
function Assert-CleanStop($Launcher, [int]$JavaPid, [int]$CleanStopsBefore, [string]$How) {
  Assert ($Launcher.WaitForExit(60000)) "OfficeFlow.exe exits after $How"
  for ($i = 0; $i -lt 60 -and (Get-Process -Id $JavaPid -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
  Assert (-not (Get-Process -Id $JavaPid -ErrorAction SilentlyContinue)) "java.exe exits after $How"
  for ($i = 0; $i -lt 20 -and -not (Test-PortFree); $i++) { Start-Sleep -Milliseconds 500 }
  Assert (Test-PortFree) "port 8080 is released after $How"
  $lines = @(Get-Content $log)
  $cleanStops = @($lines | Where-Object { $_ -match 'stopped cleanly; database closed' }).Count
  Assert ($cleanStops -eq $CleanStopsBefore + 1) "officeflow.log records a clean stop after $How (last line: $($lines[-1]))"
  return $lines[-1]
}
function Get-CleanStops { if (Test-Path $log) { @(Get-Content $log | Where-Object { $_ -match 'stopped cleanly; database closed' }).Count } else { 0 } }

Get-ChildItem Env: | Where-Object { $_.Name -in "OFFICEFLOW_ADMIN_PASSWORD", "OFFICEFLOW_NO_BROWSER" } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
$env:LOCALAPPDATA = Join-Path $work "LocalAppData"
New-Item -ItemType Directory -Force $env:LOCALAPPDATA | Out-Null
$log = Join-Path $env:LOCALAPPDATA "OfficeFlow\officeflow.log"

try {
  $name = [IO.Path]::GetFileNameWithoutExtension($Zip)
  Expand-Archive -LiteralPath $Zip -DestinationPath (Join-Path $work "Console copy")
  $folder = Join-Path (Join-Path $work "Console copy") $name

  # 1. First run in a real console: type the password as key presses; it must not be shown.
  $launcher = Start-Launcher $folder
  Wait-Screen $launcher.Id "New admin password:" | Out-Null
  Assert (Test-PortFree) "OfficeFlow is not running before the password is set"
  Assert ((Get-BrowserWithUrl).Count -eq 0) "no browser opens before the server is ready"
  Invoke-Console "type" $launcher.Id "$password`n" | Out-Null
  Wait-Screen $launcher.Id "Type it again:" | Out-Null
  Invoke-Console "type" $launcher.Id "$password`n" | Out-Null
  $screen = Wait-Screen $launcher.Id "Starting OfficeFlow"
  Assert (-not $screen.Contains($password)) "the typed password is not shown in the console window"
  Wait-Ready
  $readyAt = Get-Date
  Notice "Real console: the password typed as key presses did not appear on screen (prompts shown: 'New admin password:', 'Type it again:')"

  # 2. The browser opens on its own once the server answers.
  $browser = @()
  for ($i = 0; $i -lt 60 -and $browser.Count -eq 0; $i++) { Start-Sleep -Milliseconds 500; $browser = Get-BrowserWithUrl }
  if ($browser.Count) {
    $first = $browser | Sort-Object CreationDate | Select-Object -First 1
    Notice "VERIFIED: the browser opened after the server answered ($($first.Name), started $([int]($first.CreationDate - $readyAt).TotalSeconds) s after this test saw the server ready): $($first.CommandLine)"
  } else {
    $openWith = Get-Process OpenWith -ErrorAction SilentlyContinue
    Notice "NOT VERIFIED: no browser process with http://127.0.0.1:8080 appeared within 30 s$(if ($openWith) { ' (Windows showed the Open With dialog: no default browser on this runner)' })"
  }

  # 3. Ctrl+C in the launcher window.
  Add-Supply "Console check one"
  $java = Get-Java $launcher.Id
  Assert ($null -ne $java) "java.exe runs under OfficeFlow.exe"
  $before = Get-CleanStops
  $screen = Invoke-Console "ctrlc" $launcher.Id
  $line = Assert-CleanStop $launcher $java.ProcessId $before "Ctrl+C"
  Assert ($launcher.ExitCode -eq 0) "OfficeFlow.exe exits with code 0 after Ctrl+C (got $($launcher.ExitCode))"
  Assert ($screen.Contains("OfficeFlow stopped cleanly; the database is closed.")) "the window reports the clean stop"
  Assert ($screen.Contains("OfficeFlow has stopped.")) "the launcher reports that OfficeFlow stopped"
  Notice "Ctrl+C: OfficeFlow.exe exited with code 0, java.exe exited, port 8080 released; window showed 'OfficeFlow stopped cleanly; the database is closed.'; log: $line"

  # 4. Restart, check the data, then close the launcher window.
  $launcher = Start-Launcher $folder
  Wait-Ready
  Assert ((Get-Supplies) -contains "Console check one") "the supply saved before Ctrl+C is there after restart"
  Add-Supply "Console check two"
  $java = Get-Java $launcher.Id
  $before = Get-CleanStops
  Invoke-Console "close" $launcher.Id | Out-Null
  $line = Assert-CleanStop $launcher $java.ProcessId $before "closing the window"
  Notice "Closing the window: OfficeFlow.exe exited (code $($launcher.ExitCode)), java.exe exited, port 8080 released; log: $line"

  # 5. Restart again: both records are there. Stop with Ctrl+C.
  $launcher = Start-Launcher $folder
  Wait-Ready
  $supplies = Get-Supplies
  Assert ($supplies -contains "Console check one" -and $supplies -contains "Console check two") "both supplies are there after restart"
  $java = Get-Java $launcher.Id
  $before = Get-CleanStops
  Invoke-Console "ctrlc" $launcher.Id | Out-Null
  Assert-CleanStop $launcher $java.ProcessId $before "the final Ctrl+C" | Out-Null
  Notice "After closing the window and restarting, both test supplies were still there; final Ctrl+C stopped cleanly. officeflow.log: $(@(Get-Content $log) -join ' | ')"
  Write-Output "Launcher console test passed."
}
finally {
  # Cleanup only. A test that reaches this with OfficeFlow still running has already failed.
  foreach ($process in $launched) {
    if (-not $process.HasExited) { taskkill /PID $process.Id /T /F 2>$null | Out-Null }
  }
  Get-BrowserWithUrl | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
}
