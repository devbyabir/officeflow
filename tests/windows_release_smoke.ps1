# Tests the release ZIP on a disposable Windows machine (CI runner) the way a person uses it:
# extract into a folder with spaces, first run of OfficeFlow.exe through its password prompt,
# add a supply, restart through a shell launch (as a double-click does), replace the extracted
# folder, and open the same workspace from another copy. System Java and Maven are removed from
# PATH, and LOCALAPPDATA points to a disposable folder.
param([Parameter(Mandatory = $true)][string]$Zip)
$ErrorActionPreference = "Stop"
$temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$work = Join-Path $temp "OfficeFlow release test"
$base = "http://127.0.0.1:8080"
$adminPassword = "Release prompt password 7"
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

# Ctrl+C cannot be sent to another console here, so wait past H2's one-second write delay and
# end the launcher's process tree. People stop OfficeFlow with Ctrl+C or by closing the window.
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
$env:OFFICEFLOW_NO_BROWSER = "1"
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

  # First run through OfficeFlow.exe's own password prompt. The answers arrive on standard input,
  # like typing, never as an argument or environment variable.
  $answers = Join-Path $work "answers.txt"
  [IO.File]::WriteAllText($answers, "$adminPassword`r`n$adminPassword`r`n")
  $output = Join-Path $work "first-run.log"
  $process = Start-Process -FilePath (Join-Path $folder "OfficeFlow.exe") -WorkingDirectory $env:SystemRoot -NoNewWindow -PassThru `
    -RedirectStandardInput $answers -RedirectStandardOutput $output -RedirectStandardError "$output.err"
  $launched += $process
  Wait-Ready
  $tree = Assert-ProcessTree $process
  Assert (Test-Path -LiteralPath $database) "the workspace is created at $database"
  Assert (-not (Test-Path -LiteralPath (Join-Path $folder "data"))) "nothing is stored in the extracted folder"
  $page = Invoke-WebRequest "$base/" -UseBasicParsing
  Assert ($page.Content.Contains('content="java"')) "the launcher serves the Java workspace"
  $admin = Login
  Invoke-Api "/api/command" @{ action = "saveSupply"; data = @{
      name = "Release check paper"; category = "Paper & print"; quantity = "12"; threshold = "2"; unit = "reams" } } $admin | Out-Null
  Assert ((Get-Supplies $admin) -contains "Release check paper") "the new supply is listed"
  Stop-Package $process
  # OfficeFlow.exe held the answers file open as its standard input until it stopped.
  Remove-Item $answers
  $log = (Get-Content -Raw $output) + (Get-Content -Raw "$output.err")
  Assert ($log -match "Choose a password for the administrator account") "the first run asked for the admin password"
  Assert (-not $log.Contains($adminPassword)) "the admin password does not appear in the launcher's output"
  Notice "First run: OfficeFlow.exe asked for the admin password (typed via standard input), created $database, supply added; password on no command line and not in the output; process tree: $tree"

  # Restart through a shell launch, as a double-click does.
  $process = Start-Package $folder
  $tree = Assert-ProcessTree $process
  $admin = Login
  Assert ((Get-Supplies $admin) -contains "Release check paper") "the supply survives a restart"
  Invoke-Api "/api/login" @{ id = "001"; password = "wrong-password-123" } -Expected 403 | Out-Null
  Notice "Restart via shell launch of OfficeFlow.exe: no password prompt, same admin password, supply still present; process tree: $tree"

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
