# Tests the release ZIP the way a person uses it, on a disposable Windows machine (CI runner):
# extract into a folder with spaces, double-click "Start OfficeFlow.cmd" (shell launch), first
# admin setup, add a supply, stop, restart, then open the same workspace from a replacement copy.
# System Java and Maven are removed from PATH, and LOCALAPPDATA points to a disposable folder.
param([Parameter(Mandatory = $true)][string]$Zip)
$ErrorActionPreference = "Stop"
$temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$work = Join-Path $temp "OfficeFlow release test"
$base = "http://127.0.0.1:8080"
$adminPassword = "release-admin-password"
$launched = @()

function Notice([string]$Message) { Write-Output "::notice title=Windows ZIP test::$Message" }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "Check failed: $Message" } }

function Invoke-Api([string]$Path, $Body = $null, [string]$Token = "", [int]$Expected = 200) {
  $parameters = @{ Uri = "$base$Path"; Method = "Get"; SkipHttpErrorCheck = $true; StatusCodeVariable = "status" }
  if ($Token) { $parameters.Headers = @{ Authorization = "Bearer $Token" } }
  if ($null -ne $Body) {
    $parameters.Method = "Post"; $parameters.ContentType = "application/json"
    $parameters.Body = $Body | ConvertTo-Json -Depth 5
  }
  $result = Invoke-RestMethod @parameters
  if ($status -ne $Expected) { throw "$Path returned $status, expected ${Expected}: $($result | ConvertTo-Json -Depth 5)" }
  return $result
}

function Wait-Ready {
  for ($i = 0; $i -lt 120; $i++) {
    try {
      if ((Invoke-RestMethod "$base/api/health" -TimeoutSec 2).service -eq "officeflow") { return }
    } catch { }
    Start-Sleep -Milliseconds 500
  }
  throw "OfficeFlow did not answer on $base"
}

# Double-click equivalent: a shell launch of the .cmd from another working directory.
function Start-Package([string]$Folder) {
  $launcher = Join-Path $Folder "Start OfficeFlow.cmd"
  $process = Start-Process -FilePath $launcher -WorkingDirectory $env:SystemRoot -PassThru
  $script:launched += $process
  Wait-Ready
  return $process
}

# Ctrl+C cannot be sent to a separate console here, so wait past H2's one-second write delay
# and end the launcher's process tree.
function Stop-Package($Process) {
  Start-Sleep -Seconds 3
  taskkill /PID $Process.Id /T /F | Out-Null
  $Process.WaitForExit()
  for ($i = 0; $i -lt 40; $i++) {
    try { Invoke-RestMethod "$base/api/health" -TimeoutSec 1 | Out-Null; Start-Sleep -Milliseconds 250 } catch { return }
  }
  throw "OfficeFlow still answers after stopping"
}

function Get-Supplies([string]$Token) { @((Invoke-Api "/api/state" -Token $Token).supplies | ForEach-Object { $_.name }) }

# Prerequisites present on this machine, then hide system Java and Maven from the launcher.
$os = Get-CimInstance Win32_OperatingSystem
$systemJava = Get-Command java -ErrorAction SilentlyContinue
Notice ("Environment: $($os.Caption) $($os.Version) build $($os.BuildNumber); Windows PowerShell " +
  "$((powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'))" +
  "; system Java on PATH before isolation: $(if ($systemJava) { $systemJava.Source } else { 'none' })")
$env:PATH = ($env:PATH -split ";" | Where-Object { $_ -and $_ -notmatch '(?i)java|jdk|jre|maven|temurin|zulu|hostedtoolcache' }) -join ";"
Get-ChildItem Env: | Where-Object { $_.Name -match '^(JAVA_HOME|JDK_HOME|JRE_HOME|M2_HOME|MAVEN_HOME)' } |
  ForEach-Object { Remove-Item "Env:$($_.Name)" }
Assert (-not (Get-Command java -ErrorAction SilentlyContinue)) "no java on PATH for the launcher"
Assert (-not (Get-Command mvn -ErrorAction SilentlyContinue)) "no Maven on PATH for the launcher"
$env:LOCALAPPDATA = Join-Path $work "LocalAppData"
$env:OFFICEFLOW_NO_BROWSER = "1"
$database = Join-Path $env:LOCALAPPDATA "OfficeFlow\officeflow.mv.db"
New-Item -ItemType Directory -Force $env:LOCALAPPDATA | Out-Null

try {
  $name = [IO.Path]::GetFileNameWithoutExtension($Zip)
  $first = Join-Path $work "First copy"
  Expand-Archive -LiteralPath $Zip -DestinationPath $first
  $folder = Join-Path $first $name
  foreach ($file in "Start OfficeFlow.cmd", "Quick Start.txt", "LICENSE.txt", "THIRD-PARTY-NOTICES.txt",
                    "app\officeflow.jar", "app\launch.ps1", "app\site\index.html",
                    "runtime\bin\java.exe", "runtime\legal\java.base\LICENSE",
                    "licenses\Apache-2.0.txt", "licenses\MPL-2.0.txt") {
    Assert (Test-Path -LiteralPath (Join-Path $folder $file)) "the ZIP contains $file"
  }
  Assert ((Get-Content -Raw -LiteralPath (Join-Path $folder "Start OfficeFlow.cmd")) -match "`r`n") "the launcher has CRLF line endings"
  $microsoftFiles = @(Get-ChildItem -Recurse -File -LiteralPath $folder | Where-Object {
      $_.Name -match '^(vcruntime140|vcruntime140_1|msvcp140|ucrtbase)\.dll$|^api-ms-win-.*\.dll$' })
  Assert ($microsoftFiles.Count -eq 0) "the ZIP contains no Microsoft runtime DLLs (found: $($microsoftFiles.Name -join ', '))"
  $microsoftSigned = @(Get-ChildItem -Recurse -File -LiteralPath $folder -Include *.dll, *.exe | Where-Object {
      $signature = Get-AuthenticodeSignature -LiteralPath $_.FullName
      $signature.SignerCertificate -and $signature.SignerCertificate.Subject -match 'O=Microsoft Corporation' })
  Assert ($microsoftSigned.Count -eq 0) "the ZIP contains no Microsoft-signed binaries (found: $($microsoftSigned.Name -join ', '))"
  $runtime = Get-Item (Join-Path $env:SystemRoot "System32\vcruntime140.dll") -ErrorAction SilentlyContinue
  Notice ("Extracted ZIP inspected: 0 Microsoft runtime DLLs, 0 Microsoft-signed binaries; system x64 Visual C++ runtime " +
    "$(if ($runtime) { $runtime.VersionInfo.FileVersion } else { 'absent' })")
  Notice "Extracted $name.zip to '$folder' (path with spaces); all expected files present"

  # First start: the launcher's own admin setup reads OFFICEFLOW_ADMIN_PASSWORD when it is set,
  # instead of the interactive prompt, which needs a keyboard.
  $env:OFFICEFLOW_ADMIN_PASSWORD = $adminPassword
  $process = Start-Package $folder
  Assert (Test-Path -LiteralPath $database) "the workspace is created at $database"
  Assert (-not (Test-Path -LiteralPath (Join-Path $folder "data"))) "nothing is stored in the extracted folder"
  $page = Invoke-WebRequest "$base/" -UseBasicParsing
  Assert ($page.Content.Contains('content="java"')) "the launcher serves the Java workspace"
  $admin = (Invoke-Api "/api/login" @{ id = "001"; password = $adminPassword }).token
  Invoke-Api "/api/command" @{ action = "saveSupply"; data = @{
      name = "Release check paper"; category = "Paper & print"; quantity = "12"; threshold = "2"; unit = "reams" } } $admin | Out-Null
  Assert ((Get-Supplies $admin) -contains "Release check paper") "the new supply is listed"
  Notice "First start via shell launch of 'Start OfficeFlow.cmd': admin 001 set up, workspace created at $database, supply added"
  Stop-Package $process
  Remove-Item Env:OFFICEFLOW_ADMIN_PASSWORD

  $process = Start-Package $folder
  $admin = (Invoke-Api "/api/login" @{ id = "001"; password = $adminPassword }).token
  Assert ((Get-Supplies $admin) -contains "Release check paper") "the supply survives a restart"
  Invoke-Api "/api/login" @{ id = "001"; password = "wrong-password-123" } -Expected 403 | Out-Null
  Notice "Restarted without OFFICEFLOW_ADMIN_PASSWORD: same admin password, supply still present"
  Stop-Package $process

  # A replacement ZIP extracted elsewhere opens the same workspace.
  $second = Join-Path $work "Replacement copy"
  Expand-Archive -LiteralPath $Zip -DestinationPath $second
  $process = Start-Package (Join-Path $second $name)
  $admin = (Invoke-Api "/api/login" @{ id = "001"; password = $adminPassword }).token
  Assert ((Get-Supplies $admin) -contains "Release check paper") "the replacement copy opens the same workspace"
  Notice "Replacement copy in '$second' opened the same workspace ($database) with the supply"

  # A second double-click while running reports that OfficeFlow is already running.
  $again = Start-Process -FilePath (Join-Path (Join-Path $second $name) "Start OfficeFlow.cmd") -WorkingDirectory $env:SystemRoot -PassThru
  Start-Sleep -Seconds 8
  Assert ((Get-Supplies $admin) -contains "Release check paper") "the running workspace is unaffected"
  taskkill /PID $again.Id /T /F 2>$null | Out-Null
  Stop-Package $process
  Write-Output "Windows ZIP test passed."
}
finally {
  foreach ($process in $launched) {
    if (-not $process.HasExited) { taskkill /PID $process.Id /T /F 2>$null | Out-Null }
  }
}
