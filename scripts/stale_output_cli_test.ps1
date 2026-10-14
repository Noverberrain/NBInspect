#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$exe = Join-Path $root '_build/native/debug/build/cmd/nbinspect/nbinspect.exe'
$fixtures = [IO.Directory]::CreateDirectory((Join-Path $root ('_build/stale-output-fixtures-' + [Guid]::NewGuid().ToString('N')))).FullName
$utf8 = [Text.UTF8Encoding]::new($false)
$script:passed = 0
function Invoke-StaleCase([string]$Name, [string[]]$Arguments, [int]$Expected = 0) {
  $psi = [Diagnostics.ProcessStartInfo]::new($exe)
  $psi.WorkingDirectory = (Get-Location).Path
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
$before=Join-Path $fixtures 'before.ipynb'
$after=Join-Path $fixtures 'after.ipynb'
$config=Join-Path $fixtures 'policy.json'
$stream=@{output_type='stream';name='stdout';text='same saved result'}
function Book([string]$source,[object[]]$outputs=@($stream),[bool]$id=$true) {
  $cell=@{cell_type='code';source=$source;metadata=@{};execution_count=1;outputs=$outputs}
  if ($id) {$cell.id='result'}
  return @{nbformat=4;nbformat_minor=$(if ($id) {5} else {4});metadata=@{kernelspec=@{};language_info=@{}};cells=@($cell)} | ConvertTo-Json -Depth 20 -Compress
}
function Save-After([string]$value) {[IO.File]::WriteAllText($after,$value,$utf8)}
function Policy([string]$value) {[IO.File]::WriteAllText($config,$value,$utf8)}
[IO.File]::WriteAllText($before,(Book 'print(value)'),$utf8)
Save-After (Book 'print(value + 1)')
$argsBase=@('review',$before,$after)
$r=(Invoke-StaleCase 'default info' ($argsBase+@('--format','json'))) | ConvertFrom-Json -Depth 100
$hint=@($r.changes | Where-Object {$_.after.code -eq 'OUT002'})
if ($hint.Count -ne 1 -or $hint[0].status -ne 'introduced' -or $hint[0].after.severity -ne 'info' -or $hint[0].evidence.before_source_path -ne '/cells/0/source') {throw 'incorrect stale output hint'}
[void](Invoke-StaleCase 'warning threshold passes info' ($argsBase+@('--fail-on','warning')))
[void](Invoke-StaleCase 'info threshold blocks hint' ($argsBase+@('--fail-on','info')) 1)
$text=Invoke-StaleCase 'text evidence' $argsBase
if (!$text.Contains('OUT002') -or !$text.Contains('Saved output evidence')) {throw 'missing text evidence'}
$html=Invoke-StaleCase 'HTML evidence' ($argsBase+@('--format','html'))
if (!$html.Contains('Saved output evidence') -or $html.Contains('same saved result')) {throw 'missing evidence or copied payload'}
$report=Join-Path $fixtures 'report.json'
[void](Invoke-StaleCase 'save full report' ($argsBase+@('--format','json','--output',$report)))
[void](Invoke-StaleCase 'preserve saved report' ($argsBase+@('--output',$report)) 2)
Policy '{"rules":{"OUT002":{"severity":"error"}}}'
[void](Invoke-StaleCase 'error severity blocks' ($argsBase+@('--config',$config)) 1)
[void](Invoke-StaleCase 'single check never guesses history' @('check',$after,'--config',$config))
Policy '{"rules":{"OUT002":{"severity":"warning"}}}'
[void](Invoke-StaleCase 'configured warning blocks' ($argsBase+@('--config',$config,'--fail-on','warning')) 1)
Policy '{"rules":{"OUT002":{"enabled":false}}}'
$r=(Invoke-StaleCase 'disabled rule' ($argsBase+@('--config',$config,'--format','json','--fail-on','info'))) | ConvertFrom-Json
if (@($r.changes | Where-Object {$_.after.code -eq 'OUT002'}).Count) {throw 'disabled rule emitted'}
[void](Invoke-StaleCase 'same source no hint' @('review',$before,$before,'--fail-on','info'))
Save-After (Book 'print(value + 1)' @())
[void](Invoke-StaleCase 'cleared outputs no hint' ($argsBase+@('--fail-on','info')))
Save-After (Book 'print(value + 1)' @(@{output_type='stream';name='stdout';text='different'}))
[void](Invoke-StaleCase 'changed outputs no hint' ($argsBase+@('--fail-on','info')))
[IO.File]::WriteAllText($before,(Book "setup`nload`ncompute`ncheck`nold" @($stream) $false),$utf8)
Save-After (Book "setup`nload`ncompute`ncheck`nnew" @($stream) $false)
Policy '{"rules":{"OUT002":{"severity":"error"}}}'
$r=(Invoke-StaleCase 'similarity remains uncertain' ($argsBase+@('--config',$config,'--format','json'))) | ConvertFrom-Json -Depth 100
$hint=@($r.changes | Where-Object {$_.after.code -eq 'OUT002'})
if ($hint.Count -ne 1 -or $hint[0].status -ne 'uncertain' -or $hint[0].evidence.match_basis -ne 'similarity') {throw 'uncertain match falsely blocked or missing'}
$repo=Join-Path $fixtures 'notebooks repo'; [IO.Directory]::CreateDirectory($repo) | Out-Null
Push-Location $repo
try {
  git init -b main | Out-Null; git config user.name 'NBInspect fixture'; git config user.email 'fixture@example.invalid'
  [IO.File]::WriteAllText((Join-Path $repo 'demo.ipynb'),(Book 'print(value)'),$utf8)
  git add --all; git commit -m base | Out-Null
  [IO.File]::WriteAllText((Join-Path $repo 'demo.ipynb'),(Book 'print(value + 1)'),$utf8)
  git add --all
  [void](Invoke-StaleCase 'staged risk review' @('review-git','--staged','--config',$config) 1)
  git commit -m changed | Out-Null
  [void](Invoke-StaleCase 'commit risk review' @('review-git','HEAD~1','HEAD','--config',$config) 1)
} finally {Pop-Location}
Write-Output "Stale output CLI integration: $script:passed passed"
Write-Output "Fixtures retained in: $fixtures"
