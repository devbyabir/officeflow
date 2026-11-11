# Tests OfficeFlow-<version>.zip on Windows with an installed Java (CI runner), using a
# disposable workspace: extract into a folder with spaces, run `java -jar officeflow.jar`, add a
# record, stop with Ctrl+C (clean stop checked in officeflow.log), restart from another working
# directory, and open the same data from a replacement copy. OfficeFlow is never force-killed
# as proof of a clean stop.
param([Parameter(Mandatory = $true)][string]$Zip)
$ErrorActionPreference = "Stop"
$temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$work = Join-Path $temp "OfficeFlow ZIP test"
$base = "http://127.0.0.1:8080"
$password = "Release ZIP password 4"
$helper = Join-Path $PSScriptRoot "windows_console_helper.ps1"
$launched = @()

function Notice([string]$Message) { Write-Output "::notice title=Release ZIP test::$Message" }
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
function Wait-Ready { for ($i = 0; $i -lt 120; $i++) { if (Test-Ready) { return }; Start-Sleep -Milliseconds 500 }; throw "OfficeFlow did not answer" }
function Test-PortFree { -not (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue) }
function Login { (Invoke-Api "/api/login" @{ id = "001"; password = $password }).token }
function Get-Supplies { @((Invoke-Api "/api/state" -Token (Login)).supplies | ForEach-Object { $_.name }) }
function Get-CleanStops { if (Test-Path $log) { @(Get-Content $log | Where-Object { $_ -match 'stopped cleanly; database closed' }).Count } else { 0 } }

# `java -jar ...` in its own console window, as a person runs it in a terminal.
function Start-OfficeFlow([string]$Jar, [string]$WorkingDirectory) {
  $process = Start-Process -FilePath "java" -ArgumentList "-jar", "`"$Jar`"" -WorkingDirectory $WorkingDirectory -PassThru
  $script:launched += $process
  Wait-Ready
  return $process
}

# Presses Ctrl+C in that window through the test helper, then checks for a clean stop.
function Stop-WithCtrlC($Process) {
  $before = Get-CleanStops
  $out = Join-Path $work "helper.txt"
  Start-Process powershell.exe -WindowStyle Hidden -Wait -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", "`"$helper`"", "-Action", "ctrlc", "-TargetPid", $Process.Id, "-OutFile", "`"$out`"" | Out-Null
  $result = Get-Content -Raw $out
  Remove-Item $out
  if ($result.StartsWith("ERROR")) { throw "Ctrl+C helper: $result" }
  Assert ($Process.WaitForExit(60000)) "java.exe exits after Ctrl+C"
  for ($i = 0; $i -lt 20 -and -not (Test-PortFree); $i++) { Start-Sleep -Milliseconds 500 }
  Assert (Test-PortFree) "port 8080 is released after Ctrl+C"
  Assert ((Get-CleanStops) -eq $before + 1) "officeflow.log records a clean stop"
  Assert ($result.Contains("OfficeFlow stopped cleanly; the database is closed.")) "the window reports the clean stop"
}

Remove-Item Env:OFFICEFLOW_ADMIN_PASSWORD -ErrorAction SilentlyContinue
$env:LOCALAPPDATA = Join-Path $work "LocalAppData"
New-Item -ItemType Directory -Force $env:LOCALAPPDATA | Out-Null
$database = Join-Path $env:LOCALAPPDATA "OfficeFlow\officeflow.mv.db"
$log = Join-Path $env:LOCALAPPDATA "OfficeFlow\officeflow.log"
$os = Get-CimInstance Win32_OperatingSystem
$javaVersion = (& java -version 2>&1 | Select-Object -First 1)
$javaPath = (Get-Command java).Source

try {
  Notice "Environment: $($os.Caption) build $($os.BuildNumber); installed Java: $javaVersion ($javaPath); no Maven used"
  $name = [IO.Path]::GetFileNameWithoutExtension($Zip)
  $first = Join-Path $work "First copy"
  Expand-Archive -LiteralPath $Zip -DestinationPath $first
  $folder = Join-Path $first $name
  foreach ($file in "officeflow.jar", "site\index.html", "Quick Start.txt", "LICENSE.txt", "TERMS.txt",
                    "THIRD-PARTY-NOTICES.txt", "licenses\Apache-2.0.txt", "licenses\MPL-2.0.txt") {
    Assert (Test-Path -LiteralPath (Join-Path $folder $file)) "the ZIP contains $file"
  }
  $executables = @(Get-ChildItem -Recurse -File -LiteralPath $folder | Where-Object { $_.Extension -in ".exe", ".dll", ".cmd", ".bat", ".ps1", ".vbs", ".lnk", ".msi" })
  Assert ($executables.Count -eq 0) "the ZIP contains no executables or scripts (found: $($executables.Name -join ', '))"
  $jar = Join-Path $folder "officeflow.jar"

  # First start from the extracted folder, as the Quick Start says.
  $env:OFFICEFLOW_ADMIN_PASSWORD = $password
  $process = Start-OfficeFlow $jar $folder
  Remove-Item Env:OFFICEFLOW_ADMIN_PASSWORD
  Assert (Test-Path -LiteralPath $database) "the workspace is created at $database"
  Assert (-not (Test-Path -LiteralPath (Join-Path $folder "data"))) "nothing is stored in the extracted folder"
  Assert ((Invoke-WebRequest "$base/" -UseBasicParsing).Content.Contains('content="java"')) "the local app serves the Java workspace"
  Invoke-Api "/api/command" @{ action = "saveSupply"; data = @{
      name = "ZIP check paper"; category = "Paper & print"; quantity = "6"; threshold = "1"; unit = "reams" } } (Login) | Out-Null
  Stop-WithCtrlC $process
  Notice "First start with 'java -jar officeflow.jar' in '$folder': workspace created at $database, supply added; Ctrl+C stopped it cleanly (java.exe exited, port 8080 released, officeflow.log: stopped cleanly)"

  # Restart from another working directory: the web files are found next to the JAR.
  $process = Start-OfficeFlow $jar $env:SystemRoot
  Assert ((Get-Supplies) -contains "ZIP check paper") "the supply survives a restart"
  Invoke-Api "/api/login" @{ id = "001"; password = "wrong-password-123" } -Expected 403 | Out-Null
  Stop-WithCtrlC $process
  Notice "Restart (started from $env:SystemRoot with the JAR's full path): no password needed, supply still present; clean Ctrl+C stop"

  # A replacement copy extracted elsewhere opens the same workspace.
  $second = Join-Path $work "Replacement copy"
  Expand-Archive -LiteralPath $Zip -DestinationPath $second
  $process = Start-OfficeFlow (Join-Path (Join-Path $second $name) "officeflow.jar") (Join-Path $second $name)
  Assert ((Get-Supplies) -contains "ZIP check paper") "the replacement copy opens the same workspace"
  Stop-WithCtrlC $process
  Notice "Replacement copy in '$second' opened the same workspace with the supply; clean Ctrl+C stop. officeflow.log: $(@(Get-Content $log) -join ' | ')"
  Write-Output "Release ZIP test passed."
}
catch {
  Write-Output "::error title=Release ZIP test failed::$($_.Exception.Message -replace "`r?`n", ' | ')"
  throw
}
finally {
  foreach ($process in $launched) { if (-not $process.HasExited) { taskkill /PID $process.Id /T /F 2>$null | Out-Null } }
}
