#Requires -Version 5.1
<#
.SYNOPSIS
    Generate a human-readable HTML report for the latest Test Manager execution.
    Renders, per test case: Assertions, Logs, Healing Logs, Execution details,
    and Attachments.

.NOTES
    Expects these environment variables (same as create-defects.ps1):
      ORCHESTRATOR_ORG      - UiPath organization (account) name
      ORCHESTRATOR_TENANT   - UiPath tenant name
      TM_PROJECT_NAME       - Test Manager project name
      UIPATH_TM_CLIENT_ID   - External app client id
      UIPATH_TM_SECRET      - External app client secret

    Optional:
      REPORT_OUT            - output path (default .\results\report.html)

    Healing Logs are populated by UiPath only for Test Cloud users; on standard
    Orchestrator that section will be empty.

    The external app needs: TM.Projects TM.TestSets TM.TestExecutions and, for
    robot logs/screenshots, OR.Monitoring + folder "View Logs" permission.
#>

$ErrorActionPreference = 'Stop'

$org         = $env:ORCHESTRATOR_ORG
$tenant      = $env:ORCHESTRATOR_TENANT
$projectName = $env:TM_PROJECT_NAME
$outPath     = if ($env:REPORT_OUT) { $env:REPORT_OUT } else { "$PWD\results\report.html" }

foreach ($name in 'ORCHESTRATOR_ORG','ORCHESTRATOR_TENANT','TM_PROJECT_NAME','UIPATH_TM_CLIENT_ID','UIPATH_TM_SECRET') {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        Write-Error "Required environment variable '$name' is not set."
        exit 1
    }
}

# --- helpers -------------------------------------------------------------
function HtmlEncode([object]$s) {
    if ($null -eq $s) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$s)
}

# GET that degrades gracefully: returns $null (and warns) instead of throwing,
# so a 403/404 on one optional section never kills the whole report.
function Get-Tm([string]$uri, [hashtable]$headers) {
    try {
        return Invoke-RestMethod -Headers $headers -Uri $uri -ErrorAction Stop
    } catch {
        Write-Warning "GET $uri failed: $($_.Exception.Message)"
        return $null
    }
}

# Return the first property that exists on $obj from a list of candidate names.
function First-Prop([object]$obj, [string[]]$names) {
    foreach ($n in $names) {
        if ($obj -and $obj.PSObject.Properties.Name -contains $n -and $obj.$n) {
            return $obj.$n
        }
    }
    return $null
}

# --- auth ----------------------------------------------------------------
$tokenResponse = Invoke-RestMethod -Method Post `
    -Uri "https://cloud.uipath.com/$org/identity_/connect/token" `
    -ContentType "application/x-www-form-urlencoded" `
    -Body @{
        grant_type    = "client_credentials"
        client_id     = $env:UIPATH_TM_CLIENT_ID
        client_secret = $env:UIPATH_TM_SECRET
        scope         = "TM.Projects TM.TestSets TM.TestExecutions TM.Defects"
    }

$tmToken = $tokenResponse.access_token
if ([string]::IsNullOrWhiteSpace($tmToken)) {
    Write-Error "Failed to obtain a Test Manager access token."
    exit 1
}
$headers = @{ Authorization = "Bearer $tmToken" }
$tmApi   = "https://cloud.uipath.com/$org/$tenant/testmanager_/api/v2"
$tmUi    = "https://cloud.uipath.com/$org/$tenant/testmanager_"

# --- resolve project + latest execution ----------------------------------
$encodedName = [uri]::EscapeDataString($projectName)
$projectSearch = Get-Tm "$tmApi/projects?search=$encodedName&top=50" $headers
$project = $projectSearch.data | Where-Object { $_.name -eq $projectName } | Select-Object -First 1
if (-not $project) { $project = $projectSearch.data | Select-Object -First 1 }
if (-not $project) { Write-Error "No Test Manager project found matching '$projectName'"; exit 1 }
$projectId = $project.id

$orderBy = [uri]::EscapeDataString("created desc")
$execSearch = Get-Tm "$tmApi/$projectId/testexecutions?top=1&orderby=$orderBy" $headers
$execution  = $execSearch.data | Select-Object -First 1
if (-not $execution) { Write-Error "No test executions found for project '$projectName'."; exit 1 }

# all test case logs for this execution (not only failed - we want the full report)
$logsResult = Get-Tm "$tmApi/$projectId/testcaselogs/testexecution/$($execution.id)/paged?top=500" $headers
$logs = @($logsResult.data)

# --- build HTML ----------------------------------------------------------
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append(@"
<!doctype html><html><head><meta charset="utf-8">
<title>Test Manager Report - $(HtmlEncode $projectName)</title>
<style>
  body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f4f5f7;color:#172b4d}
  header{background:#20252b;color:#fff;padding:20px 28px}
  header h1{margin:0 0 6px;font-size:20px}
  header .meta{font-size:13px;opacity:.85}
  .wrap{max-width:1100px;margin:24px auto;padding:0 20px}
  .case{background:#fff;border:1px solid #dfe1e6;border-radius:8px;margin:0 0 18px;overflow:hidden}
  .case>summary{list-style:none;cursor:pointer;padding:14px 18px;font-weight:600;display:flex;justify-content:space-between;align-items:center}
  .case>summary::-webkit-details-marker{display:none}
  .badge{font-size:12px;font-weight:700;padding:3px 10px;border-radius:12px}
  .pass{background:#e3fcef;color:#006644}.fail{background:#ffebe6;color:#bf2600}.other{background:#eae6ff;color:#403294}
  .body{padding:0 18px 16px;border-top:1px solid #f0f0f0}
  .section{margin:14px 0}
  .section h3{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:#5e6c84;margin:0 0 6px}
  table{border-collapse:collapse;width:100%;font-size:13px}
  th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #f0f0f0;vertical-align:top}
  pre{background:#f7f8f9;border:1px solid #eee;border-radius:6px;padding:10px;overflow:auto;font-size:12px;max-height:320px}
  a{color:#0052cc}
  .empty{color:#97a0af;font-style:italic;font-size:13px}
  details.raw summary{cursor:pointer;color:#5e6c84;font-size:12px}
</style></head><body>
<header>
  <h1>Test Manager Report - $(HtmlEncode $projectName)</h1>
  <div class="meta">
    Execution: $(HtmlEncode $execution.id) &nbsp;|&nbsp;
    Status: $(HtmlEncode (First-Prop $execution @('status','state'))) &nbsp;|&nbsp;
    <a style="color:#8ab4ff" href="$tmUi/$(HtmlEncode $project.key)/testexecutions/$(HtmlEncode $execution.id)">Open in Test Manager</a>
  </div>
</header>
<div class="wrap">
"@)

if ($logs.Count -eq 0) {
    [void]$sb.Append('<p class="empty">No test case logs found for this execution.</p>')
}

foreach ($log in $logs) {
    $name   = First-Prop $log @('testCaseName','name','testCaseUniqueId','testCaseId')
    $status = [string](First-Prop $log @('status','result','state'))
    $cls = switch -Regex ($status) { 'ass'{'pass';break} 'ail|error|cancel'{'fail';break} default{'other'} }

    [void]$sb.Append("<details class='case' open><summary><span>$(HtmlEncode $name)</span><span class='badge $cls'>$(HtmlEncode $status)</span></summary><div class='body'>")

    # --- Execution details ---
    [void]$sb.Append("<div class='section'><h3>Execution details</h3><table>")
    foreach ($f in @('projectName','releaseName','machineName','robotName','startTime','endTime','executionTime','inputArguments','outputArguments','preconditionState','postconditionState')) {
        $v = First-Prop $log @($f)
        if ($v) {
            if ($v -isnot [string]) { $v = ($v | ConvertTo-Json -Compress -Depth 6) }
            [void]$sb.Append("<tr><th>$(HtmlEncode $f)</th><td>$(HtmlEncode $v)</td></tr>")
        }
    }
    [void]$sb.Append("</table></div>")

    # --- Assertions ---
    $assertions = First-Prop $log @('assertions','testCaseAssertions')
    [void]$sb.Append("<div class='section'><h3>Assertions</h3>")
    if ($assertions) {
        [void]$sb.Append("<table><tr><th>Result</th><th>Message</th></tr>")
        foreach ($a in $assertions) {
            $ar = First-Prop $a @('status','result','passed')
            $am = First-Prop $a @('message','expression','name','description')
            [void]$sb.Append("<tr><td>$(HtmlEncode $ar)</td><td>$(HtmlEncode $am)</td></tr>")
        }
        [void]$sb.Append("</table>")
    } else { [void]$sb.Append("<p class='empty'>No assertion data on this log object.</p>") }
    [void]$sb.Append("</div>")

    # --- Logs (RobotLogs) ---
    $robotLogs = First-Prop $log @('robotLogs','logs','executionLog')
    [void]$sb.Append("<div class='section'><h3>Logs</h3>")
    if ($robotLogs) {
        $txt = if ($robotLogs -is [string]) { $robotLogs } else { ($robotLogs | ConvertTo-Json -Depth 6) }
        [void]$sb.Append("<pre>$(HtmlEncode $txt)</pre>")
    } else { [void]$sb.Append("<p class='empty'>No robot logs attached (check OR.Monitoring scope + folder View Logs permission).</p>") }
    [void]$sb.Append("</div>")

    # --- Healing Logs (Test Cloud only) ---
    $healing = First-Prop $log @('healingLogs','healing','selfHealingLogs')
    [void]$sb.Append("<div class='section'><h3>Healing Logs</h3>")
    if ($healing) {
        $txt = if ($healing -is [string]) { $healing } else { ($healing | ConvertTo-Json -Depth 6) }
        [void]$sb.Append("<pre>$(HtmlEncode $txt)</pre>")
    } else { [void]$sb.Append("<p class='empty'>No healing logs (available for Test Cloud users only).</p>") }
    [void]$sb.Append("</div>")

    # --- Attachments ---
    $attachments = First-Prop $log @('attachments','files')
    [void]$sb.Append("<div class='section'><h3>Attachments</h3>")
    if ($attachments) {
        [void]$sb.Append("<ul>")
        foreach ($at in $attachments) {
            $an = First-Prop $at @('name','fileName','title')
            $au = First-Prop $at @('url','downloadUrl','uri')
            if ($au) { [void]$sb.Append("<li><a href='$(HtmlEncode $au)'>$(HtmlEncode $an)</a></li>") }
            else     { [void]$sb.Append("<li>$(HtmlEncode $an)</li>") }
        }
        [void]$sb.Append("</ul>")
    } else { [void]$sb.Append("<p class='empty'>No attachments.</p>") }
    [void]$sb.Append("</div>")

    # --- raw fallback so nothing is lost even if a field name differs ---
    [void]$sb.Append("<details class='raw'><summary>Raw log object (JSON)</summary><pre>$(HtmlEncode ($log | ConvertTo-Json -Depth 8))</pre></details>")

    [void]$sb.Append("</div></details>")
}

[void]$sb.Append("</div></body></html>")

$dir = Split-Path -Parent $outPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[System.IO.File]::WriteAllText($outPath, $sb.ToString(), [System.Text.Encoding]::UTF8)
Write-Host "Report written to $outPath  ($($logs.Count) test cases)"
