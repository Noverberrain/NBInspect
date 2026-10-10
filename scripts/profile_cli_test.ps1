#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$exe = Join-Path $root '_build/native/debug/build/cmd/nbinspect/nbinspect.exe'
$fixtures = [IO.Directory]::CreateDirectory((Join-Path $root ('_build/profile-fixtures-' + [Guid]::NewGuid().ToString('N')))).FullName
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
$inputPath = Join-Path $fixtures '中文 notebook.ipynb'
$book = @{nbformat=4;nbformat_minor=5;metadata=@{};cells=@(
  @{cell_type='code';id='code';source=@('你好',"`n");metadata=@{};execution_count=$null;outputs=@(
    @{output_type='stream';name='stdout';text="你好`n"},
    @{output_type='display_data';data=@{'image/png'='not-base64';'text/html'='<script>payload-secret</script>'};metadata=@{}},
    @{output_type='error';ename='Demo';evalue='payload-secret';traceback=@()}
  )},
  @{cell_type='markdown';id='md';source='![image](attachment:a.png)';metadata=@{};attachments=@{'a.png'=@{'image/png'='AAAA'}}}
)}
$bookJson = $book | ConvertTo-Json -Depth 20 -Compress
[IO.File]::WriteAllText($inputPath, ($book | ConvertTo-Json -Depth 20), $utf8)
$r = (Invoke-ProfileCase 'JSON statistics' @('profile',$inputPath,'--format','json')) | ConvertFrom-Json
if ($r.kind -ne 'profile' -or $r.status -ne 'complete' -or $r.resource_count -ne 5) { throw 'profile schema/counters' }
if ($r.summary.notebook_bytes -is [string]) { throw 'byte counts must be JSON numbers' }
if ($r.summary.notebook_bytes -ne ($r.summary.source_bytes + $r.summary.output_bytes + $r.summary.attachment_bytes + $r.summary.other_bytes)) { throw 'partition does not add up' }
if ($r.summary.notebook_bytes -ge (Get-Item $inputPath).Length) { throw 'original formatting counted as compact JSON' }
if ($r.cells[0].index -ne 0 -or $r.resources[0].bytes -lt $r.resources[-1].bytes) { throw 'descending ranking' }
$png = @($r.mime_types | Where-Object mime -eq 'image/png')
if ($png.Count -ne 1 -or $png[0].count -ne 2 -or $png[0].bytes -ne 18) { throw 'output and attachment MIME values not combined' }
$text = Invoke-ProfileCase 'text ranking' @('profile',$inputPath)
if (!$text.Contains('Cells by size') -or !$text.Contains('MIME payloads') -or $text.Contains('payload-secret')) { throw 'text report content' }
$html = Invoke-ProfileCase 'HTML table' @('profile',$inputPath,'--format','html')
if (!$html.Contains('<table>') -or !$html.Contains('Cells by size') -or !$html.Contains("script-src 'none'") -or $html.Contains('payload-secret')) { throw 'HTML report content' }
$reportPath = Join-Path $fixtures 'report.json'
[void](Invoke-ProfileCase 'new report file' @('profile',$inputPath,'--format','json','--output',$reportPath))
if ((Get-Content $reportPath -Raw | ConvertFrom-Json).kind -ne 'profile') { throw 'written report invalid' }
$beforeHash = (Get-FileHash $inputPath).Hash
[void](Invoke-ProfileCase 'preserve input' @('profile',$inputPath,'--output',$inputPath) 2)
if ((Get-FileHash $inputPath).Hash -ne $beforeHash) { throw 'input overwritten' }
$reportHash = (Get-FileHash $reportPath).Hash
[void](Invoke-ProfileCase 'preserve report' @('profile',$inputPath,'--output',$reportPath) 2)
if ((Get-FileHash $reportPath).Hash -ne $reportHash) { throw 'report overwritten' }
foreach ($option in @('--config','--fail-on','--view')) {
  $value = switch ($option) { '--config' { 'missing.json' }; '--fail-on' { 'error' }; '--view' { 'all' } }
  [void](Invoke-ProfileCase "reject $option" @('profile',$inputPath,$option,$value) 2)
}
foreach ($option in @('--recursive','--exit-code','--staged')) {
  [void](Invoke-ProfileCase "reject $option" @('profile',$inputPath,$option) 2)
}
[void](Invoke-ProfileCase 'missing input' @('profile') 2)
[void](Invoke-ProfileCase 'extra input' @('profile',$inputPath,$inputPath) 2)
[void](Invoke-ProfileCase 'bad format' @('profile',$inputPath,'--format','xml') 2)
[void](Invoke-ProfileCase 'missing option value' @('profile',$inputPath,'--output') 2)
[void](Invoke-ProfileCase 'missing file' @('profile',(Join-Path $fixtures 'absent.ipynb')) 2)
$invalid = Join-Path $fixtures 'bad.ipynb'
[IO.File]::WriteAllText($invalid, '{}', $utf8)
[void](Invoke-ProfileCase 'invalid notebook' @('profile',$invalid) 2)
$future = Join-Path $fixtures 'future.ipynb'
[IO.File]::WriteAllText($future, $bookJson.Replace('"nbformat_minor":5','"nbformat_minor":6'), $utf8)
[void](Invoke-ProfileCase 'unsupported minor' @('profile',$future) 2)
$old = Join-Path $fixtures 'old.ipynb'
[IO.File]::WriteAllText($old, '{"nbformat":4,"nbformat_minor":0,"metadata":{},"cells":[]}', $utf8)
$empty = (Invoke-ProfileCase 'empty version 4.0' @('profile',$old,'--format','json')) | ConvertFrom-Json
if ($empty.cell_count -ne 0 -or $empty.summary.output_bytes -ne 0) { throw 'empty notebook size' }
Write-Output "Profile CLI integration: $script:passed passed"
Write-Output "Fixtures retained in: $fixtures"
