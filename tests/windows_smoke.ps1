# Windows smoke check for the README's PowerShell instructions: first launch, the default
# %LOCALAPPDATA%\OfficeFlow data path, reopening, checking a backup and restoring it.
# Run from the repository root after `mvn -f server/pom.xml package`, on a disposable machine
# (CI runner). It refuses to run if a real workspace already exists at the default path.
$ErrorActionPreference = "Stop"
$repo = (Get-Location).Path
$jar = "server\target\officeflow-1.0.2.jar"
$data = Join-Path $env:LOCALAPPDATA "OfficeFlow"
$database = Join-Path $data "officeflow.mv.db"
$temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$work = Join-Path $temp "officeflow-smoke"
if (Test-Path $database) { throw "A workspace already exists at $database. This check only uses fresh data." }
if (-not (Test-Path $jar)) { throw "Build first: mvn -f server/pom.xml package" }
New-Item -ItemType Directory -Force $work | Out-Null
$servers = @()

function Notice([string]$Message) { Write-Output "::notice title=Windows smoke::$Message" }

# Runs a README command line in its own PowerShell, as a person would type it.
function Start-OfficeFlow([string]$Command, [int]$Port = 8080) {
  $log = Join-Path $work "server-$([guid]::NewGuid()).log"
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
  $process = Start-Process pwsh -ArgumentList "-NoProfile", "-EncodedCommand", $encoded `
    -WorkingDirectory $repo -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
    -PassThru -NoNewWindow
  $script:servers += $process
  for ($i = 0; $i -lt 300; $i++) {
    Start-Sleep -Milliseconds 200
    $text = if (Test-Path $log) { Get-Content $log -Raw } else { "" }
    if ($text -match "Press Ctrl\+C to stop") {
      return @{ Process = $process; Output = $text; Base = "http://127.0.0.1:$Port" }
    }
    if ($process.HasExited) { throw "OfficeFlow stopped:`n$text`n$(Get-Content "$log.err" -Raw)" }
  }
  throw "OfficeFlow did not start:`n$text"
}

# Ctrl+C cannot be sent to a background console in CI, so wait past H2's one-second write
# delay and end the process tree. People stop OfficeFlow with Ctrl+C, which closes H2 cleanly.
function Stop-OfficeFlow($Server) {
  Start-Sleep -Seconds 3
  taskkill /PID $Server.Process.Id /T /F | Out-Null
  $Server.Process.WaitForExit()
  Start-Sleep -Seconds 1
}

function Invoke-Api([string]$Base, [string]$Path, $Body = $null, [string]$Token = "", [int]$Expected = 200) {
  $parameters = @{ Uri = "$Base$Path"; Method = "Get"; SkipHttpErrorCheck = $true; StatusCodeVariable = "status" }
  if ($Token) { $parameters.Headers = @{ Authorization = "Bearer $Token" } }
  if ($null -ne $Body) {
    $parameters.Method = "Post"
    $parameters.ContentType = "application/json"
    $parameters.Body = $Body | ConvertTo-Json -Depth 5
  }
  $result = Invoke-RestMethod @parameters
  if ($status -ne $Expected) { throw "$Path returned $status, expected ${Expected}: $($result | ConvertTo-Json -Depth 5)" }
  return $result
}

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "Check failed: $Message" } }

function Assert-Workspace([string]$Base, [string]$Password, [bool]$ExpectLaterSupply) {
  $admin = (Invoke-Api $Base "/api/login" @{ id = "001"; password = "smoke-admin" }).token
  $state = Invoke-Api $Base "/api/state" -Token $admin
  $paper = $state.supplies | Where-Object name -eq "Smoke paper"
  Assert ($paper.quantity -eq 3) "stock is 3 after issuing 2 of 5"
  Assert ($state.requests[0].status -eq "Issued") "request history shows Issued"
  Assert ((@($state.supplies | Where-Object name -eq "Added after backup").Count -eq 1) -eq $ExpectLaterSupply) `
    "the supply added after the backup is present only when expected"
  $teacher = Invoke-Api $Base "/api/login" @{ id = "T001"; password = $Password }
  Assert (-not $teacher.actor.mustChangePassword) "the teacher's own password still works"
}

try {
  # README step 2, with the password set directly because Read-Host needs a keyboard.
  $env:OFFICEFLOW_ADMIN_PASSWORD = "smoke-admin"
  $server = Start-OfficeFlow "java -jar server\target\officeflow-1.0.2.jar"
  Assert ($server.Output.Contains("Database: $database")) "prints the default database path $database"
  Assert (Test-Path $database) "creates $database"
  Notice "First launch with 'java -jar server\target\officeflow-1.0.2.jar' created $database"
  $page = Invoke-WebRequest "$($server.Base)/"
  Assert ($page.Content.Contains('<meta name="officeflow-mode" content="java" />')) "serves the Java-mode page"

  $base = $server.Base
  $admin = (Invoke-Api $base "/api/login" @{ id = "001"; password = "smoke-admin" }).token
  $created = Invoke-Api $base "/api/command" @{ action = "saveTeacher"; data = @{
      id = "T001"; name = "Smoke Teacher"; department = "Office"; email = "" } } $admin
  $temporary = $created.temporaryPasswords[0].password
  Invoke-Api $base "/api/login" @{ id = "T001"; password = "T001" } -Expected 403 | Out-Null
  $login = Invoke-Api $base "/api/login" @{ id = "T001"; password = $temporary }
  Assert $login.actor.mustChangePassword "a temporary password must be changed"
  $blocked = Invoke-Api $base "/api/state" -Token $login.token -Expected 403
  Assert ($blocked.code -eq "PASSWORD_CHANGE_REQUIRED") "temporary sessions cannot read the workspace"
  Invoke-Api $base "/api/password/change" @{ currentPassword = $temporary; newPassword = "smoke-teach"; hint = "school clue" } $login.token | Out-Null
  $teacher = (Invoke-Api $base "/api/login" @{ id = "T001"; password = "smoke-teach" }).token
  $state = Invoke-Api $base "/api/command" @{ action = "saveSupply"; data = @{
      name = "Smoke paper"; category = "Paper & print"; quantity = "5"; threshold = "1"; unit = "reams" } } $admin
  $supply = ($state.supplies | Where-Object name -eq "Smoke paper").id
  $request = Invoke-Api $base "/api/command" @{ action = "request"; data = @{ supplyId = $supply; quantity = "2" } } $teacher
  Invoke-Api $base "/api/command" @{ action = "issue"; data = @{ id = $request.requests[0].id } } $admin | Out-Null
  Notice "Temporary password blocked the workspace until changed; stock issued from 5 to 3"
  Stop-OfficeFlow $server

  # README step 3: later starts need no password.
  Remove-Item Env:OFFICEFLOW_ADMIN_PASSWORD
  $server = Start-OfficeFlow "java -jar server\target\officeflow-1.0.2.jar"
  Assert-Workspace $server.Base "smoke-teach" $false
  Notice "Reopened $database without OFFICEFLOW_ADMIN_PASSWORD; stock, history and passwords intact"
  Stop-OfficeFlow $server

  # README "Back up and restore": back up with OfficeFlow stopped.
  $backups = Join-Path $work "backups"
  New-Item -ItemType Directory -Force $backups | Out-Null
  $backup = Join-Path $backups "officeflow-$(Get-Date -Format yyyy-MM-dd-HHmm).mv.db"
  Copy-Item "$env:LOCALAPPDATA\OfficeFlow\officeflow.mv.db" $backup

  # Check the backup in a separate folder on port 8081, with the README's quoted options.
  $check = Join-Path $work "officeflow-check"
  New-Item -ItemType Directory -Force $check | Out-Null
  Copy-Item $backup "$check\officeflow.mv.db"
  $server = Start-OfficeFlow "java `"-Dofficeflow.db=jdbc:h2:$check\officeflow`" `"-Dofficeflow.port=8081`" -jar server\target\officeflow-1.0.2.jar" 8081
  Assert ($server.Output.Contains("Database: $check\officeflow.mv.db")) "the backup check opens the copy"
  Assert-Workspace $server.Base "smoke-teach" $false
  Notice "Backup copy opened on port 8081 from $check; stock, history and passwords intact"
  Stop-OfficeFlow $server

  # Change the live workspace after the backup, then restore as the README describes.
  $server = Start-OfficeFlow "java -jar server\target\officeflow-1.0.2.jar"
  $admin = (Invoke-Api $server.Base "/api/login" @{ id = "001"; password = "smoke-admin" }).token
  Invoke-Api $server.Base "/api/command" @{ action = "saveSupply"; data = @{
      name = "Added after backup"; category = "Stationery"; quantity = "1"; threshold = "0"; unit = "box" } } $admin | Out-Null
  Assert-Workspace $server.Base "smoke-teach" $true
  Stop-OfficeFlow $server

  $data = "$env:LOCALAPPDATA\OfficeFlow"
  Rename-Item "$data\officeflow.mv.db" "officeflow-before-restore-$(Get-Date -Format yyyy-MM-dd-HHmm).mv.db"
  Copy-Item $backup "$data\officeflow.mv.db"
  Assert (@(Get-ChildItem $data -Filter "officeflow-before-restore-*.mv.db").Count -eq 1) "the pre-restore file is kept"
  $server = Start-OfficeFlow "java -jar server\target\officeflow-1.0.2.jar"
  Assert-Workspace $server.Base "smoke-teach" $false
  Notice "Restored the backup into $database; later changes are gone and the previous file was kept"
  Stop-OfficeFlow $server
  Write-Output "Windows smoke check passed."
}
finally {
  foreach ($process in $servers) {
    if (-not $process.HasExited) { taskkill /PID $process.Id /T /F | Out-Null }
  }
}
