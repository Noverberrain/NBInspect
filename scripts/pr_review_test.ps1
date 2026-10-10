#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$exe = Join-Path $root '_build/native/debug/build/cmd/nbinspect/nbinspect.exe'
$fixtures = Join-Path $root ('_build/pr-fixtures-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtures) | Out-Null
$repo = Join-Path $fixtures '仓库 with spaces'
[IO.Directory]::CreateDirectory($repo) | Out-Null
$script:passed = 0
function Run-Process([string]$program,[string[]]$arguments,[string]$directory) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.Environment['GIT_CEILING_DIRECTORIES']=Split-Path $fixtures
  $psi.Environment['GIT_CONFIG_NOSYSTEM']='1'
  $psi.Environment['GIT_CONFIG_GLOBAL']=Join-Path $fixtures 'global.config'
  $psi.FileName=$program; $psi.WorkingDirectory=$directory
  $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
  $psi.StandardOutputEncoding=[Text.Encoding]::UTF8; $psi.StandardErrorEncoding=[Text.Encoding]::UTF8
  foreach ($argument in $arguments) {[void]$psi.ArgumentList.Add($argument)}
  $p=[Diagnostics.Process]::new(); $p.StartInfo=$psi
  [void]$p.Start()
  $stdoutTask=$p.StandardOutput.ReadToEndAsync(); $stderrTask=$p.StandardError.ReadToEndAsync()
  if (!$p.WaitForExit(60000)) {$p.Kill($true); throw 'Test child timed out'}
  $result=@{code=$p.ExitCode; stdout=$stdoutTask.GetAwaiter().GetResult(); stderr=$stderrTask.GetAwaiter().GetResult()}
  $p.Dispose(); return $result
}
function Git([string[]]$arguments) {
  $r=Run-Process 'git' $arguments $repo
  if ($r.code -ne 0) {throw "Git fixture failed: $($r.stderr)"}
  return $r.stdout.Trim()
}
function Save-Notebook([string]$name,[string]$tag,[bool]$risk=$false,[bool]$modified=$false) {
  $source=@(1..30 | ForEach-Object {"$tag line $_ uniquely identifies this notebook`n"})
  if ($modified) {$source += "one additional line"}
  $outputs=@()
  if ($risk) {$outputs=@(@{output_type='error'; ename='Demo'; evalue='saved failure'; traceback=@()})}
  $value=@{nbformat=4; nbformat_minor=5; metadata=@{kernelspec=@{}; language_info=@{}};
    cells=@(@{cell_type='code';id='a';metadata=@{};source=$source;execution_count=$null;outputs=$outputs})}
  [IO.File]::WriteAllText((Join-Path $repo $name),($value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}


[IO.File]::WriteAllText((Join-Path $fixtures 'global.config'),'')
$driver=Join-Path $root 'scripts/pr_review.ps1'
$pwsh=Join-Path $PSHOME 'pwsh.exe'
$policy=Join-Path $fixtures 'policy.json'; [IO.File]::WriteAllText($policy,'{"fail_on":"warning"}')
function Commit([string]$message) { [void](Git @('add','--all')); [void](Git @('commit','-m',$message)); return Git @('rev-parse','HEAD') }
function Equal($actual,$expected,[string]$label) {if ($actual -ne $expected) {throw "$label expected $expected got $actual"}}
function Review([string]$base,[string]$head,[int]$expected=0,[string[]]$extra=@(),[string]$binary=$exe) {
  $directory=Join-Path $fixtures ('reports-'+[Guid]::NewGuid().ToString('N'))
  $summary=Join-Path $fixtures ('summary-'+[Guid]::NewGuid().ToString('N')+'.md')
  $r=Run-Process $pwsh (@('-NoProfile','-File',$driver,'-Executable',$binary,'-Repository',$repo,'-BaseCommit',$base,'-HeadCommit',$head,'-ReportDirectory',$directory,'-StepSummary',$summary)+$extra) $root
  if ($r.code -ne $expected) {throw "Expected $expected got $($r.code): $($r.stdout) $($r.stderr)"}
  if (($r.stdout+$r.stderr).Contains('::error::payload')) {throw 'Notebook data leaked into workflow commands'}
  $script:passed++
  $step=[IO.File]::ReadAllText($summary)
  if (Test-Path (Join-Path $directory 'summary.md')) {Equal ([IO.File]::ReadAllText((Join-Path $directory 'summary.md'))) $step 'artifact/job summary parity'}
  return @{directory=$directory; summary=$step; result=$r}
}
function Reports($run,[string]$state) {
  $value=Get-Content (Join-Path $run.directory 'review.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
  Equal $value.status $state 'report state'
  if (!$run.summary.Contains("Status: **$state**")) {throw 'summary missing review state'}
  $html=[IO.File]::ReadAllText((Join-Path $run.directory 'review.html'))
  if (!$html.StartsWith('<!doctype html>')) {throw 'missing offline HTML'}
  return $value
}
[void](Git @('init','-b','main'))
[void](Git @('config','user.name','NBInspect fixture'))
[void](Git @('config','user.email','fixture@example.invalid'))
Save-Notebook '课程 '' &.ipynb' 'first'
Save-Notebook 'existing.ipynb' 'existing' $true
$base=Commit 'fixture base'
$r=Review $base $base
$value=Reports $r 'passed'; Equal $value.summary.files 0 'no Notebook changes pass'
Save-Notebook '课程 '' &.ipynb' 'first' $true
$head=Commit 'fixture risk'
$r=Review $base $head 1 @('-Config',$policy)
$value=Reports $r 'blocked'; Equal $value.summary.introduced 1 'new risk count'; Equal $value.summary.blocked 1 'blocking file count'
Equal ([IO.File]::ReadAllText((Join-Path $r.directory 'policy.json'))) ([IO.File]::ReadAllText($policy)) 'policy snapshot'
Equal $value.base_commit $base 'base identity'; Equal $value.head_commit $head 'head identity'
if (![IO.File]::ReadAllText((Join-Path $r.directory 'review.html')).Contains('课程 &#39; &amp;.ipynb')) {throw 'Notebook filename not escaped in HTML'}
$r=Review $base $head
[void](Reports $r 'passed')
$r=Review $base $head 0 @('-Config',$policy,'-FailOn','error')
$value=Reports $r 'passed'; Equal $value.policy.fail_on 'error' 'explicit override'
# Unchanged old risk remains visible but never becomes a new blocker.
Save-Notebook 'existing.ipynb' 'existing' $true $true
$existing=Commit 'fixture existing risk'
$r=Review $head $existing 0 @('-Config',$policy)
$value=Reports $r 'passed'; Equal $value.summary.existing 1 'existing risk inherited'; Equal $value.summary.introduced 0 'existing not introduced'
# Incomplete analysis still produces JSON and HTML and fails the check.
[IO.File]::WriteAllText((Join-Path $repo 'broken.ipynb'),'{')
Save-Notebook 'valid-new.ipynb' 'valid-new'
$broken=Commit 'fixture invalid input'
$r=Review $existing $broken 2 @('-Config',$policy)
$value=Reports $r 'incomplete'; Equal $value.summary.errors 1 'invalid Notebook retained'; Equal $value.summary.passed 1 'valid Notebook retained'
# Terminal Git/config errors retain logs and an explicit failure summary.
$r=Review ('f'*40) $head 2
if (!$r.summary.Contains('Analysis failed') -or !(Test-Path (Join-Path $r.directory 'json.stderr.log')) -or !(Test-Path (Join-Path $r.directory 'run-error.txt'))) {throw 'Git failure lacks diagnostics'}
$invalidPolicy=Join-Path $fixtures 'invalid.json'; [IO.File]::WriteAllText($invalidPolicy,'{"rules":{"UNKNOWN":{}}}')
$r=Review $base $head 2 @('-Config',$invalidPolicy)
if (!$r.summary.Contains('Analysis failed')) {throw 'invalid policy falsely passed'}
[void](Review 'HEAD~1' $head 2)
[void](Review 'HEAD; echo injected' $head 2)
$r=Review $base $head 2 @('-Config',(Join-Path $fixtures 'missing.json'))
if (!$r.summary.Contains('Analysis failed')) {throw 'missing policy falsely passed'}
[void](Review $base $head 2 @() (Join-Path $fixtures 'missing.exe'))
# An existing output directory must remain byte-for-byte untouched.
$directory=Join-Path $fixtures 'existing reports'; [void][IO.Directory]::CreateDirectory($directory)
$sentinel=Join-Path $directory 'summary.md'; [IO.File]::WriteAllText($sentinel,'keep original')
$r=Run-Process $pwsh @('-NoProfile','-File',$driver,'-Executable',$exe,'-Repository',$repo,'-BaseCommit',$base,'-HeadCommit',$head,'-ReportDirectory',$directory,'-StepSummary','') $root
Equal $r.code 2 'existing reports rejected'; Equal ([IO.File]::ReadAllText($sentinel)) 'keep original' 'existing output preserved'; $script:passed++
# Report failures cannot silently succeed when the GitHub summary is unwritable.
$directory=Join-Path $fixtures 'bad-summary reports'
$r=Run-Process $pwsh @('-NoProfile','-File',$driver,'-Executable',$exe,'-Repository',$repo,'-BaseCommit',$base,'-HeadCommit',$base,'-ReportDirectory',$directory,'-StepSummary',$fixtures) $root
Equal $r.code 2 'summary write failure blocks'; $script:passed++
# Event SHA commits are used directly, without executing PR source files.
[void](Git @('reset','--hard',$base))
[void](Git @('checkout','-b','pr-fork'))
Save-Notebook 'fork.ipynb' 'fork' $true
[IO.File]::WriteAllText((Join-Path $repo 'must-not-run.ps1'),"throw 'PR source executed'")
$forkHead=Commit 'fixture fork head'
[void](Git @('update-ref','refs/pull/7/head',$forkHead))
[void](Git @('checkout','main'))
Save-Notebook 'base-only.ipynb' 'base-only'
$newBase=Commit 'fixture advanced base'
$r=Review $newBase $forkHead 1 @('-Config',$policy)
$value=Reports $r 'blocked'; Equal $value.summary.deleted 1 'two endpoint comparison, not merge-base'; Equal $value.summary.introduced 1 'fork risk reviewed'
# Malicious output stays escaped in offline HTML and out of summary/log command syntax.
[void](Git @('checkout','pr-fork'))
$f=Join-Path $repo 'fork.ipynb'; [IO.File]::WriteAllText($f,[IO.File]::ReadAllText($f).Replace('saved failure','<script>alert(1)</script> ::error::payload'))
$malicious=Commit 'fixture output text'
$r=Review $forkHead $malicious 1 @('-Config',$policy)
$html=[IO.File]::ReadAllText((Join-Path $r.directory 'review.html'))
if ($html.Contains('<script>')) {throw 'unsafe HTML content'}
if ($r.summary.Contains('payload')) {throw 'untrusted content entered job summary'}
# Static template checks run in CI without requiring an extra YAML parser dependency.
$template=[IO.File]::ReadAllText((Join-Path $root 'templates/github-actions/notebook-review.yml'))
foreach ($required in @('pull_request:','contents: read','fetch-depth: 0','persist-credentials: false','if: always()','github.event.pull_request.base.sha','github.event.pull_request.head.sha','./trusted/.github/nbinspect/pr_review.ps1','working-directory: analyzer','retention-days: 14')) {
 if (!$template.Contains($required)) {throw "Missing workflow contract: $required"}
}
if ($template.Contains('pull_request_target:') -or $template.Contains('continue-on-error:') -or $template.Contains('pull-requests: write')) {throw 'unexpected workflow privileges or failure masking'}
$uses=[regex]::Matches($template,'uses:\s*([^\s]+)')
foreach ($use in $uses) {if ($use.Groups[1].Value -notmatch '@[a-f0-9]{40}$') {throw 'Action is not pinned to a full SHA'}}
if ($template -notmatch 'repository: Noverberrain/NBInspect\s+ref: [a-f0-9]{40}') {throw 'Analyzer is not pinned'}
$script:passed++
Write-Output "PR review integration: $script:passed passed (native reports, exits, job summary, failure artifacts, fork endpoints, workflow contract)"
Write-Output "Fixtures retained in: $fixtures"
