# Tests the release ZIP on a disposable Windows machine (CI runner) the way a person uses it:
# extract into a folder with spaces, first run of OfficeFlow.exe through its browser setup
# screen (one-time token), add a supply, quit cleanly, restart through a shell launch (as a
# double-click does), replace the extracted
# folder, and open the same workspace from another copy. System Java and Maven are removed from
# PATH, and LOCALAPPDATA points to a disposable folder.
param([Parameter(Mandatory = $true)][string]$Zip)
$ErrorActionPreference = "Stop"
$temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$work = Join-Path $temp "OfficeFlow release test"
$base = "http://127.0.0.1:8080"
$adminPassword = "Release setup password 7"
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

# Every process started under the launcher, with its command line.
function Get-Descendants([int]$Parent) {
  $all = @(Get-CimInstance Win32_Process)
  $found = @(); $queue = @($Parent)
  while ($queue.Count) {
    $current, $queue = $queue
    foreach ($child in $all | Where-Object { $_.ParentProcessId -eq $current }) {
      $found += $child; $queue += [int]$child.ProcessId
    }
  }
  return $found
}

function Assert-ProcessTree($Process) {
  $tree = @(Get-Descendants $Process.Id)
  $names = @($tree | ForEach-Object { $_.Name.ToLowerInvariant() })
  Assert ($names -contains "java.exe") "the launcher starts the bundled java.exe"
  Assert (-not ($names | Where-Object { $_ -in "cmd.exe", "powershell.exe", "pwsh.exe" })) "the launcher starts no cmd.exe or PowerShell ($($names -join ', '))"
  $java = $tree | Where-Object Name -eq "java.exe" | Select-Object -First 1
  Assert ($java.CommandLine -like "*runtime\bin\java.exe*") "java.exe is the bundled runtime ($($java.CommandLine))"
  $launcher = Get-CimInstance Win32_Process -Filter "ProcessId = $($Process.Id)"
  foreach ($line in @($launcher.CommandLine) + @($tree | ForEach-Object CommandLine)) {
    Assert (-not ([string]$line).Contains($adminPassword)) "the admin password is on no command line"
  }
  return ($names | Sort-Object -Unique) -join ", "
}

# Double-click equivalent: a shell launch of OfficeFlow.exe from another working directory.
function Start-Package([string]$Folder) {
  $process = Start-Process -FilePath (Join-Path $Folder "OfficeFlow.exe") -WorkingDirectory $env:SystemRoot -PassThru
  $script:launched += $process
  Wait-Ready
  return $process
}

# Quits like the "Quit OfficeFlow" Start menu shortcut: OfficeFlow.exe --quit asks the running
# OfficeFlow to stop cleanly and waits for it.
function Stop-Package($Process) {
  $folder = Split-Path (Get-CimInstance Win32_Process -Filter "ProcessId = $($Process.Id)").ExecutablePath
  $quit = Start-Process -FilePath (Join-Path $folder "OfficeFlow.exe") -ArgumentList "--quit" -WorkingDirectory $env:SystemRoot -Wait -PassThru
  Assert ($quit.ExitCode -eq 0) "OfficeFlow.exe --quit exits with code 0 (got $($quit.ExitCode))"
  Assert ($Process.WaitForExit(30000)) "OfficeFlow.exe exits after quitting"
  Assert ($Process.ExitCode -eq 0) "OfficeFlow.exe reports a clean stop (exit code $($Process.ExitCode))"
  for ($i = 0; $i -lt 40; $i++) {
    try { Invoke-RestMethod "$base/api/health" -TimeoutSec 1 | Out-Null; Start-Sleep -Milliseconds 250 } catch { return }
  }
  throw "OfficeFlow still answers after quitting"
}

# The address OfficeFlow.exe opened most recently, once it has opened $Count addresses in all.
function Wait-Opened([int]$Count) {
  $file = Join-Path $output "opened-url.txt"
  for ($i = 0; $i -lt 80; $i++) {
    $lines = @(if (Test-Path $file) { Get-Content $file })
    if ($lines.Count -ge $Count) { return $lines[-1] }
    Start-Sleep -Milliseconds 250
  }
  throw "OfficeFlow.exe did not open the browser (address $Count)"
}

function Get-Supplies([string]$Token) { @((Invoke-Api "/api/state" -Token $Token).supplies | ForEach-Object { $_.name }) }
function Login { (Invoke-Api "/api/login" @{ id = "001"; password = $adminPassword }).token }

# Prerequisites present on this machine, then hide system Java and Maven from the launcher.
$os = Get-CimInstance Win32_OperatingSystem
$systemJava = Get-Command java -ErrorAction SilentlyContinue
$runtimeDll = Get-Item (Join-Path $env:SystemRoot "System32\vcruntime140.dll") -ErrorAction SilentlyContinue
Notice ("Environment: $($os.Caption) $($os.Version) build $($os.BuildNumber); x64 Visual C++ runtime " +
  "$(if ($runtimeDll) { $runtimeDll.VersionInfo.FileVersion } else { 'absent' }); system Java on PATH before isolation: " +
  "$(if ($systemJava) { $systemJava.Source } else { 'none' })")
$env:PATH = ($env:PATH -split ";" | Where-Object { $_ -and $_ -notmatch '(?i)java|jdk|jre|maven|temurin|zulu|hostedtoolcache' }) -join ";"
Get-ChildItem Env: | Where-Object { $_.Name -match '^(JAVA_HOME|JDK_HOME|JRE_HOME|M2_HOME|MAVEN_HOME|OFFICEFLOW_ADMIN_PASSWORD)' } |
  ForEach-Object { Remove-Item "Env:$($_.Name)" }
Assert (-not (Get-Command java -ErrorAction SilentlyContinue)) "no java on PATH for the launcher"
Assert (-not (Get-Command mvn -ErrorAction SilentlyContinue)) "no Maven on PATH for the launcher"
$env:LOCALAPPDATA = Join-Path $work "LocalAppData"
# OfficeFlow.exe records the browser address and any message here instead of opening them.
$output = Join-Path $work "Launcher output"
New-Item -ItemType Directory -Force $output | Out-Null
$env:OFFICEFLOW_TEST_OUTPUT = $output
$database = Join-Path $env:LOCALAPPDATA "OfficeFlow\officeflow.mv.db"
New-Item -ItemType Directory -Force $env:LOCALAPPDATA | Out-Null

try {
  $name = [IO.Path]::GetFileNameWithoutExtension($Zip)
  $first = Join-Path $work "First copy"
  Expand-Archive -LiteralPath $Zip -DestinationPath $first
  $folder = Join-Path $first $name
  foreach ($file in "OfficeFlow.exe", "Quick Start.txt", "LICENSE.txt", "TERMS.txt", "THIRD-PARTY-NOTICES.txt",
                    "app\officeflow.jar", "app\site\index.html", "runtime\bin\java.exe",
                    "runtime\legal\java.base\LICENSE", "licenses\Apache-2.0.txt", "licenses\MPL-2.0.txt") {
    Assert (Test-Path -LiteralPath (Join-Path $folder $file)) "the ZIP contains $file"
  }
  $scripts = @(Get-ChildItem -Recurse -File -LiteralPath $folder | Where-Object { $_.Extension -in ".cmd", ".bat", ".ps1", ".vbs", ".lnk" })
  Assert ($scripts.Count -eq 0) "the ZIP contains no script launchers (found: $($scripts.Name -join ', '))"
  $terms = (Get-Content -Raw -LiteralPath (Join-Path $folder "TERMS.txt")) -replace "`r`n", "`n"
  $source = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "..\TERMS.md")) -replace "`r`n", "`n"
  Assert ($terms -eq $source) "TERMS.txt in the ZIP has the same text as TERMS.md"
  $microsoftFiles = @(Get-ChildItem -Recurse -File -LiteralPath $folder | Where-Object {
      $_.Name -match '^(vcruntime140|vcruntime140_1|msvcp140|ucrtbase)\.dll$|^api-ms-win-.*\.dll$' })
  Assert ($microsoftFiles.Count -eq 0) "the ZIP contains no Microsoft runtime DLLs (found: $($microsoftFiles.Name -join ', '))"
  $signatures = Get-ChildItem -Recurse -File -LiteralPath $folder | Where-Object { $_.Extension -in ".exe", ".dll" } |
    ForEach-Object { [pscustomobject]@{ File = $_.Name; Signature = Get-AuthenticodeSignature -LiteralPath $_.FullName } }
  $microsoftSigned = @($signatures | Where-Object { $_.Signature.SignerCertificate -and $_.Signature.SignerCertificate.Subject -match 'O=Microsoft Corporation' })
  Assert ($microsoftSigned.Count -eq 0) "the ZIP contains no Microsoft-signed binaries (found: $($microsoftSigned.File -join ', '))"
  $launcherSignature = ($signatures | Where-Object File -eq "OfficeFlow.exe").Signature
  $otherUnsigned = @($signatures | Where-Object { $_.File -ne "OfficeFlow.exe" -and $_.Signature.Status -ne "Valid" })
  Notice ("Extracted to '$folder' (path with spaces): OfficeFlow.exe present, no script launchers, no Microsoft runtime files; " +
    "OfficeFlow.exe signature: $($launcherSignature.Status); other EXE/DLL files not validly signed: $($otherUnsigned.Count)")

  # First run: OfficeFlow.exe opens the browser on the setup screen with a one-time token.
  $process = Start-Package $folder
  $tree = Assert-ProcessTree $process
  $opened = Wait-Opened 1
  Assert ($opened -match '^http://127\.0\.0\.1:8080/#setup=([A-Za-z0-9_-]{32,128})$') "the first run opens the setup screen ($opened)"
  $setupToken = $Matches[1]
  Assert ((Invoke-Api "/api/setup").status -eq "ready") "setup is waiting for the administrator password"
  Invoke-Api "/api/setup" @{ token = $setupToken; password = $adminPassword; confirmPassword = $adminPassword } | Out-Null
  Assert ((Invoke-Api "/api/setup").status -eq "done") "setup closes after the first administrator"
  Assert (Test-Path -LiteralPath $database) "the workspace is created at $database"
  Assert (-not (Test-Path -LiteralPath (Join-Path $folder "data"))) "nothing is stored in the extracted folder"
  $page = Invoke-WebRequest "$base/" -UseBasicParsing
  Assert ($page.Content.Contains('content="java"')) "the launcher serves the Java workspace"
  $admin = Login
  Invoke-Api "/api/command" @{ action = "saveSupply"; data = @{
      name = "Release check paper"; category = "Paper & print"; quantity = "12"; threshold = "2"; unit = "reams" } } $admin | Out-Null
  Assert ((Get-Supplies $admin) -contains "Release check paper") "the new supply is listed"
  Stop-Package $process
  $log = Get-Content -Raw (Join-Path $env:LOCALAPPDATA "OfficeFlow\launcher.log")
  Assert (-not $log.Contains($adminPassword) -and -not $log.Contains($setupToken)) "neither the password nor the setup token appears in launcher.log"
  Notice "First run: OfficeFlow.exe opened the setup screen with a one-time token, the admin password was set there, $database created, supply added, quit cleanly; password and token on no command line or log; process tree: $tree"

  # Restart through a shell launch, as a double-click does.
  $process = Start-Package $folder
  $tree = Assert-ProcessTree $process
  $admin = Login
  Assert ((Get-Supplies $admin) -contains "Release check paper") "the supply survives a restart"
  Invoke-Api "/api/login" @{ id = "001"; password = "wrong-password-123" } -Expected 403 | Out-Null
  Assert ((Wait-Opened 2) -eq "$base/") "a returning start opens sign-in, not setup"
  Notice "Restart via shell launch of OfficeFlow.exe: sign-in (no setup link), same admin password, supply still present; process tree: $tree"

  # A second launch while OfficeFlow runs reports it and exits on its own.
  $again = Start-Process -FilePath (Join-Path $folder "OfficeFlow.exe") -WorkingDirectory $env:SystemRoot -PassThru
  Assert ($again.WaitForExit(20000)) "a second OfficeFlow.exe exits by itself while OfficeFlow is running"
  Assert ($again.ExitCode -eq 0) "the second launch exits normally (exit code $($again.ExitCode))"
  Assert ((Get-Supplies $admin) -contains "Release check paper") "the running workspace is unaffected"
  Stop-Package $process
  Notice "Second launch while running: exited by itself with code 0; workspace unaffected"

  # Replace the extracted app folder: delete it, extract the ZIP again to the same place.
  Remove-Item -Recurse -Force -LiteralPath $first
  Expand-Archive -LiteralPath $Zip -DestinationPath $first
  $process = Start-Package $folder
  Assert ((Get-Supplies (Login)) -contains "Release check paper") "a freshly extracted folder opens the same workspace"
  Stop-Package $process
  # And a copy extracted somewhere else.
  $second = Join-Path $work "Replacement copy"
  Expand-Archive -LiteralPath $Zip -DestinationPath $second
  $process = Start-Package (Join-Path $second $name)
  Assert ((Get-Supplies (Login)) -contains "Release check paper") "a copy in another folder opens the same workspace"
  Stop-Package $process
  Notice "Replaced the extracted folder (deleted and extracted again) and started a copy in '$second': both opened $database with the supply"
  Write-Output "Windows ZIP test passed."
}
catch {
  Write-Output "::error title=Windows ZIP test failed::$($_.Exception.Message -replace "`r?`n", ' | ')"
  throw
}
finally {
  foreach ($process in $launched) {
    if (-not $process.HasExited) { taskkill /PID $process.Id /T /F 2>$null | Out-Null }
  }
}
