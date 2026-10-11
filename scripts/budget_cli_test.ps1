#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$exe = Join-Path $root '_build/native/debug/build/cmd/nbinspect/nbinspect.exe'
$fixtures = [IO.Directory]::CreateDirectory((Join-Path $root ('_build/budget-fixtures-' + [Guid]::NewGuid().ToString('N')))).FullName
$utf8 = [Text.UTF8Encoding]::new($false)
$script:passed = 0
function Invoke-BudgetCase([string]$Name, [string[]]$Arguments, [int]$Expected = 0) {
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
    if ($Expected -ne 2 -and $stderr) { throw "$Name unexpected stderr: $stderr" }
    $script:passed++
    return $stdout
  } finally { $process.Dispose() }
}
$beforePath = Join-Path $fixtures 'before 中文.ipynb'
$afterPath = Join-Path $fixtures 'after 中文.ipynb'
$configPath = Join-Path $fixtures 'budget 中文.json'
$makeBook = { param([string]$Text) @{nbformat=4;nbformat_minor=5;metadata=@{};cells=@(@{cell_type='code';id='stable';source='x=1';metadata=@{};execution_count=$null;outputs=@(@{output_type='stream';name='stdout';text=$Text})})} | ConvertTo-Json -Depth 20 -Compress }
[IO.File]::WriteAllText($beforePath, (& $makeBook 'short'), $utf8)
[IO.File]::WriteAllText($afterPath, (& $makeBook 'short123'), $utf8)
function Set-Budget([string]$Text) { [IO.File]::WriteAllText($configPath, $Text, $utf8) }
Set-Budget '{"limits":{"max_notebook_growth_bytes":3,"max_output_growth_bytes":3}}'
$argsBase = @('budget', $beforePath, $afterPath, '--config', $configPath)
$r = (Invoke-BudgetCase 'exact allowances JSON' ($argsBase + @('--format','json'))) | ConvertFrom-Json
if ($r.kind -ne 'budget' -or $r.status -ne 'passed' -or $r.checks.Count -ne 2 -or $r.checks[0].delta_bytes -ne 3) { throw 'budget boundary report' }
if ($r.budget.limits.max_output_growth_bytes -ne 3 -or $r.comparison.matched_count -ne 1) { throw 'effective allowance/evidence missing' }
Set-Budget '{"limits":{"max_notebook_growth_bytes":2,"max_output_growth_bytes":1}}'
$r = (Invoke-BudgetCase 'exceeded JSON exit 1' ($argsBase + @('--format','json')) 1) | ConvertFrom-Json
if ($r.status -ne 'blocked' -or $r.exceeded_count -ne 2 -or $r.checks[0].excess_bytes -ne 1 -or $r.checks[1].excess_bytes -ne 2) { throw 'budget violation report' }
$text = Invoke-BudgetCase 'blocked text' $argsBase 1
if (!$text.Contains('NBInspect budget') -or !$text.Contains('excess 2 bytes; blocked') -or !$text.Contains('Cells by absolute size change')) { throw 'budget text missing' }
$html = Invoke-BudgetCase 'blocked HTML' ($argsBase + @('--format','html')) 1
if (!$html.Contains('Growth allowance results') -or !$html.Contains('Effective size budget') -or !$html.Contains('Cell measurements and matching evidence') -or !$html.Contains("script-src 'none'")) { throw 'budget HTML missing' }
$reportPath = Join-Path $fixtures 'blocked report.json'
[void](Invoke-BudgetCase 'blocked report saved before exit 1' ($argsBase + @('--format','json','--output',$reportPath)) 1)
if ((Get-Content $reportPath -Raw | ConvertFrom-Json).status -ne 'blocked') { throw 'blocked artifact absent' }
foreach ($protected in @($beforePath,$afterPath,$configPath,$reportPath)) {
  $hash = (Get-FileHash $protected).Hash
  [void](Invoke-BudgetCase 'no overwrite' ($argsBase + @('--output',$protected)) 2)
  if ((Get-FileHash $protected).Hash -ne $hash) { throw 'protected input overwritten' }
}
Set-Budget '{"limits":{"max_notebook_growth_bytes":0,"max_output_growth_bytes":0}}'
[void](Invoke-BudgetCase 'shrinking passes zero allowance' @('budget',$afterPath,$beforePath,'--config',$configPath))
[void](Invoke-BudgetCase 'identical passes zero allowance' @('budget',$beforePath,$beforePath,'--config',$configPath))
[void](Invoke-BudgetCase 'growth fails zero allowance' $argsBase 1)
Set-Budget '{"limits":{"max_attachment_growth_bytes":0}}'
$r = (Invoke-BudgetCase 'unconfigured output growth ignored' ($argsBase + @('--format','json'))) | ConvertFrom-Json
if ($r.checks.Count -ne 1 -or $r.checks[0].metric -ne 'attachment_bytes') { throw 'omitted limit checked' }
foreach ($option in @('--view','--fail-on')) {
  $value = if ($option -eq '--view') {'all'} else {'error'}
  [void](Invoke-BudgetCase "reject $option" ($argsBase + @($option,$value)) 2)
}
foreach ($option in @('--exit-code','--recursive','--staged')) { [void](Invoke-BudgetCase "reject $option" ($argsBase + @($option)) 2) }
[void](Invoke-BudgetCase 'missing explicit budget' @('budget',$beforePath,$afterPath) 2)
[void](Invoke-BudgetCase 'missing second input' @('budget',$beforePath,'--config',$configPath) 2)
[void](Invoke-BudgetCase 'extra input' ($argsBase + @($afterPath)) 2)
[void](Invoke-BudgetCase 'missing config value' @('budget',$beforePath,$afterPath,'--config') 2)
[void](Invoke-BudgetCase 'bad format' ($argsBase + @('--format','xml')) 2)
[void](Invoke-BudgetCase 'missing config file' @('budget',$beforePath,$afterPath,'--config',(Join-Path $fixtures 'missing.json')) 2)
foreach ($bad in @('{}','{"limits":{}}','{"limits":null}','{"rules":{}}','{"schema_version":2,"limits":{"max_output_growth_bytes":0}}','{"limits":{"max_total_output_bytes":0}}','{"limits":{"max_output_growth_bytes":-1}}','{"limits":{"max_output_growth_bytes":0.5}}','{"limits":{"max_output_growth_bytes":2147483648}}','{"limits":{"max_output_growth_bytes":"0"}}','{"limits":{"max_output_growth_bytes":false}}','{"limits":{"max_output_growth_bytes":null}}','{')) {
  Set-Budget $bad
  [void](Invoke-BudgetCase 'invalid config' $argsBase 2)
}
Set-Budget (' ' * 1048577)
[void](Invoke-BudgetCase 'oversized config' $argsBase 2)
Set-Budget '{"limits":{"max_notebook_growth_bytes":2147483647}}'
[void](Invoke-BudgetCase 'maximum allowance accepted' $argsBase)
$badInput = Join-Path $fixtures 'bad.ipynb'
[IO.File]::WriteAllText($badInput,'{}',$utf8)
[void](Invoke-BudgetCase 'invalid before' @('budget',$badInput,$afterPath,'--config',$configPath) 2)
[void](Invoke-BudgetCase 'invalid after' @('budget',$beforePath,$badInput,'--config',$configPath) 2)
[void](Invoke-BudgetCase 'missing notebook' @('budget',$beforePath,(Join-Path $fixtures 'missing.ipynb'),'--config',$configPath) 2)
$future = Join-Path $fixtures 'future.ipynb'
[IO.File]::WriteAllText($future,(Get-Content $afterPath -Raw).Replace('"nbformat_minor":5','"nbformat_minor":6'),$utf8)
[void](Invoke-BudgetCase 'unverified format' @('budget',$beforePath,$future,'--config',$configPath) 2)
$empty = Join-Path $fixtures 'empty.ipynb'
[IO.File]::WriteAllText($empty,'{"nbformat":4,"nbformat_minor":0,"metadata":{},"cells":[]}',$utf8)
Set-Budget '{"limits":{"max_notebook_growth_bytes":0}}'
[void](Invoke-BudgetCase 'empty to new blocked' @('budget',$empty,$afterPath,'--config',$configPath) 1)
[void](Invoke-BudgetCase 'all cells removed passes' @('budget',$afterPath,$empty,'--config',$configPath))
$ambiguous = Join-Path $fixtures 'ambiguous.ipynb'
$duplicate = @{cell_type='raw';source='same';metadata=@{}}
[IO.File]::WriteAllText($ambiguous,(@{nbformat=4;nbformat_minor=4;metadata=@{};cells=@($duplicate,$duplicate)} | ConvertTo-Json -Depth 20 -Compress),$utf8)
$r = (Invoke-BudgetCase 'ambiguity retained global budget passes' @('budget',$ambiguous,$ambiguous,'--config',$configPath,'--format','json')) | ConvertFrom-Json
if ($r.status -ne 'passed' -or $r.comparison.ambiguous_before.Count -ne 2 -or $r.comparison.cells.Count -ne 4) { throw 'ambiguity hidden' }
[void](Invoke-BudgetCase 'cannot write directory' ($argsBase + @('--output',$fixtures)) 2)
[void](Invoke-BudgetCase 'publication policy is not a budget' @('budget',$beforePath,$afterPath,'--config',(Join-Path $root 'configs/sharing.json')) 2)
[void](Invoke-BudgetCase 'budget is not a publication policy' @('check',$afterPath,'--config',$configPath) 2)
Write-Output "Budget CLI integration: $script:passed passed"
Write-Output "Fixtures retained in: $fixtures"
