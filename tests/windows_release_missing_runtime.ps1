# Missing-runtime check for the release ZIP, for a disposable Windows machine (CI runner) only.
# 1. Uninstalls the x64 Visual C++ Redistributable using Microsoft's own uninstall entries.
# 2. If its DLLs are really gone, extracts the ZIP and checks that the bundled Java cannot start
#    on its own and that "Start OfficeFlow.cmd" shows the redistributable message without starting.
# 3. Installs the official redistributable from Microsoft again, so later tests have it.
# If Windows keeps the DLLs (for example because they are in use), step 2 is reported as not
# verified and the case still needs a clean Windows test.
param([Parameter(Mandatory = $true)][string]$Zip)
$ErrorActionPreference = "Stop"
if (-not $env:GITHUB_ACTIONS) { throw "This test uninstalls system software; it only runs on a disposable CI runner." }
$temp = $env:RUNNER_TEMP
$work = Join-Path $temp "OfficeFlow missing runtime test"
$system32 = Join-Path $env:SystemRoot "System32"
$runtimeFiles = "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll"
$installer = "https://aka.ms/vs/17/release/vc_redist.x64.exe"

function Notice([string]$Message) { Write-Output "::notice title=Missing VC++ runtime test::$Message" }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "Check failed: $Message" } }
function Get-RuntimeState {
  ($runtimeFiles | ForEach-Object {
      $path = Join-Path $system32 $_
      if (Test-Path $path) { "$_ $((Get-Item $path).VersionInfo.FileVersion)" } else { "$_ absent" }
    }) -join "; "
}

Notice "Before: $(Get-RuntimeState)"
$uninstallKeys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                 "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
$entries = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue | Where-Object {
  $_.DisplayName -match 'Microsoft Visual C\+\+ 20(15|17|19|22).*Redistributable \(x64\)' -or
  $_.DisplayName -match 'Microsoft Visual C\+\+ 20(15|17|19|22) X64 (Minimum|Additional) Runtime' }
foreach ($entry in $entries) {
  if ($entry.DisplayName -match 'Redistributable' -and $entry.BundleCachePath) {
    $process = Start-Process -FilePath $entry.BundleCachePath -ArgumentList "/uninstall", "/quiet", "/norestart" -Wait -PassThru
  } elseif ($entry.PSChildName -match '^\{[0-9A-F-]+\}$') {
    $process = Start-Process msiexec.exe -ArgumentList "/x", $entry.PSChildName, "/qn", "/norestart" -Wait -PassThru
  } else { continue }
  Notice "Uninstalled '$($entry.DisplayName)' (exit code $($process.ExitCode))"
}
$after = Get-RuntimeState
Notice "After uninstall: $after"

if ($runtimeFiles | Where-Object { Test-Path (Join-Path $system32 $_) }) {
  Notice "NOT VERIFIED: Windows kept the Visual C++ runtime DLLs on this runner, so the missing-runtime message still needs a test on a clean Windows 10 or 11 PC."
} else {
  Expand-Archive -LiteralPath $Zip -DestinationPath $work
  $folder = Join-Path $work ([IO.Path]::GetFileNameWithoutExtension($Zip))
  $java = Join-Path $folder "runtime\bin\java.exe"
  $javaProcess = Start-Process -FilePath $java -ArgumentList "-version" -Wait -PassThru -NoNewWindow
  Assert ($javaProcess.ExitCode -ne 0) "the bundled java.exe must not start without the Visual C++ runtime"
  Notice "Bundled java.exe without the runtime exited with code $($javaProcess.ExitCode) (it carries no Microsoft DLLs)"

  $env:LOCALAPPDATA = Join-Path $work "LocalAppData"
  $env:OFFICEFLOW_NO_BROWSER = "1"
  $env:OFFICEFLOW_ADMIN_PASSWORD = "missing-runtime-password"
  $launcher = Join-Path $folder "Start OfficeFlow.cmd"
  $output = (cmd.exe /d /c "`"$launcher`" < NUL" 2>&1 | Out-String)
  Write-Output $output
  Assert ($output -match 'Microsoft Visual C\+\+ Redistributable') "the launcher names the Visual C++ Redistributable"
  Assert ($output.Contains("https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist")) "the launcher shows Microsoft's download page"
  Assert ($output -match 'vcruntime140\.dll is not installed') "the launcher says which file is missing"
  Assert (-not (Test-Path (Join-Path $env:LOCALAPPDATA "OfficeFlow"))) "no workspace is created"
  $listening = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
  Assert (-not $listening) "OfficeFlow is not started"
  Notice "VERIFIED: with the runtime absent, 'Start OfficeFlow.cmd' showed the Visual C++ Redistributable message and Microsoft's download page, and started nothing"
  Remove-Item Env:OFFICEFLOW_ADMIN_PASSWORD, Env:OFFICEFLOW_NO_BROWSER
}

# Install the official runtime from Microsoft for the remaining tests.
$download = Join-Path $temp "vc_redist.x64.exe"
Invoke-WebRequest $installer -OutFile $download -UseBasicParsing
$signature = Get-AuthenticodeSignature -LiteralPath $download
Assert ($signature.Status -eq "Valid" -and $signature.SignerCertificate.Subject -match 'O=Microsoft Corporation') "the redistributable is signed by Microsoft"
$install = Start-Process -FilePath $download -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
Assert ($install.ExitCode -in 0, 1638, 3010) "the official redistributable installs (exit code $($install.ExitCode))"
$version = (Get-Item $download).VersionInfo.ProductVersion
Notice "Installed the official Microsoft Visual C++ Redistributable (x64) $version from $installer (exit code $($install.ExitCode)); now $(Get-RuntimeState)"
foreach ($name in $runtimeFiles) { Assert (Test-Path (Join-Path $system32 $name)) "$name is installed" }
