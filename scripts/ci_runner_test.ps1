#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (!$IsWindows) { throw 'CI runner tests require Windows.' }
$originalPath = $env:PATH
Push-Location (Split-Path $PSScriptRoot)
try {
  $fixture = Join-Path (Get-Location) ('_build/ci-logs/runner-tests-' + [Guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($fixture) | Out-Null
  $moon = Join-Path $fixture 'moon.cmd'
  $env:PATH = "$fixture;$originalPath"
  foreach ($failedStage in @('fmt', 'check')) {
    @"
@echo off
if "%1"=="$failedStage" (
  echo simulated $failedStage failure 1>&2
  exit /b 23
)
echo simulated moon success
exit /b 0
"@ | Set-Content -LiteralPath $moon -Encoding ascii
    $logs = Join-Path $fixture $failedStage
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File scripts/ci.ps1 -LogDirectory $logs *> (Join-Path $fixture "$failedStage-driver.log")
    if ($LASTEXITCODE -ne 1) { throw "Failed stage $failedStage did not fail CI" }
    $stageName = if ($failedStage -eq 'fmt') { 'format' } else { 'native-check' }
    $log = Get-Content (Join-Path $logs "$stageName.log") -Raw
    if ($log -notmatch "simulated $failedStage failure" -or $log -notmatch 'Exit code: 23') { throw 'Missing failure output or exit code' }
    $summary = Get-Content (Join-Path $logs 'summary.log') -Raw
    if ($summary -notmatch "$stageName failed") { throw 'Missing failed stage summary' }
    $next = if ($failedStage -eq 'fmt') { 'native-check' } else { 'native-test' }
    if (Test-Path (Join-Path $logs "$next.log")) { throw 'CI continued after failure' }
    Write-Output "Failure-path test passed: $stageName, stderr, exit code, stopped stages"
  }
} finally {
  $env:PATH = $originalPath
  Pop-Location
}
