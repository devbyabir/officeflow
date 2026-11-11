# Downloads the pinned Eclipse Temurin JDK for the Windows ZIP, verifies it, extracts it and
# prints its folder. The Windows ZIP's runtime is made with jlink from exactly this JDK.
#   $jdk = ./packaging/windows/fetch-jdk.ps1 -Destination $env:RUNNER_TEMP
param([Parameter(Mandatory = $true)][string]$Destination)
$ErrorActionPreference = "Stop"
$pin = Get-Content -Raw "packaging/runtime/temurin-21.json" | ConvertFrom-Json
$folder = New-Item -ItemType Directory -Force (Join-Path $Destination "temurin-jdk")
$zip = Join-Path $folder.FullName $pin.jdk.file
$ProgressPreference = "SilentlyContinue"

# Retries temporary server errors (408, 429, 5xx) and network failures with backoff; other HTTP
# errors fail at once. Integrity is still checked below against the pinned checksum.
function Get-Download([string]$Url, [string]$Target) {
  $name = Split-Path $Target -Leaf
  $attempts = 5
  for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    Write-Host "Downloading $name (attempt $attempt/$attempts)"
    try {
      Invoke-WebRequest $Url -OutFile "$Target.part" -UseBasicParsing -TimeoutSec 600
      Move-Item -Force "$Target.part" $Target
      Write-Host "Downloaded $name ($('{0:N0}' -f (Get-Item $Target).Length) bytes)"
      return
    } catch {
      Remove-Item -Force -ErrorAction SilentlyContinue "$Target.part"
      $status = $null
      if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
      $temporary = ($null -eq $status) -or ($status -in 408, 429, 500, 502, 503, 504)
      if (-not $temporary -or $attempt -eq $attempts) {
        Write-Host "::error title=Download failed::$name from ${Url}: $($_.Exception.Message)"
        throw
      }
      $wait = 10 * [math]::Pow(2, $attempt - 1)
      Write-Host "::warning title=Download retry::${name}: $($_.Exception.Message); retrying in $wait s"
      Start-Sleep -Seconds $wait
    }
  }
}

Get-Download "$($pin.download_base)/$($pin.jdk.file)" $zip
# Release assets are served as binary, so save the checksum file and read it as text.
Get-Download "$($pin.download_base)/$($pin.jdk.file).sha256.txt" "$zip.sha256.txt"
$published = ((Get-Content -Raw "$zip.sha256.txt").Trim() -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
if ($published -ne $pin.jdk.sha256) { throw "Adoptium's published checksum $published differs from the pinned $($pin.jdk.sha256)" }
if ($actual -ne $pin.jdk.sha256) { throw "Downloaded JDK checksum $actual does not match $($pin.jdk.sha256)" }

$extract = Join-Path $folder.FullName "extracted"
Expand-Archive -LiteralPath $zip -DestinationPath $extract
$jdk = (Get-ChildItem -Directory $extract | Select-Object -First 1).FullName
$release = Get-Content (Join-Path $jdk "release") -Raw
$implementor = [regex]::Match($release, 'IMPLEMENTOR_VERSION="([^"]+)"').Groups[1].Value
$source = [regex]::Match($release, 'SOURCE="([^"]+)"').Groups[1].Value
if ($implementor -ne $pin.jdk.implementor_version) { throw "JDK reports $implementor, expected $($pin.jdk.implementor_version)" }
$sourceCommit = [regex]::Matches($source, '[0-9a-f]{7,40}') | ForEach-Object { $_.Value } |
  Where-Object { $pin.openjdk_source.commit.StartsWith($_) } | Select-Object -First 1
if (-not $sourceCommit) {
  throw "JDK release file SOURCE '$source' does not name commit $($pin.openjdk_source.commit)"
}
Write-Host "::notice title=Pinned JDK::$($pin.jdk.file) SHA-256 $actual verified; $implementor built from jdk21u $sourceCommit"
Write-Output $jdk
