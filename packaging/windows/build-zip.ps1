# Builds OfficeFlow-<version>-windows-x64.zip with a bundled Java runtime.
# Run from the repository root on Windows after `mvn -f server/pom.xml package`:
#   ./packaging/windows/build-zip.ps1 -Jdk $env:JAVA_HOME -OutputDirectory dist
param(
  [Parameter(Mandatory = $true)][string]$Jdk,
  [string]$OutputDirectory = "dist"
)
$ErrorActionPreference = "Stop"
$version = ([xml](Get-Content -Raw "server/pom.xml")).project.version
$name = "OfficeFlow-$version-windows-x64"
$jar = "server/target/officeflow-$version.jar"
if (-not (Test-Path $jar)) { throw "Build first: mvn -f server/pom.xml package ($jar is missing)" }
foreach ($tool in "jlink.exe", "jdeps.exe") {
  if (-not (Test-Path (Join-Path $Jdk "bin\$tool"))) { throw "$Jdk is not a JDK with $tool" }
}

$output = New-Item -ItemType Directory -Force $OutputDirectory
$stage = Join-Path $output.FullName $name
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
$app = New-Item -ItemType Directory -Force (Join-Path $stage "app")
Copy-Item $jar (Join-Path $app "officeflow.jar")
Copy-Item -Recurse "docs/site" (Join-Path $app "site")
Copy-Item "packaging/windows/launch.ps1" $app
Copy-Item -Recurse "packaging/windows/licenses" $stage

# Text files a person opens or Windows runs get CRLF line endings.
function Copy-WithCrlf([string]$Source, [string]$Target) {
  $text = [IO.File]::ReadAllText((Resolve-Path $Source)) -replace "`r?`n", "`r`n"
  [IO.File]::WriteAllText($Target, $text, (New-Object Text.UTF8Encoding $false))
}
Copy-WithCrlf "packaging/windows/Start OfficeFlow.cmd" (Join-Path $stage "Start OfficeFlow.cmd")
Copy-WithCrlf "packaging/windows/Quick Start.txt" (Join-Path $stage "Quick Start.txt")
Copy-WithCrlf "packaging/windows/THIRD-PARTY-NOTICES.txt" (Join-Path $stage "THIRD-PARTY-NOTICES.txt")
Copy-WithCrlf "LICENSE" (Join-Path $stage "LICENSE.txt")

# A runtime with only the Java modules OfficeFlow needs, including its legal notices.
$detected = & (Join-Path $Jdk "bin\jdeps.exe") --ignore-missing-deps --print-module-deps --multi-release 17 $jar
if ($LASTEXITCODE -ne 0) { throw "jdeps failed" }
$modules = (($detected -split ",") + "java.sql", "jdk.httpserver", "jdk.crypto.ec" |
  ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique) -join ","
& (Join-Path $Jdk "bin\jlink.exe") --add-modules $modules --strip-debug --no-man-pages `
  --no-header-files --compress=zip-6 --output (Join-Path $stage "runtime")
if ($LASTEXITCODE -ne 0) { throw "jlink failed" }
foreach ($file in "NOTICE", "LICENSE") {
  $path = Join-Path $Jdk $file
  if (Test-Path $path) { Copy-Item $path (Join-Path $stage "runtime\$file") }
}
if (-not (Test-Path (Join-Path $stage "runtime\legal\java.base\LICENSE"))) { throw "The runtime has no legal notices" }

# Microsoft's Visual C++ runtime and Universal CRT files are not redistributed. The launcher
# requires the Visual C++ Redistributable installed from Microsoft; Windows 10 and 11 include the UCRT.
$microsoftPattern = '^(vcruntime140|vcruntime140_1|msvcp140|ucrtbase)\.dll$|^api-ms-win-.*\.dll$'
$removed = Get-ChildItem -Recurse -File (Join-Path $stage "runtime") | Where-Object { $_.Name -match $microsoftPattern }
$removed | Remove-Item -Force
$signed = Get-ChildItem -Recurse -File $stage -Include *.dll, *.exe | Where-Object {
  $signature = Get-AuthenticodeSignature -LiteralPath $_.FullName
  $signature.SignerCertificate -and $signature.SignerCertificate.Subject -match 'O=Microsoft Corporation'
}
if ($signed) { throw "Microsoft-signed files remain: $(($signed | ForEach-Object Name) -join ', ')" }

$zip = Join-Path $output.FullName "$name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)

# Inspect the finished ZIP itself, not only the staging folder.
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try {
  $entries = @($archive.Entries | ForEach-Object { $_.FullName })
} finally {
  $archive.Dispose()
}
$leftover = @($entries | Where-Object { ($_ -split '/')[-1] -match $microsoftPattern })
if ($leftover.Count) { throw "The ZIP still contains Microsoft runtime files: $($leftover -join ', ')" }
$dllCount = @($entries | Where-Object { $_ -match '\.dll$' }).Count
Write-Output "::notice title=Microsoft runtime files::Removed $(@($removed).Count) files from runtime\bin; the finished ZIP contains 0 of them and no Microsoft-signed DLL or EXE ($dllCount DLLs in total)"
$hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
Set-Content -NoNewline -Encoding ascii -Path "$zip.sha256" -Value "$hash  $name.zip`n"

$runtime = (Get-Content (Join-Path $stage "runtime\release") | Where-Object { $_ -match '^JAVA_VERSION=' }) -replace '^JAVA_VERSION=|"', ''
$vendor = (Get-Content (Join-Path $Jdk "release") | Where-Object { $_ -match '^IMPLEMENTOR_VERSION=' }) -replace '^IMPLEMENTOR_VERSION=|"', ''
if ($vendor) { $runtime = "$runtime ($vendor)" }
$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Output "::notice title=Windows ZIP::$name.zip ($size MB) SHA-256 $hash"
Write-Output "::notice title=Bundled runtime::Java $runtime with modules $modules"
Write-Output $zip
