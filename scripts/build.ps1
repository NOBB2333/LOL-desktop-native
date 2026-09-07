param(
  [ValidateSet('windows','macos','linux')]
  [string]$Target = '',
  [switch]$NoArchive
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $Root 'config/native.json'
$Config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
if (-not $Target) { $Target = [string]$Config.package.target }
$SdkPath = [string]$Config.nativeSdkPath
if (-not [IO.Path]::IsPathRooted($SdkPath)) { $SdkPath = Join-Path $Root $SdkPath }
if (-not (Test-Path (Join-Path $SdkPath 'build.zig'))) {
  $GlobalSdk = Join-Path (npm root -g) '@native-sdk/cli'
  if (Test-Path (Join-Path $GlobalSdk 'build.zig')) { $SdkPath = $GlobalSdk }
}
if (-not (Test-Path (Join-Path $SdkPath 'build.zig'))) { throw "Native SDK not found: $SdkPath" }

function Require-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Required command not found: $Name" }
}
Require-Command 'node'
Require-Command 'npm'
Require-Command 'zig'
& node (Join-Path $Root 'scripts/sync-native-config.mjs')
if ($LASTEXITCODE -ne 0) { throw "native config sync failed with exit code $LASTEXITCODE" }
if (-not (Get-Command 'native' -ErrorAction SilentlyContinue)) {
  $NativeScript = Join-Path (Split-Path -Parent (Get-Command node).Source) 'native.ps1'
  if (-not (Test-Path $NativeScript)) { throw 'Native CLI not found; install @native-sdk/cli first' }
}

Push-Location $Root
try {
  if ($Target -eq 'windows' -and [bool]$Config.package.singleFile) {
    $RunningApps = @(Get-Process -Name 'lol-desktop-native' -ErrorAction SilentlyContinue)
    if ($RunningApps.Count -gt 0) {
      Write-Host 'Closing the running lol-desktop-native instance so the single executable can be replaced...'
      $RunningApps | Stop-Process -Force -ErrorAction SilentlyContinue
      $RunningApps | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
      if (Get-Process -Name 'lol-desktop-native' -ErrorAction SilentlyContinue) {
        Write-Warning 'The elevated application is still running. Its old executable will be renamed and cleaned up after the process exits.'
      }
    }
  }
  $ZigArgs = @('build','package',"-Dpackage-target=$Target", "-Dplatform=$Target", "-Dnative-sdk-path=$SdkPath", '-Dpackage-archive=false')
  & zig @ZigArgs
  if ($LASTEXITCODE -ne 0) { throw "zig build failed with exit code $LASTEXITCODE" }
  $PackageRoot = Join-Path $Root 'zig-out/package'
  $PackageDir = Join-Path $PackageRoot "lol-desktop-native-2.0.0-$Target-ReleaseFast"
  if (-not $NoArchive -and [bool]$Config.package.archive -and [bool]$Config.package.singleFile -and (Test-Path $PackageDir)) {
    $Binary = Join-Path $PackageDir 'bin/lol-desktop-native.exe'
    $SingleExe = Join-Path $PackageRoot 'lol-desktop-native.exe'
    $IncomingExe = Join-Path $PackageRoot 'lol-desktop-native.new.exe'
    $DeferredOldExe = $null
    $LegacyWebViewData = "$SingleExe.WebView2"
    if (-not (Test-Path $Binary)) { throw "Native package did not produce $Binary" }
    Copy-Item -LiteralPath $Binary -Destination $IncomingExe -Force
    if (Test-Path -LiteralPath $LegacyWebViewData) {
      # Older builds let WebView2 place its profile beside the executable.
      # The app now uses LOCALAPPDATA, so this stale output-side cache can go.
      Remove-Item -LiteralPath $LegacyWebViewData -Recurse -Force
    }
    if (Test-Path $SingleExe) {
      try { Remove-Item -LiteralPath $SingleExe -Force -ErrorAction Stop }
      catch {
        $DeferredOldExe = Join-Path $PackageRoot "lol-desktop-native.running-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).old.exe"
        Move-Item -LiteralPath $SingleExe -Destination $DeferredOldExe -Force -ErrorAction Stop
      }
    }
    Get-ChildItem -LiteralPath $PackageRoot -Filter '*.zip' -File -ErrorAction SilentlyContinue | Remove-Item -Force
    Move-Item -LiteralPath $IncomingExe -Destination $SingleExe -Force
    Remove-Item -LiteralPath $PackageDir -Recurse -Force
    $DeferredOldFiles = @(Get-ChildItem -LiteralPath $PackageRoot -Filter 'lol-desktop-native.running*.exe' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    if ($DeferredOldExe -and $DeferredOldExe -notin $DeferredOldFiles) { $DeferredOldFiles += $DeferredOldExe }
    if ($DeferredOldFiles.Count -gt 0) {
      $RunningIds = @(Get-Process -Name 'lol-desktop-native' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
      if ($RunningIds.Count -gt 0) {
        $CleanupRemovals = $DeferredOldFiles | ForEach-Object { "Remove-Item -LiteralPath '$($_.Replace("'", "''"))' -Force -ErrorAction SilentlyContinue" }
        $Cleanup = "Wait-Process -Id $($RunningIds -join ',') -ErrorAction SilentlyContinue; $($CleanupRemovals -join '; ')"
        $EncodedCleanup = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Cleanup))
        Start-Process -FilePath (Get-Command powershell).Source -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$EncodedCleanup) -WindowStyle Hidden
      } else {
        $DeferredOldFiles | ForEach-Object { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }
      }
    }
    Write-Host "Single-file executable: $SingleExe"
  } elseif (-not $NoArchive -and [bool]$Config.package.archive -and (Test-Path $PackageDir)) {
    $Archive = "$PackageDir.zip"
    if (Test-Path $Archive) { Remove-Item -LiteralPath $Archive -Force }
    Compress-Archive -Path (Join-Path $PackageDir '*') -DestinationPath $Archive -CompressionLevel Optimal
    Write-Host "Package archive: $Archive"
  } else { Write-Host "Package output: $PackageRoot" }
} finally { Pop-Location }
