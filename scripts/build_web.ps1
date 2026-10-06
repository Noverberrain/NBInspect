$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
  moon build --target js --release
  if ($LASTEXITCODE -ne 0) { throw 'MoonBit JS build failed' }
  Copy-Item -LiteralPath '_build/js/release/build/bridge/bridge.js' -Destination 'web/nbinspect.js'
  Write-Output 'Browser bundle ready: web/nbinspect.js'
} finally {
  Pop-Location
}
