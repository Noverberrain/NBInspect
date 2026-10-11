#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$exe = Join-Path $root '_build/native/debug/build/cmd/nbinspect/nbinspect.exe'
$fixtures = [IO.Directory]::CreateDirectory((Join-Path $root ('_build/profile-diff-fixtures-' + [Guid]::NewGuid().ToString('N')))).FullName
$utf8 = [Text.UTF8Encoding]::new($false)
$script:passed = 0
function Invoke-ProfileCase([string]$Name, [string[]]$Arguments, [int]$Expected = 0) {
  $psi = [Diagnostics.ProcessStartInfo]::new($exe)
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  foreach ($arg in $Arguments) { $psi.ArgumentList.Add($arg) }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $psi
  try {
    [void]$process.Start()
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit(30000)) { $process.Kill($true); throw "$Name timed out" }
    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne $Expected) { throw "$Name exit $($process.ExitCode), expected $Expected; $stderr" }
    if ($Expected -eq 2 -and (!$stderr -or $stdout)) { throw "$Name must use stderr without a partial report" }
    if ($Expected -eq 0 -and $stderr) { throw "$Name unexpected stderr: $stderr" }
    $script:passed++
    return $stdout
  } finally { $process.Dispose() }
}
$beforePath=Join-Path $fixtures 'before 中文.ipynb'
$afterPath=Join-Path $fixtures 'after 中文.ipynb'
$makeBook = { param([string]$Text) @{nbformat=4;nbformat_minor=5;metadata=@{};cells=@(@{cell_type='code';id='stable';source='x=1';metadata=@{};execution_count=$null;outputs=@(@{output_type='stream';name='stdout';text=$Text})})} | ConvertTo-Json -Depth 20 -Compress }
[IO.File]::WriteAllText($beforePath, (& $makeBook 'short'), $utf8)
[IO.File]::WriteAllText($afterPath, (& $makeBook 'larger output'), $utf8)
$r=(Invoke-ProfileCase 'growth JSON' @('profile-diff',$beforePath,$afterPath,'--format','json')) | ConvertFrom-Json
if ($r.kind -ne 'profile-diff' -or $r.matched_count -ne 1 -or $r.cells[0].basis -ne 'id' -or $r.summary.delta.output_bytes -ne 8 -or $r.summary.delta.notebook_bytes -ne 8) { throw 'incorrect growth report' }
if ($r.cells[0].delta_bytes + $r.container_delta_bytes -ne $r.summary.delta.notebook_bytes) {throw 'accounting mismatch'}
$reverse=(Invoke-ProfileCase 'shrink JSON' @('profile-diff',$afterPath,$beforePath,'--format','json')) | ConvertFrom-Json
if ($reverse.summary.delta.notebook_bytes -ne -8) {throw 'negative delta lost'}
$identical=(Invoke-ProfileCase 'same notebook' @('profile-diff',$beforePath,$beforePath,'--format','json')) | ConvertFrom-Json
if ($identical.summary.delta.notebook_bytes -ne 0) {throw 'same input delta'}
$text=Invoke-ProfileCase 'text report' @('profile-diff',$beforePath,$afterPath)
if (!$text.Contains('Cells by absolute size change') -or !$text.Contains('delta 8')) {throw 'text report content'}
$html=Invoke-ProfileCase 'HTML report' @('profile-diff',$beforePath,$afterPath,'--format','html')
if (!$html.Contains('Byte changes by category') -or !$html.Contains('Cell measurements and matching evidence') -or !$html.Contains("script-src 'none'")) {throw 'HTML report content'}
$reportPath=Join-Path $fixtures 'report.json'
[void](Invoke-ProfileCase 'new report file' @('profile-diff',$beforePath,$afterPath,'--format','json','--output',$reportPath))
if ((Get-Content $reportPath -Raw | ConvertFrom-Json).kind -ne 'profile-diff') {throw 'file report kind'}
foreach ($protected in @($beforePath,$afterPath,$reportPath)) {
  $hash=(Get-FileHash $protected).Hash
  [void](Invoke-ProfileCase 'overwrite protected' @('profile-diff',$beforePath,$afterPath,'--output',$protected) 2)
  if ((Get-FileHash $protected).Hash -ne $hash) {throw 'protected file changed'}
}
foreach ($option in @('--config','--fail-on','--view')) {
  $value=switch ($option) { '--config' {'missing.json'}; '--fail-on' {'error'}; '--view' {'all'} }
  [void](Invoke-ProfileCase "reject $option" @('profile-diff',$beforePath,$afterPath,$option,$value) 2)
}
foreach ($option in @('--recursive','--exit-code','--staged')) {
  [void](Invoke-ProfileCase "reject $option" @('profile-diff',$beforePath,$afterPath,$option) 2)
}
[void](Invoke-ProfileCase 'missing second input' @('profile-diff',$beforePath) 2)
[void](Invoke-ProfileCase 'extra input' @('profile-diff',$beforePath,$afterPath,$afterPath) 2)
[void](Invoke-ProfileCase 'bad format' @('profile-diff',$beforePath,$afterPath,'--format','xml') 2)
[void](Invoke-ProfileCase 'missing option value' @('profile-diff',$beforePath,$afterPath,'--output') 2)
[void](Invoke-ProfileCase 'missing file' @('profile-diff',$beforePath,(Join-Path $fixtures 'absent.ipynb')) 2)
$bad=Join-Path $fixtures 'bad.ipynb'
[IO.File]::WriteAllText($bad,'{}',$utf8)
[void](Invoke-ProfileCase 'invalid before' @('profile-diff',$bad,$afterPath) 2)
[void](Invoke-ProfileCase 'invalid after' @('profile-diff',$beforePath,$bad) 2)
$future=Join-Path $fixtures 'future.ipynb'
[IO.File]::WriteAllText($future,(Get-Content $afterPath -Raw).Replace('"nbformat_minor":5','"nbformat_minor":6'),$utf8)
[void](Invoke-ProfileCase 'unsupported minor' @('profile-diff',$beforePath,$future) 2)
$empty=Join-Path $fixtures 'empty.ipynb'
[IO.File]::WriteAllText($empty,'{"nbformat":4,"nbformat_minor":0,"metadata":{},"cells":[]}',$utf8)
$new=(Invoke-ProfileCase 'empty to new' @('profile-diff',$empty,$afterPath,'--format','json')) | ConvertFrom-Json
if ($new.unmatched_after_count -ne 1 -or $new.cells[0].kind -ne 'unmatched_after') {throw 'new cell count'}
$removed=(Invoke-ProfileCase 'new to empty' @('profile-diff',$afterPath,$empty,'--format','json')) | ConvertFrom-Json
if ($removed.unmatched_before_count -ne 1 -or $removed.cells[0].kind -ne 'unmatched_before') {throw 'removed cell count'}
[void](Invoke-ProfileCase 'two empty notebooks' @('profile-diff',$empty,$empty,'--format','json'))
$ambiguous=Join-Path $fixtures 'ambiguous.ipynb'
$duplicate=@{cell_type='raw';source='same';metadata=@{}}
[IO.File]::WriteAllText($ambiguous,(@{nbformat=4;nbformat_minor=4;metadata=@{};cells=@($duplicate,$duplicate)} | ConvertTo-Json -Depth 20 -Compress),$utf8)
$a=(Invoke-ProfileCase 'ambiguity retained' @('profile-diff',$ambiguous,$ambiguous,'--format','json')) | ConvertFrom-Json
if ($a.matched_count -ne 0 -or $a.ambiguous_before.Count -ne 2 -or $a.cells.Count -ne 4) {throw 'ambiguous cells falsely paired'}
Write-Output "Profile diff CLI integration: $script:passed passed"
Write-Output "Fixtures retained in: $fixtures"
