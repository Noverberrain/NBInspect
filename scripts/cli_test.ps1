$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
Set-Location $root
$exe = Join-Path $root '_build/native/debug/build/cmd/nbinspect/nbinspect.exe'
$testDir = Join-Path $root '_build/cli-fixtures'
[IO.Directory]::CreateDirectory($testDir) | Out-Null
$valid = '{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","id":"a","source":"x=1","metadata":{},"execution_count":null,"outputs":[]}]}'
[IO.File]::WriteAllText((Join-Path $testDir 'a.ipynb'),$valid)
[IO.File]::WriteAllText((Join-Path $testDir 'b.ipynb'),$valid.Replace('x=1','x=2'))
[IO.File]::WriteAllText((Join-Path $testDir 'invalid.ipynb'),'{}')
[IO.File]::WriteAllText((Join-Path $testDir 'duplicate.ipynb'),$valid.Replace('"id":"a"','"id":"bad id"'))
$script:passed=0
function Invoke-Case([string]$name,[string[]]$cliArgs,[int]$expected,[bool]$json=$false) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=$exe
  $psi.Arguments=($cliArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
  $psi.UseShellExecute=$false
  $psi.RedirectStandardOutput=$true
  $psi.RedirectStandardError=$true
  $p=New-Object Diagnostics.Process
  $p.StartInfo=$psi
  [void]$p.Start()
  $stdout=$p.StandardOutput.ReadToEnd()
  $stderr=$p.StandardError.ReadToEnd()
  $p.WaitForExit()
  if ($p.ExitCode -ne $expected) {throw "$name exit $($p.ExitCode), expected $expected; $stderr"}
  if ($json) { [void]($stdout | ConvertFrom-Json); if ($stderr) {throw "$name unexpected stderr"} }
  if ($expected -eq 2 -and (!$stderr -or $stdout)) {throw "$name invalid error channel"}
  $script:passed++
}
$a='_build/cli-fixtures/a.ipynb'
$b='_build/cli-fixtures/b.ipynb'
Invoke-Case 'help' @('--help') 0
Invoke-Case 'check JSON' @('check',$a,'--format','json') 0 $true
Invoke-Case 'check info policy' @('check',$a,'--fail-on','info') 1
Invoke-Case 'same diff' @('diff',$a,$a,'--exit-code','--format','json') 0 $true
Invoke-Case 'changed diff' @('diff',$a,$b,'--exit-code','--format','json') 1 $true
Invoke-Case 'bad format' @('check',$a,'--format','xml') 2
Invoke-Case 'missing option' @('check',$a,'--output') 2
Invoke-Case 'missing file' @('check','_build/cli-fixtures/missing.ipynb') 2
Invoke-Case 'invalid JSON model' @('check','_build/cli-fixtures/invalid.ipynb') 2
Invoke-Case 'ID finding' @('check','_build/cli-fixtures/duplicate.ipynb','--format','json') 1 $true
Invoke-Case 'input overwrite' @('check',$a,'--output',$a) 2
$report='_build/cli-fixtures/report-' + [Guid]::NewGuid().ToString('N') + '.json'
Invoke-Case 'report file' @('check',$a,'--format','json','--output',$report) 0
[void](Get-Content -Raw $report | ConvertFrom-Json)
Invoke-Case 'existing output protected' @('check',$a,'--output',$report) 2
Write-Output "CLI integration: $script:passed passed"
