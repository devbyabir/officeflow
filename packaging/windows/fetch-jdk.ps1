# Downloads the pinned Eclipse Temurin JDK for the Windows ZIP, verifies it, extracts it and
# prints its folder. The Windows ZIP's runtime is made with jlink from exactly this JDK.
#   $jdk = ./packaging/windows/fetch-jdk.ps1 -Destination $env:RUNNER_TEMP
param([Parameter(Mandatory = $true)][string]$Destination)
$ErrorActionPreference = "Stop"
$pin = Get-Content -Raw "packaging/runtime/temurin-21.json" | ConvertFrom-Json
$folder = New-Item -ItemType Directory -Force (Join-Path $Destination "temurin-jdk")
$zip = Join-Path $folder.FullName $pin.jdk.file
$ProgressPreference = "SilentlyContinue"
Invoke-WebRequest "$($pin.download_base)/$($pin.jdk.file)" -OutFile $zip -UseBasicParsing
# Release assets are served as binary, so save the checksum file and read it as text.
Invoke-WebRequest "$($pin.download_base)/$($pin.jdk.file).sha256.txt" -OutFile "$zip.sha256.txt" -UseBasicParsing
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
