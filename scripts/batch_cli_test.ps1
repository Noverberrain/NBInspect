$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
Set-Location $root
$exe = Join-Path $root '_build/native/debug/build/cmd/nbinspect/nbinspect.exe'
$fixtures = Join-Path $root ('_build/batch-fixtures-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtures) | Out-Null
$clean = '{"nbformat":4,"nbformat_minor":5,"metadata":{"kernelspec":{},"language_info":{}},"cells":[]}'
$warning = '{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","id":"a","metadata":{},"source":"x","execution_count":null,"outputs":[{"output_type":"error","ename":"Demo","evalue":"intentional","traceback":[]}]}]}'
function Save-Notebook([string]$directory,[string]$name,[string]$content) {
  [IO.Directory]::CreateDirectory($directory) | Out-Null
  [IO.File]::WriteAllText((Join-Path $directory $name),$content)
}
$script:passed = 0
function Invoke-Batch([string[]]$cliArgs,[int]$exit,[bool]$json=$true) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $exe
  $psi.Arguments = ($cliArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $psi
  [void]$process.Start()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  if ($process.ExitCode -ne $exit) { throw "Expected $exit, got $($process.ExitCode): $stderr" }
  $script:passed++
  if ($json) {
    if ($stderr) { throw "Unexpected stderr: $stderr" }
    return $stdout | ConvertFrom-Json
  }
  return @{ stdout=$stdout; stderr=$stderr }
}
function Assert-Value($actual,$expected,[string]$label) {
  if ($actual -ne $expected) { throw "$label expected $expected, got $actual" }
}
$collection = Join-Path $fixtures '课程资料 with spaces'
Save-Notebook $collection 'a.ipynb' $clean
Save-Notebook $collection 'z.IPYNB' $warning
Save-Notebook $collection 'ignored.txt' '{}'
Save-Notebook (Join-Path $collection '子目录') 'b.ipynb' $clean
foreach ($excluded in @('.git','_build','.mooncakes','.ipynb_checkpoints','node_modules')) {
  Save-Notebook (Join-Path $collection $excluded) 'ignored.ipynb' '{}'
}
$report = Invoke-Batch @('batch',$collection,'--format','json') 0
Assert-Value $report.kind 'batch' 'kind'
Assert-Value $report.summary.files 2 'top-level count'
Assert-Value $report.summary.passed 2 'default threshold'
Assert-Value $report.summary.warning_findings 1 'warning count'
Assert-Value $report.files[0].path 'a.ipynb' 'stable ordering'
$report = Invoke-Batch @('batch',$collection,'--recursive','--format','json') 0
Assert-Value $report.summary.files 3 'recursive count'
Assert-Value $report.summary.skipped 5 'excluded directories'
Assert-Value $report.files[2].path '子目录/b.ipynb' 'relative Unicode path'
$report = Invoke-Batch @('batch',$collection,'--format','json','--fail-on','warning') 1
Assert-Value $report.summary.blocked 1 'warning threshold'
$report = Invoke-Batch @('batch',$collection,'--format','json','--fail-on','info') 1
Assert-Value $report.summary.blocked 1 'info threshold'
$mixed = Join-Path $fixtures 'mixed'
Save-Notebook $mixed 'a.ipynb' $clean
Save-Notebook $mixed 'broken.ipynb' '{}'
Save-Notebook $mixed 'future.ipynb' $clean.Replace('"nbformat_minor":5','"nbformat_minor":6')
Save-Notebook $mixed 'blocked.ipynb' $warning.Replace('"id":"a"','"id":"invalid id"')
[IO.File]::WriteAllBytes((Join-Path $mixed 'utf8.ipynb'),[byte[]]@(255,254))
Save-Notebook $mixed 'empty.ipynb' ''
$report = Invoke-Batch @('batch',$mixed,'--format','json') 2
Assert-Value $report.status 'incomplete' 'partial status'
Assert-Value $report.summary.files 6 'continue after invalid inputs'
Assert-Value $report.summary.errors 3 'file read or parse errors'
Assert-Value $report.summary.unsupported 1 'future version'
Assert-Value $report.summary.blocked 1 'incomplete has precedence over blocked'
Assert-Value $report.complete $false 'completion flag'
$text = Invoke-Batch @('batch',$mixed) 2 $false
if (!$text.stdout.Contains('broken.ipynb') -or !$text.stdout.Contains('utf8.ipynb') -or $text.stderr) { throw 'Partial text report invalid' }
$out = Join-Path $fixtures 'report.html'
[void](Invoke-Batch @('batch',$mixed,'--format','html','--output',$out) 2 $false)
$html = [IO.File]::ReadAllText($out)
if (!$html.Contains("id='file-0'") -or !$html.Contains('Batch summary')) { throw 'HTML file navigation missing' }
$errorReport = Invoke-Batch @('batch',$collection,'--output',$out) 2 $false
if (!$errorReport.stderr.Contains('cannot write report')) { throw 'Existing report overwritten' }
$empty = Join-Path $fixtures 'empty'
[IO.Directory]::CreateDirectory($empty) | Out-Null
$report = Invoke-Batch @('batch',$empty,'--format','json') 0
Assert-Value $report.summary.files 0 'empty directory'
$errorReport = Invoke-Batch @('batch',(Join-Path $fixtures 'missing')) 2 $false
if (!$errorReport.stderr -or $errorReport.stdout) { throw 'Root error channel invalid' }
[void](Invoke-Batch @('batch',(Join-Path $collection 'a.ipynb')) 2 $false)
[void](Invoke-Batch @('batch',$collection,'--view','code') 2 $false)
[void](Invoke-Batch @('batch',$collection,'--exit-code') 2 $false)
[void](Invoke-Batch @('check',(Join-Path $collection 'a.ipynb'),'--recursive') 2 $false)
[void](Invoke-Batch @('batch',$collection,'--fail-on','unknown') 2 $false)
$links = Join-Path $fixtures 'links'
[IO.Directory]::CreateDirectory($links) | Out-Null
New-Item -ItemType Junction -Path (Join-Path $links 'loop') -Target $links | Out-Null
$report = Invoke-Batch @('batch',$links,'--recursive','--format','json') 0
Assert-Value $report.summary.files 0 'junction is not followed'
Assert-Value $report.summary.skipped 1 'junction recorded'
[void](Invoke-Batch @('batch',(Join-Path $links 'loop')) 2 $false)
$limited = Join-Path $fixtures 'limited'
for ($i=0;$i -lt 1001;$i++) { Save-Notebook $limited ('{0:D4}.ipynb' -f $i) $clean }
$report = Invoke-Batch @('batch',$limited,'--format','json') 2
Assert-Value $report.summary.files 1000 'file limit'
Assert-Value $report.summary.scan_errors 1 'truncation issue'
Assert-Value $report.complete $false 'truncated scan cannot pass'
Write-Output "Batch CLI integration: $script:passed passed"
Write-Output "Fixtures retained in: $fixtures"
