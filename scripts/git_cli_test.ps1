#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$exe = Join-Path $root '_build/native/debug/build/cmd/nbinspect/nbinspect.exe'
$fixtures = Join-Path $root ('_build/git-fixtures-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtures) | Out-Null
$repo = Join-Path $fixtures '仓库 with spaces'
[IO.Directory]::CreateDirectory($repo) | Out-Null
$script:passed = 0
function Run-Process([string]$program,[string[]]$arguments,[string]$directory) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
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
function Commit([string]$message) { [void](Git @('add','--all')); [void](Git @('commit','-m',$message)); return Git @('rev-parse','HEAD') }
function Review([string[]]$arguments,[int]$expected=0,[bool]$json=$true,[string]$directory=$repo,[string]$errorText='') {
  $r=Run-Process $exe $arguments $directory
  if ($r.code -ne $expected) {throw "Expected $expected got $($r.code): $($r.stderr)"}
  if ($expected -eq 2 -and $errorText) {
    if ($r.stdout -or !$r.stderr.Contains($errorText)) {throw "Unexpected error channel: $($r.stdout) $($r.stderr)"}
  } elseif ($r.stderr) {throw "Unexpected stderr: $($r.stderr)"}
  $script:passed++
  if ($json) {return $r.stdout | ConvertFrom-Json -Depth 100}
  return $r.stdout
}
function Equal($actual,$expected,[string]$label) {if ($actual -ne $expected) {throw "$label expected $expected got $actual"}}
[void](Git @('init','-b','main'))
[void](Git @('config','user.name','NBInspect fixture'))
[void](Git @('config','user.email','fixture@example.invalid'))
Save-Notebook 'modified.ipynb' 'modify'
Save-Notebook 'deleted.ipynb' 'delete'
Save-Notebook "旧 name '&.ipynb" 'rename' $true
Save-Notebook 'rename-edit-old.ipynb' 'rename-edit' $true
Save-Notebook 'enter.txt' 'enter'
Save-Notebook 'leave.ipynb' 'leave'
Save-Notebook 'unchanged.ipynb' 'unchanged' $true
$base=Commit 'fixture base'
Save-Notebook 'modified.ipynb' 'modify' $true
[IO.File]::Delete((Join-Path $repo 'deleted.ipynb'))
[IO.File]::Move((Join-Path $repo "旧 name '&.ipynb"),(Join-Path $repo "new & '中文.ipynb"))
[IO.File]::Delete((Join-Path $repo 'rename-edit-old.ipynb'))
Save-Notebook 'rename-edit-new.ipynb' 'rename-edit' $true $true
Save-Notebook 'added.ipynb' 'added' $true
[IO.File]::Move((Join-Path $repo 'enter.txt'),(Join-Path $repo 'enter.IPYNB'))
[IO.File]::Move((Join-Path $repo 'leave.ipynb'),(Join-Path $repo 'leave.txt'))
$head=Commit 'fixture notebook changes'
[void](Git @('branch','baseline',$base))
[void](Git @('tag','审阅版本',$head))
$r=Review @('review-git','baseline','审阅版本','--format','json')
Equal $r.base_ref 'baseline' 'branch input preserved'
Equal $r.head_ref '审阅版本' 'Unicode tag input preserved'
Equal $r.head_commit $head 'tag resolved to commit'
$policy=Join-Path $fixtures 'rules.json'
[IO.File]::WriteAllText($policy,'{"fail_on":"warning"}')
$r=Review @('review-git',$base,$head,'--format','json','--config',$policy) 1
Equal $r.kind 'git-review' 'report kind'
Equal $r.base_commit $base 'base commit'; Equal $r.head_commit $head 'head commit'
Equal $r.summary.files 7 'notebook count'
Equal $r.summary.added 2 'added count'; Equal $r.summary.deleted 2 'deleted count'
Equal $r.summary.renamed 2 'rename count'; Equal $r.summary.modified 1 'modified count'
Equal $r.summary.introduced 2 'introduced risks'; Equal $r.summary.existing 2 'existing risks'
Equal $r.summary.blocked 2 'blocking files'
Equal @($r.files | Where-Object path -eq 'unchanged.ipynb').Count 0 'unchanged excluded'
Equal @($r.files | Where-Object change -eq 'renamed' | Where-Object status -eq 'blocked').Count 0 'existing rename does not block'
$baselineJson=$r | ConvertTo-Json -Depth 100 -Compress
[IO.File]::WriteAllText((Join-Path $repo 'modified.ipynb'),'{')
[IO.File]::WriteAllText((Join-Path $repo 'untracked.ipynb'),'{')
$statusBefore=Git @('status','--porcelain=v1')
$r=Review @('review-git',$base,$head,'--format','json','--config',$policy) 1
Equal ($r | ConvertTo-Json -Depth 100 -Compress) $baselineJson 'working tree ignored'
Equal (Git @('status','--porcelain=v1')) $statusBefore 'working tree not changed'
$r=Review @('review-git',$base,$head,'--format','json','--config',$policy,'--fail-on','error')
Equal $r.policy.fail_on 'error' 'CLI threshold override'
$r=Review @('review-git',$base,$head,'--format','json')
Equal $r.status 'passed' 'default threshold'
$r=Review @('review-git',$head,$head,'--format','json')
Equal $r.summary.files 0 'empty changes'
$r=Review @('review-git',$base,$head,'--format','text') 0 $false
if (!$r.Contains('Git') -and !$r.Contains('git-review')) {throw 'text missing Git report'}
$r=Review @('review-git',$base,$head,'--format','html') 0 $false
if (!$r.Contains('Matching evidence') -or !$r.Contains('new &amp; &#39;中文.ipynb')) {throw 'HTML matching/escaped filename missing'}
$jsonFile=Join-Path $fixtures 'report.json'; $htmlFile=Join-Path $fixtures 'report.html'
[void](Review @('review-git',$base,$head,'--format','json','--output',$jsonFile) 0 $false)
Equal ((Get-Content $jsonFile -Raw -Encoding utf8 | ConvertFrom-Json).head_commit) $head 'JSON output file'
[void](Review @('review-git',$base,$head,'--format','html','--output',$htmlFile) 0 $false)
[void](Review @('review-git',$base,$head,'--format','html','--output',$htmlFile) 2 $false $repo 'cannot write')
[void](Review @('review-git',$base,$head,'--config',$policy,'--output',$policy) 2 $false $repo 'cannot overwrite')
[void](Review @('review-git','does-not-exist',$head) 2 $false $repo 'Git command failed')
[void](Review @('review-git',"HEAD; echo injected",$head) 2 $false $repo 'Git command failed')
[void](Review @('review-git',($base+':modified.ipynb'),$head) 2 $false $repo 'Git command failed')
[void](Review @('review-git','',$head) 2 $false $repo 'empty Git commit reference')
[void](Review @('review-git',$base) 2 $false $repo 'wrong number')
[void](Review @('review-git',$base,$head,'--view','code') 2 $false $repo 'diff options')
[void](Review @('review-git',$base,$head,'--exit-code') 2 $false $repo 'diff options')
[void](Review @('review-git',$base,$head,'--recursive') 2 $false $repo 'recursive')
[void](Review @('review-git',$base,$head) 2 $false $fixtures 'Git command failed')
$subdir=Join-Path $repo 'subdir'; [IO.Directory]::CreateDirectory($subdir) | Out-Null
$r=Review @('review-git',$base,$head,'--format','json') 0 $true $subdir
Equal $r.summary.files 7 'subdirectory full repository diff'
[void](Git @('config','diff.relative','true'))
$r=Review @('review-git',$base,$head,'--format','json') 0 $true $subdir
Equal $r.summary.files 7 'relative config cannot hide files'
[void](Git @('config','diff.external','nonexistent-nbinspect-command'))
$r=Review @('review-git',$base,$head,'--format','json')
Equal $r.summary.files 7 'external diff disabled'
# Add broken/unsupported/special entries while retaining valid results.
[IO.File]::WriteAllText((Join-Path $repo 'malformed.ipynb'),'{')
[IO.File]::WriteAllBytes((Join-Path $repo 'utf8.ipynb'),[byte[]](255,254,255))
Save-Notebook 'unsupported.ipynb' 'unsupported'
$f=Join-Path $repo 'unsupported.ipynb'
[IO.File]::WriteAllText($f,[IO.File]::ReadAllText($f).Replace('"nbformat_minor": 5','"nbformat_minor": 6'))
[void](Git @('add','--all'))
$blob=Git @('hash-object','-w','--stdin') # Empty blob used as a symlink entry; not followed.
[void](Git @('update-index','--add','--cacheinfo',("120000,$blob,link.ipynb")))
[void](Git @('update-index','--add','--cacheinfo',("160000,$base,module.ipynb")))
[void](Git @('commit','-m','fixture invalid entries'))
$partial=Git @('rev-parse','HEAD')
$r=Review @('review-git',$head,$partial,'--format','json') 2
Equal $r.status 'incomplete' 'partial failure state'
Equal $r.summary.unsupported 1 'unsupported preserved'
if ($r.summary.errors -lt 4) {throw 'special/invalid inputs were not rejected'}
# The previously dirty modified.ipynb is committed here and must now be an error.
if (@($r.files | Where-Object path -eq 'modified.ipynb' | Where-Object status -eq 'error').Count -ne 1) {throw 'committed corruption not checked'}
$large=Join-Path $repo 'oversized.ipynb'
$stream=[IO.File]::Create($large); $stream.SetLength(52428801); $stream.Dispose()
$largeHead=Commit 'fixture oversized blob'
$r=Review @('review-git',$partial,$largeHead,'--format','json') 2
$largeResult=@($r.files | Where-Object path -eq 'oversized.ipynb')
if ($largeResult.Count -ne 1 -or !$largeResult[0].error.Contains('byte limit')) {throw 'blob byte cap not enforced'}
$sha256=Join-Path $fixtures 'sha256'; [IO.Directory]::CreateDirectory($sha256) | Out-Null
$probe=Run-Process 'git' @('init','--object-format=sha256','-b','main') $sha256
if ($probe.code -eq 0) {
  $originalRepo=$repo; $repo=$sha256
  [void](Git @('config','user.name','NBInspect fixture')); [void](Git @('config','user.email','fixture@example.invalid'))
  Save-Notebook 'one.ipynb' 'sha256'
  $first=Commit 'sha256 base'
  Save-Notebook 'one.ipynb' 'sha256' $true
  $second=Commit 'sha256 risk'
  $r=Review @('review-git',$first,$second,'--format','json','--config',$policy) 1
  Equal $r.head_commit.Length 64 'SHA256 commit ID'
  Equal $r.files[0].after_blob.Length 64 'SHA256 blob ID'
  $repo=$originalRepo
}
Write-Output "Git review CLI integration: $script:passed passed"
Write-Output "Fixtures retained in: $fixtures"
