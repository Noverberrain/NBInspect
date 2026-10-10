#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$exe = Join-Path $root '_build/native/debug/build/cmd/nbinspect/nbinspect.exe'
$fixtures = Join-Path $root ('_build/hook-fixtures-' + [Guid]::NewGuid().ToString('N'))
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
$manager=Join-Path $root 'scripts/git_hook.ps1'
$pwsh=Join-Path $PSHOME 'pwsh.exe'
$toolDir=Join-Path $fixtures '工具 '' & $()'; [void][IO.Directory]::CreateDirectory($toolDir)
$binary=Join-Path $toolDir 'NBInspect '' & $().exe'; [IO.File]::Copy($exe,$binary)
function Expect($result,[int]$code,[string]$message='') {
  if ($result.code -ne $code -or ($message -and !($result.stdout+$result.stderr).Contains($message))) {
    throw "Expected $code / $message; got $($result.code): $($result.stdout) $($result.stderr)"
  }
  $script:passed++
}
function Manage([string[]]$arguments,[int]$code=0,[string]$message='') {
  $r=Run-Process $pwsh (@('-NoProfile','-File',$manager,'-Repository',$repo)+$arguments) $fixtures
  Expect $r $code $message
  return $r
}
function Commit-Result([string[]]$arguments,[int]$code=0,[string]$message='') {
  $r=Run-Process 'git' (@('commit')+$arguments) $repo
  Expect $r $code $message
  return $r
}
function Equal($actual,$expected,[string]$message) {if ($actual -ne $expected) {throw "$message expected $expected got $actual"}}
[void](Git @('init','-b','main'))
[void](Git @('config','user.name','NBInspect fixture'))
[void](Git @('config','user.email','fixture@example.invalid'))
$policy=Join-Path $repo '规则 '' & $().json'
[IO.File]::WriteAllText($policy,'{"fail_on":"warning"}')
$hook=Join-Path $repo '.git/hooks/pre-commit'
$postHook=Join-Path $repo '.git/hooks/post-commit'
[IO.File]::WriteAllText($postHook,"#!/bin/sh`nexit 0`n",[Text.UTF8Encoding]::new($false))
$configBefore=(Get-FileHash (Join-Path $repo '.git/config')).Hash
[void](Manage @('-Action','Install','-Executable',$binary,'-Config',(Split-Path $policy -Leaf)) 0 'Installed')
$installed=[IO.File]::ReadAllBytes($hook)
Equal $installed[0] 35 'no UTF8 BOM'
if ([Text.Encoding]::UTF8.GetString($installed).Contains("`r")) {throw 'hook must use LF'}
[void](Manage @('-Action','Install','-Executable',$binary,'-Config',(Split-Path $policy -Leaf)) 0 'already installed')
Equal (Get-FileHash (Join-Path $repo '.git/config')).Hash $configBefore 'Git configuration untouched'
[void](Manage @('-Action','Install','-Executable',$binary,'-FailOn','error') 2 'different settings')
Equal ([Convert]::ToHexString([IO.File]::ReadAllBytes($hook))) ([Convert]::ToHexString($installed)) 'different settings do not overwrite'
# First commit risk blocks and preserves the staged blob; shell metacharacters are literal.
Save-Notebook 'first.ipynb' 'first' $true
[void](Git @('add','--','first.ipynb'))
$stagedBlob=Git @('rev-parse',':first.ipynb')
[void](Commit-Result @('-m','blocked first commit') 1 'Staged: empty tree (first commit)')
if (Test-Path (Join-Path $repo '.git/refs/heads/main')) {throw 'blocked first commit created HEAD'}
Equal (Git @('rev-parse',':first.ipynb')) $stagedBlob 'blocked commit keeps staged blob'
Save-Notebook 'first.ipynb' 'first'
[void](Git @('add','--','first.ipynb'))
[void](Commit-Result @('-m','clean first commit') 0 'Staged:')
$base=Git @('rev-parse','HEAD')
# Unstaged risk does not block committing the clean staged version.
Save-Notebook 'first.ipynb' 'first' $false $true
[void](Git @('add','--','first.ipynb'))
$cleanBlob=Git @('rev-parse',':first.ipynb')
Save-Notebook 'first.ipynb' 'first' $true $true
[void](Commit-Result @('-m','partial staging') 0 'Staged:')
Equal (Git @('rev-parse','HEAD:first.ipynb')) $cleanBlob 'commits clean staged content'
# commit --only exposes a temporary index which the hook must inherit.
[void](Git @('add','--','first.ipynb'))
[IO.File]::WriteAllText((Join-Path $repo 'notes.txt'),'safe non-notebook content')
[void](Git @('add','--','notes.txt'))
[void](Commit-Result @('--only','notes.txt','-m','only safe notes') 0 'Staged:')
$base=Git @('rev-parse','HEAD')
[void](Commit-Result @('-m','blocked saved error') 1 'blocked')
Equal (Git @('rev-parse','HEAD')) $base 'blocked commit preserves HEAD'
[void](Commit-Result @('--only','first.ipynb','-m','blocked only Notebook') 1 'blocked')
Equal (Git @('rev-parse','HEAD')) $base 'only Notebook failure preserves HEAD'
# Git supports an explicit bypass; later unchanged old risks do not block.
[void](Commit-Result @('--no-verify','-m','fixture existing risk'))
Save-Notebook 'first.ipynb' 'first' $true $true
# A new source line changes the blob while the saved error stays the same.
$f=Join-Path $repo 'first.ipynb'; [IO.File]::WriteAllText($f,[IO.File]::ReadAllText($f).Replace('one additional line','another additional line'))
[void](Git @('add','--','first.ipynb'))
[void](Commit-Result @('-m','existing risk') 0 'existing')
# Missing executable/config and invalid policy block rather than silently pass.
[IO.File]::WriteAllText((Join-Path $repo 'notes.txt'),'new note')
[void](Git @('add','--','notes.txt'))
[IO.File]::Move($binary,$binary+'.away')
try { [void](Commit-Result @('-m','missing binary') 1) } finally { [IO.File]::Move($binary+'.away',$binary) }
[IO.File]::Move($policy,$policy+'.away')
try { [void](Commit-Result @('-m','missing config') 1 'cannot read') } finally { [IO.File]::Move($policy+'.away',$policy) }
[IO.File]::WriteAllText($policy,'{"rules":{"UNKNOWN":{}}}')
[void](Commit-Result @('-m','invalid config') 1 'config')
[IO.File]::WriteAllText($policy,'{"fail_on":"warning"}')
[void](Commit-Result @('-m','valid config restored') 0 'Staged:')
# Invalid staged Notebook data also blocks an actual commit.
[IO.File]::WriteAllText((Join-Path $repo 'broken.ipynb'),'{')
[void](Git @('add','--','broken.ipynb'))
$beforeBroken=Git @('rev-parse','HEAD')
[void](Commit-Result @('-m','broken notebook') 1 'incomplete')
Equal (Git @('rev-parse','HEAD')) $beforeBroken 'invalid Notebook preserves HEAD'
[void](Git @('reset','--','broken.ipynb'))
# Modified and foreign hooks are preserved by both install and uninstall.
[IO.File]::AppendAllText($hook,"# local change`n",[Text.UTF8Encoding]::new($false))
$modifiedHash=(Get-FileHash $hook).Hash
[void](Manage @('-Action','Uninstall') 2 'foreign or modified')
[void](Manage @('-Action','Install','-Executable',$binary) 2 'foreign or modified')
Equal (Get-FileHash $hook).Hash $modifiedHash 'modified hook preserved'
[IO.File]::WriteAllBytes($hook,$installed)
[void](Manage @('-Action','Uninstall') 0 'Removed')
if (Test-Path $hook) {throw 'uninstall did not remove own hook'}
Equal ([IO.File]::ReadAllText($postHook)) "#!/bin/sh`nexit 0`n" 'other hooks preserved'
[void](Manage @('-Action','Uninstall') 0 'not installed')
[IO.File]::WriteAllText($hook,"#!/bin/sh`n# user hook`nexit 0`n",[Text.UTF8Encoding]::new($false))
$foreignHash=(Get-FileHash $hook).Hash
[void](Manage @('-Action','Install','-Executable',$binary) 2 'foreign or modified')
[void](Manage @('-Action','Uninstall') 2 'foreign or modified')
Equal (Get-FileHash $hook).Hash $foreignHash 'foreign hook preserved'
[IO.File]::Delete($hook)
# core.hooksPath is detected without changing the existing hook framework.
[void](Git @('config','core.hooksPath','custom-hooks'))
[void](Manage @('-Action','Install','-Executable',$binary) 2 'core.hooksPath')
[void](Manage @('-Action','Uninstall') 2 'core.hooksPath')
Equal (Git @('config','--get','core.hooksPath')) 'custom-hooks' 'hooksPath preserved'
[void](Git @('config','--unset','core.hooksPath'))
[IO.File]::WriteAllText((Join-Path $fixtures 'global.config'),"[core]`n hooksPath = global-hooks`n")
[void](Manage @('-Action','Install','-Executable',$binary) 2 'core.hooksPath')
[IO.File]::WriteAllText((Join-Path $fixtures 'global.config'),'')
$previousIndex=$env:GIT_INDEX_FILE
$env:GIT_INDEX_FILE=Join-Path $fixtures 'alternate-index'
try { [void](Manage @('-Action','Install','-Executable',$binary) 2 'Unset GIT_INDEX_FILE') }
finally { $env:GIT_INDEX_FILE=$previousIndex }
# Explicit fail-on overrides the policy; default install has no implicit override.
[void](Manage @('-Action','Install','-Executable',$binary,'-Config',$policy,'-FailOn','error'))
Save-Notebook 'new.ipynb' 'new' $true
[void](Git @('add','--','new.ipynb'))
[void](Commit-Result @('-m','explicit error threshold') 0 'Staged:')
[void](Manage @('-Action','Uninstall'))
[void](Manage @('-Action','Install','-Executable',$binary))
Save-Notebook 'default.ipynb' 'default' $true
[void](Git @('add','--','default.ipynb'))
[void](Commit-Result @('-m','default policy') 0 'Staged:')
# Default hooks are shared with linked worktrees; installation/removal resolve common dir.
$linked=Join-Path $fixtures 'linked 中文'
[void](Git @('worktree','add','-b','linked',$linked))
$primaryRepo=$repo; $repo=$linked
[void](Manage @('-Action','Install','-Executable',$binary) 0 'already installed')
Save-Notebook 'linked.ipynb' 'linked'
[void](Git @('add','--','linked.ipynb'))
[void](Commit-Result @('-m','linked worktree') 0 'Staged:')
# Uninstall works even if the old binary is unavailable.
[IO.File]::Move($binary,$binary+'.away')
try { [void](Manage @('-Action','Uninstall') 0 'Removed') } finally { [IO.File]::Move($binary+'.away',$binary) }
$repo=$primaryRepo
if (Test-Path $hook) {throw 'shared hook not removed'}
[void](Manage @('-Action','Install','-Executable',(Join-Path $fixtures 'missing.exe')) 2)
if (Test-Path $hook) {throw 'invalid executable installed hook'}
[void](Manage @('-Action','Install','-Executable',$binary,'-Config','missing.json') 2)
if (Test-Path $hook) {throw 'invalid config path installed hook'}
# Directory entries are never overwritten or deleted.
[void][IO.Directory]::CreateDirectory($hook)
[void](Manage @('-Action','Install','-Executable',$binary) 2 'not an ordinary')
[void](Manage @('-Action','Uninstall') 2 'not an ordinary')
if (!(Test-Path $hook -PathType Container)) {throw 'hook directory modified'}
# Junctions are rejected without following or altering their targets.
[IO.Directory]::Delete($hook)
$linkTarget=Join-Path $fixtures 'foreign hook target'; [void][IO.Directory]::CreateDirectory($linkTarget)
$sentinel=Join-Path $linkTarget 'keep.txt'; [IO.File]::WriteAllText($sentinel,'preserve target')
[void](New-Item -ItemType Junction -Path $hook -Target $linkTarget)
[void](Manage @('-Action','Install','-Executable',$binary) 2 'not an ordinary')
[void](Manage @('-Action','Uninstall') 2 'not an ordinary')
Equal ([IO.File]::ReadAllText($sentinel)) 'preserve target' 'junction target preserved'
$repo=$fixtures
[void](Manage @('-Action','Install','-Executable',$binary) 2 'Git query failed')
Write-Output "Git hook integration: $script:passed passed (actual commits, first commit, partial/only staging, policy, quoted paths, existing hooks, worktrees)"
Write-Output "Fixtures retained in: $fixtures"
