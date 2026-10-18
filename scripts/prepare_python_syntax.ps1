#requires -Version 7.0
param([switch]$SkipInstall)
$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
  if (!$SkipInstall) {
    npm ci --prefix tools/python-syntax --ignore-scripts --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw 'Locked syntax dependencies failed to install' }
  }
  moon build --target native
  if ($LASTEXITCODE -ne 0) { throw 'Native syntax validator build failed' }
  moon build --target js --release
  if ($LASTEXITCODE -ne 0) { throw 'JS syntax validator build failed' }
  Write-Output 'Python syntax probe ready. Source code is parsed, never executed.'
} finally { Pop-Location }
