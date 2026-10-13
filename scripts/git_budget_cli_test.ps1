#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$exe = Join-Path $root '_build/native/debug/build/cmd/nbinspect/nbinspect.exe'
$fixtures = Join-Path $root ('_build/git-budget-fixtures-' + [Guid]::NewGuid().ToString('N'))
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

$config=Join-Path $fixtures 'budget 中文.json'
$utf8=[Text.UTF8Encoding]::new($false)
function Budget-Config([int]$value=0) { [IO.File]::WriteAllText($config, ('{"limits":{"max_notebook_growth_bytes":'+$value+',"max_output_growth_bytes":'+$value+'}}'),$utf8) }
function Save-Size([string]$name,[string]$text) {
  $value=@{nbformat=4;nbformat_minor=5;metadata=@{};cells=@(@{cell_type='code';id='stable';source=('line remains stable' * 30);metadata=@{};execution_count=$null;outputs=@(@{output_type='stream';name='stdout';text=$text})})}
  [IO.File]::WriteAllText((Join-Path $repo $name),($value | ConvertTo-Json -Depth 20),$utf8)
}
[void](Git @('init','-b','main'))
[void](Git @('config','user.name','NBInspect fixture'))
[void](Git @('config','user.email','fixture@example.invalid'))
Budget-Config
$staged=@('budget-git','--staged','--config',$config,'--format','json')
$r=Review $staged
Equal $r.kind 'git-budget' 'kind'
Equal $r.source 'index' 'source'
Equal $r.summary.files 0 'empty index'
Equal ($null -eq $r.base_commit) $true 'unborn base'
Save-Size '课程 a.ipynb' 'short'
Save-Size 'b.ipynb' 'short123'
[void](Git @('add','--all'))
$indexHash=(Get-FileHash (Join-Path $repo '.git/index')).Hash
$r=Review $staged 1
Equal $r.summary.added 2 'first commit additions'
Equal $r.files[0].report.comparison.before_absent $true 'absent baseline'
Equal $r.files[0].report.checks[0].before_bytes 0 'zero stored bytes'
Equal $indexHash (Get-FileHash (Join-Path $repo '.git/index')).Hash 'read-only index'
Budget-Config 1000000
[void](Review $staged)
[void](Git @('commit','-m','base'))
$base=Git @('rev-parse','HEAD')
Budget-Config
Save-Size '课程 a.ipynb' 'short123'
Save-Size 'b.ipynb' 'short'
[void](Git @('add','--all'))
$r=Review $staged 1
Equal $r.summary.blocked 1 'one file growth'
Equal $r.summary.passed 1 'shrink cannot offset'
[IO.File]::WriteAllText((Join-Path $repo '课程 a.ipynb'),'{',$utf8)
$r=Review $staged 1
Equal $r.summary.errors 0 'unstaged corruption ignored'
$a=$r.files | Where-Object path -eq '课程 a.ipynb'
Equal $a.report.checks[0].delta_bytes 3 'staged byte delta'
$sub=Join-Path $repo 'nested'; [IO.Directory]::CreateDirectory($sub) | Out-Null
[void](Review $staged 1 $true $sub)
# Git-provided temporary indexes are respected, as required for --only commits.
$altIndex=Join-Path $fixtures 'temporary index'
Copy-Item -LiteralPath (Join-Path $repo '.git/index') -Destination $altIndex
$previousIndex=$env:GIT_INDEX_FILE
try {
  $env:GIT_INDEX_FILE=$altIndex
  $r=Review $staged 1
  Equal $r.summary.blocked 1 'temporary index preserved'
  [void](Git @('read-tree','--empty'))
  $r=Review $staged
  Equal $r.summary.deleted 2 'alternate index deletion only'
} finally {
  if ($null -eq $previousIndex) {Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue} else {$env:GIT_INDEX_FILE=$previousIndex}
}
[void](Git @('rm','-f','b.ipynb'))
$r=Review $staged 1
Equal $r.summary.deleted 1 'deletion recorded'
Equal $r.summary.blocked 1 'deletion cannot offset growth'
[void](Git @('commit','-m','changed stored versions'))
$head=Git @('rev-parse','HEAD')
$commits=@('budget-git',$base,$head,'--config',$config,'--format','json')
$r=Review $commits 1
Equal $r.source 'commits' 'commit source'
Equal $r.base_commit $base 'resolved base'
Equal $r.head_commit $head 'resolved head'
[void](Review @('budget-git',$head,$base,'--config',$config,'--format','json') 1) # restored deleted b is an addition from zero
[void](Review @('budget-git',$head,$head,'--config',$config,'--format','json'))
$text=Review @('budget-git',$base,$head,'--config',$config) 1 $false
if (!$text.Contains('Per changed Notebook') -or !$text.Contains('excess 3 bytes')) {throw 'text evidence missing'}
$html=Review @('budget-git',$base,$head,'--config',$config,'--format','html') 1 $false
if (!$html.Contains('Git growth budget') -or !$html.Contains('Effective size budget') -or !$html.Contains('Growth allowance results') -or !$html.Contains("script-src 'none'")) {throw 'HTML evidence missing'}
$report=Join-Path $fixtures 'report.json'
[void](Review @('budget-git',$base,$head,'--config',$config,'--format','json','--output',$report) 1 $false)
Equal (Get-Content $report -Raw | ConvertFrom-Json).status 'blocked' 'saved blocked report'
[void](Review @('budget-git',$base,$head,'--config',$config,'--output',$report) 2 $false $repo 'cannot write')
[void](Review @('budget-git',$base,$head,'--config',$config,'--output',$config) 2 $false $repo 'cannot overwrite')
$notebookHash=(Get-FileHash (Join-Path $repo '课程 a.ipynb')).Hash
[void](Review @('budget-git',$base,$head,'--config',$config,'--output',(Join-Path $repo '课程 a.ipynb')) 2 $false $repo 'cannot write')
Equal (Get-FileHash (Join-Path $repo '课程 a.ipynb')).Hash $notebookHash 'worktree protected'
Budget-Config 1000000
[void](Review $commits)
Budget-Config
# Restore real data, then rename: unchanged stored content has no growth.
Save-Size '课程 a.ipynb' 'short123'
[void](Git @('mv','课程 a.ipynb','renamed.ipynb'))
$r=Review $staged
Equal $r.summary.renamed 1 'rename recognized'
Equal $r.files[0].report.checks[0].delta_bytes 0 'rename zero growth'
[void](Git @('commit','-m','rename'))
# A changed file retains matching ambiguity, not forced pairs.
$dup=@{nbformat=4;nbformat_minor=4;metadata=@{};cells=@(@{cell_type='raw';source='same';metadata=@{}},@{cell_type='raw';source='same';metadata=@{}})} | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText((Join-Path $repo 'ambiguous.ipynb'),$dup,$utf8)
[void](Git @('add','--all')); [void](Git @('commit','-m','duplicate baseline'))
[IO.File]::WriteAllText((Join-Path $repo 'ambiguous.ipynb'),$dup.Replace('"metadata": {}','"metadata": {"changed":true}'),$utf8)
[void](Git @('add','ambiguous.ipynb'))
Budget-Config 1000000
$r=Review $staged
Equal $r.files[0].report.comparison.ambiguous_before.Count 2 'ambiguity preserved'
Budget-Config
# Invalid objects/errors stay in the report and override the blocked decision.
Save-Size 'renamed.ipynb' 'short12345'
[IO.File]::WriteAllText((Join-Path $repo 'broken.ipynb'),'{',$utf8)
[IO.File]::WriteAllBytes((Join-Path $repo 'utf8.ipynb'),[byte[]](255,254,255))
[void](Git @('add','--all'))
$r=Review $staged 2
Equal $r.status 'incomplete' 'errors override blocking'
Equal $r.complete $false 'incomplete marker'
Equal $r.summary.errors 2 'both malformed and encoding errors'
if ($r.summary.blocked -lt 1) {throw 'valid blocked files lost'}
[void](Git @('reset','--hard','HEAD'))
$oversized=Join-Path $repo 'huge.ipynb'
[IO.File]::WriteAllBytes($oversized,[byte[]]::new(52428801))
[void](Git @('add','huge.ipynb'))
$r=Review $staged 2
if (!($r.files | Where-Object path -eq 'huge.ipynb').error.Contains('byte limit')) {throw 'Git blob cap not enforced'}
[void](Git @('reset','--hard','HEAD'))
foreach ($flag in @('--view','--fail-on')) { $value=if ($flag -eq '--view') {'all'} else {'error'}; [void](Review ($staged + @($flag,$value)) 2 $false $repo 'accepts only') }
foreach ($flag in @('--recursive','--exit-code')) { [void](Review ($staged + @($flag)) 2 $false $repo 'accepts only') }
[void](Review @('budget-git',$base,$head) 2 $false $repo 'requires')
[void](Review ($staged + @($base)) 2 $false $repo 'wrong number')
[void](Review @('budget-git','missing-ref',$head,'--config',$config) 2 $false $repo 'Git command failed')
[void](Review $staged 2 $false $fixtures 'Git command failed')
[IO.File]::WriteAllText($config,'{"rules":{}}',$utf8)
[void](Review $staged 2 $false $repo 'config')
Budget-Config
# Any unmerged path, even a non-notebook, must refuse successful analysis.
$blob=Git @('rev-parse','HEAD:renamed.ipynb')
$info="100644 $blob 1`ta.txt`n100644 $blob 2`ta.txt`n100644 $blob 3`ta.txt`n"
$infoFile=Join-Path $fixtures 'conflict-index.txt'; [IO.File]::WriteAllText($infoFile,$info,$utf8)
$psi=[Diagnostics.ProcessStartInfo]::new('git'); $psi.WorkingDirectory=$repo; $psi.UseShellExecute=$false; $psi.RedirectStandardInput=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
$psi.ArgumentList.Add('update-index'); $psi.ArgumentList.Add('--index-info')
$p=[Diagnostics.Process]::Start($psi); $p.StandardInput.Write($info); $p.StandardInput.Close(); $p.WaitForExit(); if ($p.ExitCode) {throw 'conflict fixture'}; $p.Dispose()
[void](Review $staged 2 $false $repo 'unresolved merge conflicts')
Write-Output "Git budget CLI integration: $script:passed passed"
Write-Output "Fixtures retained in: $fixtures"
