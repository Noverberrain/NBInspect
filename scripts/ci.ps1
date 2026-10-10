#requires -Version 7.0
param([string]$LogDirectory = '')
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (!$IsWindows) { throw 'This validation entry point requires Windows.' }
$root = Split-Path $PSScriptRoot
Push-Location $root
try {
  if (!$LogDirectory) {
    $LogDirectory = Join-Path '_build/ci-logs' ([Guid]::NewGuid().ToString('N'))
  }
  $logs = [IO.Directory]::CreateDirectory($LogDirectory).FullName
  $summary = Join-Path $logs 'summary.log'
  "NBInspect validation logs: $logs" | Tee-Object -FilePath $summary | Write-Host

  function Invoke-Stage([string]$Name, [string]$Program, [string[]]$Arguments) {
    "Starting $Name" | Tee-Object -FilePath $summary -Append | Write-Host
    $log = Join-Path $logs "$Name.log"
    & $Program @Arguments 2>&1 | Tee-Object -FilePath $log | Out-Host
    $code = $LASTEXITCODE
    "Exit code: $code" | Tee-Object -FilePath $log -Append | Write-Host
    if ($code -ne 0) { throw "$Name failed (exit $code). See $log" }
    "Passed $Name" | Tee-Object -FilePath $summary -Append | Write-Host
  }

  $pwsh = Join-Path $PSHOME 'pwsh.exe'
  Invoke-Stage 'moon-version' 'moon' @('version', '--all')
  Invoke-Stage 'git-version' 'git' @('--version')
  Invoke-Stage 'node-version' 'node' @('--version')
  Invoke-Stage 'format' 'moon' @('fmt', '--check')
  foreach ($target in @('native', 'js')) {
    Invoke-Stage "$target-check" 'moon' @('check', '--target', $target, '--deny-warn')
    Invoke-Stage "$target-test" 'moon' @('test', '--target', $target)
    Invoke-Stage "$target-info" 'moon' @('info', '--target', $target)
  }
  Invoke-Stage 'interfaces' 'git' @('diff', '--exit-code', '--', ':(glob)**/pkg.generated.mbti')
  Invoke-Stage 'native-build' 'moon' @('build', '--target', 'native')
  foreach ($script in @('cli_test', 'batch_cli_test', 'policy_cli_test', 'git_cli_test', 'staged_cli_test', 'hook_cli_test', 'pr_review_test', 'profile_cli_test')) {
    Invoke-Stage $script $pwsh @('-NoProfile', '-File', "scripts/$script.ps1")
  }
  Invoke-Stage 'web-build' $pwsh @('-NoProfile', '-File', 'scripts/build_web.ps1')
  Invoke-Stage 'browser-core' 'node' @('scripts/browser_core_test.mjs')
  Invoke-Stage 'browser-ui' 'node' @('scripts/browser_ui_test.mjs')
  'All validation stages passed.' | Tee-Object -FilePath $summary -Append | Write-Host
} catch {
  if ($summary) { $_.ToString() | Tee-Object -FilePath $summary -Append | Write-Host }
  else { Write-Host $_ }
  exit 1
} finally {
  Pop-Location
}
