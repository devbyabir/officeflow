# OfficeFlow launcher, started by "Start OfficeFlow.cmd". Works with Windows PowerShell 5.1.
# Uses the Java runtime in this package; the workspace stays in %LOCALAPPDATA%\OfficeFlow, so
# replacing this folder with a newer release keeps all records.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$java = Join-Path $root "runtime\bin\java.exe"
$jar = Join-Path $PSScriptRoot "officeflow.jar"
$site = Join-Path $PSScriptRoot "site"
$database = Join-Path $env:LOCALAPPDATA "OfficeFlow\officeflow.mv.db"
$url = "http://127.0.0.1:8080/"

function Stop-WithMessage([string]$Message) {
  Write-Host ""
  Write-Host $Message -ForegroundColor Red
  exit 1
}

function Test-OfficeFlow {
  try {
    $health = Invoke-WebRequest "${url}api/health" -UseBasicParsing -TimeoutSec 2
    return $health.Content -match '"service":"officeflow"'
  } catch {
    return $false
  }
}

function Read-NewPassword {
  Write-Host "Welcome to OfficeFlow. This is the first start for this Windows account."
  Write-Host "Choose a password for the administrator account (ID 001). Use 12-120 characters."
  Write-Host "Typing is hidden. Keep this password safe; it is needed to manage OfficeFlow."
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $first = Read-Host "New admin password" -AsSecureString
    $second = Read-Host "Type it again" -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first))
    $again = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($second))
    if ($plain -ne $again) { Write-Host "The passwords do not match. Try again." -ForegroundColor Yellow; continue }
    if ($plain.Length -lt 12 -or $plain.Length -gt 120 -or [string]::IsNullOrWhiteSpace($plain)) {
      Write-Host "Use 12-120 characters. Try again." -ForegroundColor Yellow
      continue
    }
    return $plain
  }
  Stop-WithMessage "No administrator password was set, so no workspace was created. Start OfficeFlow again to retry."
}

$Host.UI.RawUI.WindowTitle = "OfficeFlow"
if (-not (Test-Path -LiteralPath $java)) {
  Stop-WithMessage "The Java runtime is missing from this folder:`n  $java`nExtract the whole OfficeFlow ZIP again, then start OfficeFlow from the extracted folder."
}
if (-not (Test-Path -LiteralPath $jar) -or -not (Test-Path -LiteralPath (Join-Path $site "index.html"))) {
  Stop-WithMessage "Some OfficeFlow files are missing from:`n  $root`nExtract the whole OfficeFlow ZIP again. Do not run it from inside the ZIP."
}
if (Test-OfficeFlow) {
  Write-Host "OfficeFlow is already running. Opening $url"
  Write-Host "Use the other OfficeFlow window to stop it."
  if (-not $env:OFFICEFLOW_NO_BROWSER) { Start-Process $url }
  exit 0
}
if (-not (Test-Path -LiteralPath $database) -and -not $env:OFFICEFLOW_ADMIN_PASSWORD) {
  $env:OFFICEFLOW_ADMIN_PASSWORD = Read-NewPassword
}

Write-Host ""
Write-Host "Starting OfficeFlow. Your workspace: $database"
Write-Host "Keep this window open while you use OfficeFlow. To stop it, press Ctrl+C."
Write-Host ""
if (-not $env:OFFICEFLOW_NO_BROWSER) {
  # Open the browser once the server answers (up to one minute).
  $opener = "for (`$i = 0; `$i -lt 60; `$i++) { try { Invoke-WebRequest '${url}api/health' -UseBasicParsing -TimeoutSec 1 | Out-Null; Start-Process '$url'; break } catch { Start-Sleep -Seconds 1 } }"
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($opener))
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile", "-EncodedCommand", $encoded
}

& $java "-Dofficeflow.site=$site" -jar $jar
$code = $LASTEXITCODE
$env:OFFICEFLOW_ADMIN_PASSWORD = $null
# 130 and 0xC000013A are a Ctrl+C stop, which is the normal way to close OfficeFlow.
if ($code -ne 0 -and $code -ne 130 -and $code -ne -1073741510) {
  Stop-WithMessage "OfficeFlow stopped because of the problem shown above (exit code $code)."
}
Write-Host "OfficeFlow has stopped. Your workspace is saved in $database"
exit 0
