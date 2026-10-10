#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Executable,
  [Parameter(Mandatory)][string]$Repository,
  [Parameter(Mandatory)][string]$BaseCommit,
  [Parameter(Mandatory)][string]$HeadCommit,
  [Parameter(Mandatory)][string]$ReportDirectory,
  [string]$Config = '',
  [ValidateSet('','error','warning','info')][string]$FailOn = '',
  [string]$StepSummary = $env:GITHUB_STEP_SUMMARY
)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false,$true)
$exitCode = 2
$ownedDirectory = ''
$summaryText = "## NBInspect Notebook review`n`nAnalysis failed; see the uploaded logs.`n"

function Invoke-Review([string]$Format) {
  $psi = [Diagnostics.ProcessStartInfo]::new($script:binary)
  $psi.WorkingDirectory = $script:repositoryRoot
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
  $argv = @('review-git',$BaseCommit,$HeadCommit,'--format',$Format,'--output',(Join-Path $ownedDirectory "review.$Format"))
  if ($script:policyPath) { $argv += @('--config',$script:policyPath) }
  if ($FailOn) { $argv += @('--fail-on',$FailOn) }
  foreach ($argument in $argv) { [void]$psi.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::new(); $process.StartInfo = $psi
  $started = $false
  try {
    [void]$process.Start(); $started = $true
    $outFile = [IO.FileStream]::new((Join-Path $ownedDirectory "$Format.stdout.log"),[IO.FileMode]::CreateNew)
    try {
      $errFile = [IO.FileStream]::new((Join-Path $ownedDirectory "$Format.stderr.log"),[IO.FileMode]::CreateNew)
      try {
        # Notebook content stays in artifacts, never as executable workflow commands in logs.
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($outFile)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($errFile)
        if (!$process.WaitForExit(600000)) { $process.Kill($true); $process.WaitForExit(); throw 'Review timed out after 10 minutes' }
        [void]$outTask.GetAwaiter().GetResult(); [void]$errTask.GetAwaiter().GetResult()
        return $process.ExitCode
      } finally { $errFile.Dispose() }
    } finally { $outFile.Dispose() }
  } finally {
    if ($started -and !$process.HasExited) { $process.Kill($true) }
    $process.Dispose()
  }
}
function Read-ReportFile([string]$Name) {
  $path = Join-Path $ownedDirectory $Name
  $item = Get-Item -LiteralPath $path -Force
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 67108864) {
    throw 'Report is not an ordinary file or exceeds 64 MiB'
  }
  return $utf8.GetString([IO.File]::ReadAllBytes($path))
}

try {
  if ($BaseCommit -cnotmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z' -or $HeadCommit -cnotmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z') {
    throw 'BaseCommit and HeadCommit must be full lowercase Git object IDs'
  }
  $directory = [IO.Path]::GetFullPath($ReportDirectory)
  if (Test-Path -LiteralPath $directory) { throw 'ReportDirectory already exists; existing files are never overwritten' }
  $ownedDirectory = [IO.Directory]::CreateDirectory($directory).FullName
  $script:repositoryRoot = (Get-Item -LiteralPath $Repository -Force).FullName
  if (!(Test-Path -LiteralPath $script:repositoryRoot -PathType Container)) { throw 'Repository is not a directory' }
  $item = Get-Item -LiteralPath $Executable -Force
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Executable is not an ordinary file' }
  $script:binary = $item.FullName
  $script:policyPath = ''
  if ($Config) {
    $policy = Get-Item -LiteralPath $Config -Force
    if ($policy.PSIsContainer -or ($policy.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $policy.Length -gt 1048576) { throw 'Config is not an ordinary file or exceeds 1 MiB' }
    # Freeze one policy for both report formats; the native parser remains authoritative.
    $script:policyPath = Join-Path $ownedDirectory 'policy.json'
    [IO.File]::WriteAllBytes($script:policyPath,[IO.File]::ReadAllBytes($policy.FullName))
  }
  $jsonExit = Invoke-Review 'json'
  if ($jsonExit -notin @(0,1,2)) { throw "Unexpected native review exit: $jsonExit" }
  $report = (Read-ReportFile 'review.json') | ConvertFrom-Json -AsHashtable -Depth 100
  if ($report['schema_version'] -ne 1 -or $report['kind'] -ne 'git-review' -or
      $report['base_commit'] -cne $BaseCommit -or $report['head_commit'] -cne $HeadCommit -or
      ($report.ContainsKey('source') -and $report['source'] -ne 'commits')) { throw 'Report identity does not match the requested commits' }
  $state = $report['status']
  $expectedExit = switch ($state) { 'passed' {0}; 'blocked' {1}; 'incomplete' {2}; default {throw 'Unknown report status'} }
  if ($jsonExit -ne $expectedExit -or $report['complete'] -isnot [bool] -or $report['complete'] -ne ($state -ne 'incomplete')) { throw 'Report status and exit code disagree' }
  $counts = $report['summary']
  $keys = @('files','added','modified','renamed','deleted','passed','blocked','errors','unsupported','introduced','existing','resolved','uncertain')
  foreach ($key in $keys) {
    $value = $counts[$key]
    if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0) { throw "Invalid summary count: $key" }
  }
  if ($report['files'] -isnot [array] -or $counts['files'] -ne $report['files'].Count -or
      $counts['files'] -ne ($counts['added']+$counts['modified']+$counts['renamed']+$counts['deleted'])) { throw 'Inconsistent report file counts' }
  $htmlExit = Invoke-Review 'html'
  if ($htmlExit -ne $jsonExit) { throw 'JSON and HTML review exits disagree' }
  $html = Read-ReportFile 'review.html'
  if (!$html.StartsWith('<!doctype html>')) { throw 'HTML report is missing its document header' }
  $summaryText = "## NBInspect Notebook review`n`nStatus: **$state**`n`nBase: ``$BaseCommit```n`nHead: ``$HeadCommit```n`n| Metric | Count |`n| --- | ---: |`n"
  foreach ($key in $keys) { $summaryText += "| $key | $($counts[$key]) |`n" }
  $summaryText += "`nDownload the JSON and offline HTML reports from the job artifacts. This compares the two event endpoints, not merge-base.`n"
  $exitCode = $jsonExit
} catch {
  if ($ownedDirectory) {
    try { [IO.File]::WriteAllText((Join-Path $ownedDirectory 'run-error.txt'),$_.Exception.Message,$utf8) }
    catch { [Console]::Error.WriteLine('Cannot save the error log; failing the check.') }
  }
  [Console]::Error.WriteLine('NBInspect PR review failed; see run-error.txt and native logs. No successful review is claimed.')
} finally {
  try {
    if ($ownedDirectory) { [IO.File]::WriteAllText((Join-Path $ownedDirectory 'summary.md'),$summaryText,$utf8) }
    if ($StepSummary) { [IO.File]::AppendAllText($StepSummary,$summaryText,$utf8) }
  } catch {
    $exitCode = 2
    [Console]::Error.WriteLine('Cannot write the review summary; failing the check.')
  }
}
exit $exitCode
