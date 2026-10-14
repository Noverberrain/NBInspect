#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Executable,
  [Parameter(Mandatory)][string]$Repository,
  [Parameter(Mandatory)][string]$BaseCommit,
  [Parameter(Mandatory)][string]$HeadCommit,
  [Parameter(Mandatory)][string]$ReportDirectory,
  [string]$Config = '',
  [string]$BudgetConfig = '',
  [ValidateSet('','error','warning','info')][string]$FailOn = '',
  [string]$StepSummary = $env:GITHUB_STEP_SUMMARY
)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false,$true)
$exitCode = 2
$ownedDirectory = ''
$summaryText = "## NBInspect Notebook review`n`nAnalysis failed; see the uploaded logs.`n"

function Invoke-Review([string]$Format, [string]$Command = 'review-git', [string]$Prefix = 'review') {
  $psi = [Diagnostics.ProcessStartInfo]::new($script:binary)
  $psi.WorkingDirectory = $script:repositoryRoot
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
  $argv = @($Command,$BaseCommit,$HeadCommit,'--format',$Format,'--output',(Join-Path $ownedDirectory "$Prefix.$Format"))
  $configPath = if ($Command -eq 'budget-git') { $script:budgetPath } else { $script:policyPath }
  if ($configPath) { $argv += @('--config',$configPath) }
  if ($Command -eq 'review-git' -and $FailOn) { $argv += @('--fail-on',$FailOn) }
  $logPrefix = if ($Prefix -eq 'review') { $Format } else { "$Prefix-$Format" }
  foreach ($argument in $argv) { [void]$psi.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::new(); $process.StartInfo = $psi
  $started = $false
  try {
    [void]$process.Start(); $started = $true
    $outFile = [IO.FileStream]::new((Join-Path $ownedDirectory "$logPrefix.stdout.log"),[IO.FileMode]::CreateNew)
    try {
      $errFile = [IO.FileStream]::new((Join-Path $ownedDirectory "$logPrefix.stderr.log"),[IO.FileMode]::CreateNew)
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

function Read-ValidatedReport([string]$Name, [string]$Kind, [int]$NativeExit, [string[]]$Keys) {
  if ($NativeExit -notin @(0,1,2)) { throw "Unexpected native exit: $NativeExit" }
  $value = (Read-ReportFile $Name) | ConvertFrom-Json -AsHashtable -Depth 100
  if ($value['schema_version'] -ne 1 -or $value['kind'] -ne $Kind -or
      $value['base_commit'] -cne $BaseCommit -or $value['head_commit'] -cne $HeadCommit -or
      ($value.ContainsKey('source') -and $value['source'] -ne 'commits')) { throw 'Report identity does not match the requested commits' }
  if ($Kind -eq 'git-budget' -and ($value['source'] -ne 'commits' -or $value['scope'] -ne 'per-changed-notebook')) { throw 'Budget scope or source is invalid' }
  $state = $value['status']
  $expected = switch ($state) { 'passed' {0}; 'blocked' {1}; 'incomplete' {2}; default {throw 'Unknown report status'} }
  if ($NativeExit -ne $expected -or $value['complete'] -isnot [bool] -or $value['complete'] -ne ($state -ne 'incomplete')) { throw 'Report status and exit code disagree' }
  $counts = $value['summary']
  foreach ($key in $Keys) {
    $count = $counts[$key]
    if (($count -isnot [int] -and $count -isnot [long]) -or $count -lt 0) { throw "Invalid summary count: $key" }
  }
  if ($value['files'] -isnot [array] -or $counts['files'] -ne $value['files'].Count -or
      $counts['files'] -ne ($counts['added']+$counts['modified']+$counts['renamed']+$counts['deleted'])) { throw 'Inconsistent report file counts' }
  return $value
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
  $script:budgetPath = ''
  if ($BudgetConfig) {
    $budget = Get-Item -LiteralPath $BudgetConfig -Force
    if ($budget.PSIsContainer -or ($budget.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $budget.Length -gt 1048576) { throw 'BudgetConfig is not an ordinary file or exceeds 1 MiB' }
    $script:budgetPath = Join-Path $ownedDirectory 'budget-config.json'
    [IO.File]::WriteAllBytes($script:budgetPath,[IO.File]::ReadAllBytes($budget.FullName))
  }
  $jsonExit = Invoke-Review 'json'
  $keys = @('files','added','modified','renamed','deleted','passed','blocked','errors','unsupported','introduced','existing','resolved','uncertain')
  $report = Read-ValidatedReport 'review.json' 'git-review' $jsonExit $keys
  $state = $report['status']
  $counts = $report['summary']
  $htmlExit = Invoke-Review 'html'
  if ($htmlExit -ne $jsonExit) { throw 'JSON and HTML review exits disagree' }
  $html = Read-ReportFile 'review.html'
  if (!$html.StartsWith('<!doctype html>')) { throw 'HTML report is missing its document header' }
  $summaryText = "## NBInspect Notebook review`n`nStatus: **$state**`n`nBase: ``$BaseCommit```n`nHead: ``$HeadCommit```n`n| Metric | Count |`n| --- | ---: |`n"
  foreach ($key in $keys) { $summaryText += "| $key | $($counts[$key]) |`n" }
  $summaryText += "`nDownload the JSON and offline HTML reports from the job artifacts. This compares the two event endpoints, not merge-base.`n"
  if ($script:budgetPath) {
    $summaryText += "`n## Notebook growth budget`n`nBudget analysis is pending. Allowances apply independently to each changed Notebook; deletions cannot offset another file's growth.`n"
    $budgetJsonExit = Invoke-Review 'json' 'budget-git' 'budget'
    $budgetKeys = @('files','added','modified','renamed','deleted','passed','blocked','errors')
    $budgetReport = Read-ValidatedReport 'budget.json' 'git-budget' $budgetJsonExit $budgetKeys
    $budgetHtmlExit = Invoke-Review 'html' 'budget-git' 'budget'
    if ($budgetHtmlExit -ne $budgetJsonExit) { throw 'JSON and HTML budget exits disagree' }
    $budgetHtml = Read-ReportFile 'budget.html'
    if (!$budgetHtml.StartsWith('<!doctype html>')) { throw 'Budget HTML report is missing its document header' }
    $summaryText = $summaryText.Replace('Budget analysis is pending.', "Budget status: **$($budgetReport['status'])**")
    $summaryText += "`n| Budget metric | Count |`n| --- | ---: |`n"
    foreach ($key in $budgetKeys) { $summaryText += "| $key | $($budgetReport['summary'][$key]) |`n" }
    $summaryText += "`nDownload budget.json, budget.html and budget-config.json with the risk review artifacts. This size gate does not replace publication-risk checks.`n"
    $exitCode = if ($jsonExit -eq 2 -or $budgetJsonExit -eq 2) {2} elseif ($jsonExit -eq 1 -or $budgetJsonExit -eq 1) {1} else {0}
  } else {
    $exitCode = $jsonExit
    $summaryText += "`nGrowth budget: not requested.`n"
  }
} catch {
  $summaryText += "`nAnalysis failed; any generated reports are partial and do not mean that all checks passed.`n"
  if ($ownedDirectory) {
    try { [IO.File]::WriteAllText((Join-Path $ownedDirectory 'run-error.txt'),$_.Exception.Message,$utf8) }
    catch { [Console]::Error.WriteLine('Cannot save the error log; failing the check.') }
  }
  [Console]::Error.WriteLine('NBInspect PR review failed; see run-error.txt and native logs. No successful review is claimed.')
} finally {
  $outcome = switch ($exitCode) { 0 {'passed'}; 1 {'blocked'}; default {'analysis failed'} }
  $summaryText = "Overall outcome: **$outcome**`n`n" + $summaryText
  try {
    if ($ownedDirectory) { [IO.File]::WriteAllText((Join-Path $ownedDirectory 'summary.md'),$summaryText,$utf8) }
    if ($StepSummary) { [IO.File]::AppendAllText($StepSummary,$summaryText,$utf8) }
  } catch {
    $exitCode = 2
    $failedSummary = $summaryText -replace 'Overall outcome: \*\*[^\r\n]+\*\*', 'Overall outcome: **analysis failed**'
    $failedSummary += "`nAnalysis failed: cannot write the job summary.`n"
    if ($ownedDirectory) {
      try { [IO.File]::WriteAllText((Join-Path $ownedDirectory 'summary.md'),$failedSummary,$utf8) } catch {}
    }
    [Console]::Error.WriteLine('Cannot write the review summary; failing the check.')
  }
}
exit $exitCode
