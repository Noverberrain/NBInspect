#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$exe = Join-Path $root '_build/native/debug/build/cmd/nbinspect/nbinspect.exe'
$fixtures = Join-Path $root ('_build/staged-fixtures-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtures) | Out-Null
$repo = Join-Path $fixtures '仓库 with spaces'
[IO.Directory]::CreateDirectory($repo) | Out-Null
$script:passed = 0
function Run-Process([string]$program,[string[]]$arguments,[string]$directory) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.Environment['GIT_CEILING_DIRECTORIES']=Split-Path $fixtures
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
  if ($r.code -ne $expected) {throw "Expected $expected got $($r.code) for $($arguments -join ' '): $($r.stderr) [passed=$script:passed]"}
  if ($expected -eq 2 -and $errorText) {
    if ($r.stdout -or !$r.stderr.Contains($errorText)) {throw "Unexpected error channel: $($r.stdout) $($r.stderr)"}
  } elseif ($r.stderr) {throw "Unexpected stderr: $($r.stderr)"}
  $script:passed++
  if ($json) {return $r.stdout | ConvertFrom-Json -Depth 100}
  return $r.stdout
}
function Equal($actual,$expected,[string]$label) {if ($actual -ne $expected) {throw "$label expected $expected got $actual"}}

$policy=Join-Path $fixtures 'rules.json'
[IO.File]::WriteAllText($policy,'{"fail_on":"warning"}')
function Init-Repo {
  [void](Git @('init','-b','main'))
  [void](Git @('config','user.name','NBInspect fixture'))
  [void](Git @('config','user.email','fixture@example.invalid'))
}
function Index-Hash { return (Get-FileHash (Join-Path $repo '.git/index') -Algorithm SHA256).Hash }
# An unborn branch has no commit; only fully staged files are checked.
Init-Repo
$r=Review @('review-git','--staged','--format','json')
Equal $r.source 'index' 'index source'
Equal $r.base_ref 'HEAD' 'base reference'
Equal $r.head_ref 'INDEX' 'index reference'
Equal $r.base_commit $null 'unborn base'; Equal $r.head_commit $null 'index has no commit'
Equal $r.summary.files 0 'empty unborn index'
Save-Notebook 'first.ipynb' 'first' $true
[void](Git @('add','--','first.ipynb'))
Save-Notebook 'intent.ipynb' 'intent' $true
[void](Git @('add','-N','--','intent.ipynb'))
$indexBefore=Index-Hash
$r=Review @('review-git','--staged','--format','json','--config',$policy) 1
Equal $r.summary.added 1 'first commit additions exclude intent-to-add'
Equal $r.summary.introduced 1 'first commit risk'
$stagedJson=$r | ConvertTo-Json -Depth 100 -Compress
[IO.File]::WriteAllText((Join-Path $repo 'first.ipynb'),'{')
$r=Review @('review-git','--staged','--format','json','--config',$policy) 1
Equal ($r | ConvertTo-Json -Depth 100 -Compress) $stagedJson 'unborn working content ignored'
Equal (Index-Hash) $indexBefore 'unborn index bytes unchanged'
$r=Review @('review-git','--staged','--format','text') 0 $false
if (!$r.Contains('first commit') -or !$r.Contains('INDEX')) {throw 'unborn source missing from text'}
$r=Review @('review-git','--staged','--format','html') 0 $false
if (!$r.Contains('first commit') -or !$r.Contains('Staged:')) {throw 'unborn source missing from HTML'}
# Ordinary staged changes include renames and use index blobs after partial staging.
$repo=Join-Path $fixtures 'normal'; [void][IO.Directory]::CreateDirectory($repo)
Init-Repo
Save-Notebook 'modified.ipynb' 'modify'
Save-Notebook 'deleted.ipynb' 'delete'
Save-Notebook "旧 name '&.ipynb" 'rename' $true
Save-Notebook 'rename-edit-old.ipynb' 'rename-edit' $true
Save-Notebook 'unstaged-only.ipynb' 'unstaged'
$base=Commit 'fixture base'
Save-Notebook 'modified.ipynb' 'modify' $true
Save-Notebook 'added.ipynb' 'added' $true
[void](Git @('rm','--','deleted.ipynb'))
[void](Git @('mv','--',"旧 name '&.ipynb","new & '中文.ipynb"))
[IO.File]::Delete((Join-Path $repo 'rename-edit-old.ipynb'))
Save-Notebook 'rename-edit-new.ipynb' 'rename-edit' $true $true
[void](Git @('add','--all'))
$indexBefore=Index-Hash
$r=Review @('review-git','--staged','--format','json','--config',$policy) 1
Equal $r.base_commit $base 'resolved HEAD'; Equal $r.head_commit $null 'no index commit'
Equal $r.summary.files 5 'staged file count'
Equal $r.summary.added 1 'staged addition'; Equal $r.summary.modified 1 'staged modification'
Equal $r.summary.deleted 1 'staged deletion'; Equal $r.summary.renamed 2 'staged renames'
Equal $r.summary.introduced 2 'new risks'; Equal $r.summary.existing 2 'inherited rename risks'
Equal $r.summary.blocked 2 'only introduced risks block'
$stagedJson=$r | ConvertTo-Json -Depth 100 -Compress
# Both directions: risk staged but removed from worktree; unstaged corruption stays out.
Save-Notebook 'modified.ipynb' 'modify'
[IO.File]::Delete((Join-Path $repo 'added.ipynb'))
[IO.File]::WriteAllText((Join-Path $repo "new & '中文.ipynb"),'{')
[IO.File]::WriteAllText((Join-Path $repo 'unstaged-only.ipynb'),'{')
[IO.File]::WriteAllText((Join-Path $repo 'untracked.ipynb'),'{')
$r=Review @('review-git','--staged','--format','json','--config',$policy) 1
Equal ($r | ConvertTo-Json -Depth 100 -Compress) $stagedJson 'partial staging preserved'
Equal (Index-Hash) $indexBefore 'index bytes unchanged'
Equal (Git @('rev-parse','HEAD')) $base 'HEAD unchanged'
Save-Notebook 'intent.ipynb' 'intent' $true
[void](Git @('add','-N','--','intent.ipynb'))
$r=Review @('review-git','--staged','--format','json','--config',$policy) 1
Equal $r.summary.files 5 'ordinary intent-to-add excluded'
$r=Review @('review-git','--staged','--format','json')
Equal $r.status 'passed' 'default threshold'
$r=Review @('review-git','--staged','--format','json','--config',$policy,'--fail-on','error')
Equal $r.policy.fail_on 'error' 'explicit threshold overrides policy'
$subdir=Join-Path $repo 'subdir'; [void][IO.Directory]::CreateDirectory($subdir)
[void](Git @('config','diff.relative','true'))
[void](Git @('config','diff.external','nonexistent-nbinspect-command'))
$r=Review @('review-git','--staged','--format','json','--config',$policy) 1 $true $subdir
Equal $r.summary.files 5 'subdirectory reviews full index and external diff disabled'
$r=Review @('review-git','--staged','--format','text') 0 $false
if (!$r.Contains("Staged: $base -> INDEX")) {throw 'staged source missing from text'}
$r=Review @('review-git','--staged','--format','html') 0 $false
if (!$r.Contains('Staged:') -or !$r.Contains('Matching evidence') -or !$r.Contains('new &amp; &#39;中文.ipynb')) {throw 'staged HTML source/evidence/escaping missing'}
$jsonFile=Join-Path $fixtures 'report.json'; $htmlFile=Join-Path $fixtures 'report.html'
[void](Review @('review-git','--staged','--format','json','--output',$jsonFile) 0 $false)
Equal ((Get-Content $jsonFile -Raw -Encoding utf8 | ConvertFrom-Json).source) 'index' 'JSON output file source'
[void](Review @('review-git','--staged','--format','html','--output',$htmlFile) 0 $false)
[void](Review @('review-git','--staged','--output',$htmlFile) 2 $false $repo 'cannot write')
[void](Review @('review-git','--staged','--config',$policy,'--output',$policy) 2 $false $repo 'cannot overwrite')
[void](Review @('review-git','--staged',$base,$base) 2 $false $repo 'wrong number')
[void](Review @('review-git','--staged',$base) 2 $false $repo 'wrong number')
[void](Review @('check','ignored.ipynb','--staged') 2 $false $repo 'staged is a review-git option')
[void](Review @('diff','before','after','--staged') 2 $false $repo 'staged is a review-git option')
[void](Review @('review-git','--staged','--view','code') 2 $false $repo 'diff options')
[void](Review @('review-git','--staged','--exit-code') 2 $false $repo 'diff options')
[void](Review @('review-git','--staged','--recursive') 2 $false $repo 'recursive')
[void](Review @('review-git','--staged') 2 $false $fixtures 'Git command failed')
$invalidPolicy=Join-Path $fixtures 'invalid.json'; [IO.File]::WriteAllText($invalidPolicy,'{"rules":{"UNKNOWN":{}}}')
[void](Review @('review-git','--staged','--config',$invalidPolicy) 2 $false $repo 'config')
# A detached HEAD is a normal base; only absence of a local branch is unborn.
[void](Git @('update-ref','--no-deref','HEAD',$base))
$r=Review @('review-git','--staged','--format','json','--config',$policy) 1
Equal $r.base_commit $base 'detached HEAD base'
# Broken/unsupported staged inputs preserve valid files and return incomplete.
[IO.File]::WriteAllText((Join-Path $repo 'malformed.ipynb'),'{')
[IO.File]::WriteAllBytes((Join-Path $repo 'utf8.ipynb'),[byte[]](255,254,255))
Save-Notebook 'unsupported.ipynb' 'unsupported'
$f=Join-Path $repo 'unsupported.ipynb'
[IO.File]::WriteAllText($f,[IO.File]::ReadAllText($f).Replace('"nbformat_minor": 5','"nbformat_minor": 6'))
[void](Git @('add','--','malformed.ipynb','utf8.ipynb','unsupported.ipynb'))
$blob=Git @('hash-object','-w','--stdin')
[void](Git @('update-index','--add','--cacheinfo',("120000,$blob,link.ipynb")))
[void](Git @('update-index','--add','--cacheinfo',("160000,$base,module.ipynb")))
$large=Join-Path $repo 'oversized.ipynb'
$stream=[IO.File]::Create($large); $stream.SetLength(52428801); $stream.Dispose()
[void](Git @('add','--','oversized.ipynb'))
$r=Review @('review-git','--staged','--format','json') 2
Equal $r.status 'incomplete' 'invalid staged entries incomplete'
Equal $r.summary.unsupported 1 'unsupported input retained'
Equal $r.summary.errors 5 'invalid input errors retained'
Equal $r.summary.modified 1 'valid result retained'
$largeResult=@($r.files | Where-Object path -eq 'oversized.ipynb')
if ($largeResult.Count -ne 1 -or !$largeResult[0].error.Contains('byte limit')) {throw 'staged blob byte cap not enforced'}
# Even a non-notebook merge conflict prevents review of a committable index.
[void](Git @('update-index','--add','--cacheinfo',("100644,$blob,conflict.txt")))
[void](Git @('update-index','--force-remove','--','conflict.txt'))
$conflictInfo="100644 $blob 1`tconflict.txt`n100644 $blob 2`tconflict.txt`n100644 $blob 3`tconflict.txt`n"
$psi=[Diagnostics.ProcessStartInfo]::new('git'); $psi.WorkingDirectory=$repo; $psi.UseShellExecute=$false; $psi.RedirectStandardInput=$true
foreach ($arg in @('update-index','--index-info')) {[void]$psi.ArgumentList.Add($arg)}
$p=[Diagnostics.Process]::Start($psi); $p.StandardInput.Write($conflictInfo); $p.StandardInput.Close(); $p.WaitForExit()
if ($p.ExitCode -ne 0) {throw 'conflict fixture failed'}; $p.Dispose()
$indexBefore=Index-Hash
[void](Review @('review-git','--staged','--format','json') 2 $false $repo 'unresolved merge conflicts')
Equal (Index-Hash) $indexBefore 'conflicted index unchanged'
# A dangling or malformed HEAD must never be misreported as a first commit.
[IO.File]::WriteAllText((Join-Path $repo '.git/HEAD'),('f'*40)+"`n")
[void](Review @('review-git','--staged') 2 $false $repo 'Git command failed')
[IO.File]::WriteAllText((Join-Path $repo '.git/HEAD'),"ref: refs/heads/main`n")
[IO.File]::WriteAllText((Join-Path $repo '.git/refs/heads/main'),('f'*40)+"`n")
[void](Review @('review-git','--staged') 2 $false $repo 'Git command failed')
# A corrupt index must not be treated as no staged changes.
[IO.File]::WriteAllText((Join-Path $repo '.git/HEAD'),$base+"`n")
[IO.File]::WriteAllText((Join-Path $repo '.git/index'),'corrupt index')
$indexBefore=Index-Hash
[void](Review @('review-git','--staged') 2 $false $repo 'Git command failed')
Equal (Index-Hash) $indexBefore 'corrupt index unchanged'
# SHA256 repositories also work before and after their first commit.
$sha256=Join-Path $fixtures 'sha256'; [void][IO.Directory]::CreateDirectory($sha256)
$probe=Run-Process 'git' @('init','--object-format=sha256','-b','main') $sha256
if ($probe.code -eq 0) {
  $repo=$sha256
  [void](Git @('config','user.name','NBInspect fixture')); [void](Git @('config','user.email','fixture@example.invalid'))
  Save-Notebook 'one.ipynb' 'sha256'
  [void](Git @('add','--','one.ipynb'))
  $r=Review @('review-git','--staged','--format','json')
  Equal $r.base_commit $null 'SHA256 unborn base'
  Equal $r.files[0].after_blob.Length 64 'SHA256 unborn blob ID'
  $first=Commit 'sha256 base'
  Save-Notebook 'one.ipynb' 'sha256' $true
  [void](Git @('add','--','one.ipynb'))
  $r=Review @('review-git','--staged','--format','json','--config',$policy) 1
  Equal $r.base_commit $first 'SHA256 staged base'
  Equal $r.files[0].after_blob.Length 64 'SHA256 staged blob ID'
  # Nothing staged, while worktree has a risk: no file may enter the report.
  [void](Git @('reset','--mixed','HEAD'))
  $r=Review @('review-git','--staged','--format','json','--config',$policy)
  Equal $r.summary.files 0 'unstaged risk ignored'
}
Write-Output "Staged Git CLI integration: $script:passed passed"
Write-Output "Fixtures retained in: $fixtures"
