$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
Set-Location $root
$exe = Join-Path $root '_build/native/debug/build/cmd/nbinspect/nbinspect.exe'
$fixtures = Join-Path $root ('_build/policy-fixtures-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtures) | Out-Null
$clean = '{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","id":"a","source":"x","metadata":{},"execution_count":null,"outputs":[]}]}'
$risk = $clean.Replace('"outputs":[]','"outputs":[{"output_type":"error","ename":"Demo","evalue":"demo","traceback":[]}]')
$a = Join-Path $fixtures 'before.ipynb'
$b = Join-Path $fixtures 'after.ipynb'
[IO.File]::WriteAllText($a,$clean)
[IO.File]::WriteAllText($b,$risk)
$folder = Join-Path $fixtures 'collection'
[IO.Directory]::CreateDirectory($folder) | Out-Null
[IO.File]::WriteAllText((Join-Path $folder 'risk.ipynb'),$risk)
$strict = Join-Path $fixtures '严格 policy.json'
[IO.File]::WriteAllText($strict,'{"rules":{"OUT001":{"severity":"error"}}}')
$warning = Join-Path $fixtures 'warning.json'
[IO.File]::WriteAllText($warning,'{"fail_on":"warning"}')
$disabled = Join-Path $fixtures 'disabled.json'
[IO.File]::WriteAllText($disabled,'{"rules":{"OUT001":{"enabled":false},"META001":{"enabled":false}}}')
$script:passed = 0
function Invoke-Policy([string[]]$cliArgs,[int]$exit,[bool]$json=$true,[string]$errorText='') {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName=$exe
  $psi.Arguments=($cliArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
  $psi.UseShellExecute=$false
  $psi.RedirectStandardOutput=$true
  $psi.RedirectStandardError=$true
  $psi.StandardOutputEncoding=[Text.Encoding]::UTF8
  $psi.StandardErrorEncoding=[Text.Encoding]::UTF8
  $p=[Diagnostics.Process]::new()
  $p.StartInfo=$psi
  [void]$p.Start()
  $stdout=$p.StandardOutput.ReadToEnd()
  $stderr=$p.StandardError.ReadToEnd()
  $p.WaitForExit()
  if ($p.ExitCode -ne $exit) {throw "Expected $exit, got $($p.ExitCode): $stderr"}
  if ($errorText -and (!$stderr.Contains($errorText) -or $stdout)) {throw "Invalid config error channel: $stderr"}
  $script:passed++
  if ($json) {if ($stderr) {throw $stderr}; return $stdout | ConvertFrom-Json}
  return $stdout
}
$report = Invoke-Policy @('check',$b,'--config',$strict,'--format','json') 1
if ($report.policy.rules.OUT001.severity -ne 'error') {throw 'Severity override not recorded'}
$report = Invoke-Policy @('check',$b,'--config',$disabled,'--format','json') 0
if ($report.findings.Count -ne 0) {throw 'Disabled rules still present'}
[void](Invoke-Policy @('check',$b,'--config',$warning,'--format','json') 1)
$report = Invoke-Policy @('check',$b,'--config',$warning,'--fail-on','error','--format','json') 0
if ($report.policy.fail_on -ne 'error') {throw 'Explicit default CLI value did not override config'}
$report = Invoke-Policy @('review',$a,$b,'--config',$strict,'--format','json') 1
if ($report.summary.introduced -ne 1) {throw 'Risk review policy mismatch'}
$report = Invoke-Policy @('review',$b,$b,'--config',$strict,'--format','json') 0
if ($report.summary.introduced -ne 0) {throw 'Policy promoted existing risk to introduced'}
[void](Invoke-Policy @('review',$a,$b,'--config',$disabled,'--format','json') 0)
$report = Invoke-Policy @('batch',$folder,'--config',$strict,'--format','json') 1
if ($report.policy.rules.OUT001.severity -ne $report.files[0].report.policy.rules.OUT001.severity) {throw 'Batch and file policies differ'}
[void](Invoke-Policy @('batch',$folder,'--config',$disabled,'--format','json') 0)
[void](Invoke-Policy @('batch',$folder,'--config',$warning,'--fail-on','error','--format','json') 0)
$text = Invoke-Policy @('check',$b,'--config',$strict) 1 $false
if (!$text.Contains('Effective policy:')) {throw 'Text report does not record policy'}
$html = Invoke-Policy @('review',$a,$b,'--config',$strict,'--format','html') 1 $false
if (!$html.Contains('Effective publication policy')) {throw 'HTML report does not record policy'}
$out = Join-Path $fixtures 'report.json'
[void](Invoke-Policy @('check',$b,'--config',$strict,'--format','json','--output',$out) 1 $false)
if (([IO.File]::ReadAllText($out) | ConvertFrom-Json).policy.rules.OUT001.severity -ne 'error') {throw 'File report policy invalid'}
foreach ($case in @(
  @('{"rules":{"TYPO":{}}}','/rules/TYPO'),
  @('{"limits":{"max_cell_output_bytes":0}}','/limits/max_cell_output_bytes'),
  @('{"rules":{"FMT002":{"enabled":false}}}','/rules/FMT002'),
  @('{"fail_on":"fatal"}','/fail_on'),
  @('{"rules":{"OUT001":{"enable":false}}}','/rules/OUT001/enable'),
  @('{','invalid JSON')
)) {
  $bad = Join-Path $fixtures ('invalid-' + [Guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($bad,$case[0])
  [void](Invoke-Policy @('batch',$folder,'--config',$bad,'--format','json') 2 $false $case[1])
}
[void](Invoke-Policy @('check',$a,'--config',(Join-Path $fixtures 'missing.json')) 2 $false 'config ')
[void](Invoke-Policy @('check',$a,'--config') 2 $false 'missing option')
[void](Invoke-Policy @('diff',$a,$b,'--config',$strict) 2 $false 'config is')
[void](Invoke-Policy @('check',$b,'--config',$strict,'--output',$strict) 2 $false 'configuration file')
$huge = Join-Path $fixtures 'huge.json'
[IO.File]::WriteAllText($huge,(' ' * 1048577))
[void](Invoke-Policy @('check',$a,'--config',$huge) 2 $false '1048576')
foreach ($template in @('teaching','research','sharing')) {
  $expected = if ($template -eq 'sharing' -or $template -eq 'research') {1} else {0}
  [void](Invoke-Policy @('check',$b,'--config',("configs/$template.json"),'--format','json') $expected)
}
$tiny = Join-Path $fixtures 'tiny.json'
[IO.File]::WriteAllText($tiny,'{"rules":{"OUT001":{"enabled":false},"META001":{"enabled":false},"SIZE001":{"severity":"error"}},"limits":{"max_cell_output_bytes":16,"max_total_output_bytes":16}}')
$report = Invoke-Policy @('check',$b,'--config',$tiny,'--format','json') 1
if ($report.findings.Count -ne 2 -or @($report.findings | Where-Object code -ne 'SIZE001').Count -ne 0) {throw 'Configured size checks invalid'}
$report = Invoke-Policy @('review',$a,$b,'--config',$tiny,'--format','json') 1
if ($report.summary.introduced -ne 2) {throw 'Review ignores output size thresholds'}
$report = Invoke-Policy @('batch',$folder,'--config',$tiny,'--format','json') 1
if ($report.summary.error_findings -ne 2) {throw 'Batch ignores output size thresholds'}
$policyHtml = Join-Path $fixtures 'policy-report.html'
[void](Invoke-Policy @('review',$a,$b,'--config',$strict,'--format','html','--output',$policyHtml) 1 $false)
Write-Output "Policy CLI integration: $script:passed passed"
Write-Output "Fixtures retained in: $fixtures"
