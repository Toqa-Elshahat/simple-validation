#Requires -Version 5.1
<#
.SYNOPSIS
    Generate a human-readable HTML report for the latest Test Manager execution.
    Renders, per test case: Execution details, Assertions, Logs (Orchestrator
    robot logs), Healing Logs, and Attachments.

.NOTES
    Expects these environment variables:
      ORCHESTRATOR_ORG      - UiPath organization (account) name
      ORCHESTRATOR_TENANT   - UiPath tenant name
      ORCHESTRATOR_FOLDER   - Orchestrator folder the job ran in (e.g. Shared)
      TM_PROJECT_NAME       - Test Manager project name
      UIPATH_TM_CLIENT_ID   - External app client id
      UIPATH_TM_SECRET      - External app client secret

    Optional:
      REPORT_OUT            - output path (default .\results\report.html)

    The external app must have these scopes granted (and folder "View Logs"):
      TM.Projects TM.TestSets TM.TestExecutions OR.Folders OR.Monitoring
    Robot logs (the Logs tab) come from Orchestrator and need OR.Monitoring +
    View Logs on the folder. Healing Logs exist for Test Cloud users only.
#>

$ErrorActionPreference = 'Stop'

$org         = $env:ORCHESTRATOR_ORG
$tenant      = $env:ORCHESTRATOR_TENANT
$folderName  = $env:ORCHESTRATOR_FOLDER
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

# GET that degrades gracefully: returns $null (and warns) instead of throwing.
function Get-Api([string]$uri, [hashtable]$headers) {
    try { return Invoke-RestMethod -Headers $headers -Uri $uri -ErrorAction Stop }
    catch { Write-Warning "GET $uri failed: $($_.Exception.Message)"; return $null }
}

# First property (from a candidate list) that exists and is non-empty on $obj.
function First-Prop([object]$obj, [string[]]$names) {
    foreach ($n in $names) {
        if ($obj -and $obj.PSObject.Properties.Name -contains $n -and $null -ne $obj.$n -and "$($obj.$n)" -ne "") {
            return $obj.$n
        }
    }
    return $null
}

# --- auth ----------------------------------------------------------------
# Token needs BOTH Test Manager and Orchestrator scopes: TM.* to read the
# execution/test-case logs, OR.Folders + OR.Monitoring to read robot logs.
# If the app hasn't been granted the OR.* scopes yet, the identity server
# rejects the whole request with invalid_scope - so fall back to TM-only so
# the report still generates (just without robot logs).
function Get-Token([string]$scope) {
    try {
        return (Invoke-RestMethod -Method Post `
            -Uri "https://cloud.uipath.com/$org/identity_/connect/token" `
            -ContentType "application/x-www-form-urlencoded" `
            -Body @{
                grant_type    = "client_credentials"
                client_id     = $env:UIPATH_TM_CLIENT_ID
                client_secret = $env:UIPATH_TM_SECRET
                scope         = $scope
            } -ErrorAction Stop).access_token
    } catch {
        Write-Warning "Token request failed for scope '$scope': $($_.Exception.Message)"
        return $null
    }
}

$hasOrchScopes = $true
$tmToken = Get-Token "TM.Projects TM.TestSets TM.TestExecutions OR.Folders OR.Monitoring"
if ([string]::IsNullOrWhiteSpace($tmToken)) {
    Write-Warning "Falling back to TM-only token; robot logs will be skipped. Grant OR.Folders + OR.Monitoring to the app to include them."
    $hasOrchScopes = $false
    $tmToken = Get-Token "TM.Projects TM.TestSets TM.TestExecutions"
}
if ([string]::IsNullOrWhiteSpace($tmToken)) {
    Write-Error "Failed to obtain an access token."
    exit 1
}
$headers = @{ Authorization = "Bearer $tmToken" }
$tmApi   = "https://cloud.uipath.com/$org/$tenant/testmanager_/api/v2"
$tmUi    = "https://cloud.uipath.com/$org/$tenant/testmanager_"
$orchApi = "https://cloud.uipath.com/$org/$tenant/orchestrator_"

# --- resolve Orchestrator folder id (for robot-log folder scoping) --------
$folderId = $null
if ($folderName -and $hasOrchScopes) {
    $encFolder = $folderName.Replace("'", "''")
    $folders = Get-Api "$orchApi/odata/Folders?`$filter=DisplayName eq '$encFolder'" $headers
    $folderId = $folders.value | Select-Object -First 1 -ExpandProperty Id -ErrorAction SilentlyContinue
    if (-not $folderId) { Write-Warning "Could not resolve Orchestrator folder id for '$folderName'; robot logs may be unavailable." }
}

# --- resolve TM project + latest execution --------------------------------
$encodedName = [uri]::EscapeDataString($projectName)
$projectSearch = Get-Api "$tmApi/projects?search=$encodedName&top=50" $headers
$project = $projectSearch.data | Where-Object { $_.name -eq $projectName } | Select-Object -First 1
if (-not $project) { $project = $projectSearch.data | Select-Object -First 1 }
if (-not $project) { Write-Error "No Test Manager project found matching '$projectName'"; exit 1 }
$projectId = $project.id

$orderBy = [uri]::EscapeDataString("created desc")
$execSearch = Get-Api "$tmApi/$projectId/testexecutions?top=1&orderby=$orderBy" $headers
$execution  = $execSearch.data | Select-Object -First 1
if (-not $execution) { Write-Error "No test executions found for project '$projectName'."; exit 1 }

$logsResult = Get-Api "$tmApi/$projectId/testcaselogs/testexecution/$($execution.id)/paged?top=500" $headers
$logs = @($logsResult.data)

# Derive the TM project key/prefix (e.g. "CPN") from a test case objKey so the
# "Open in Test Manager" links work (the projects payload has no key field).
$prefix = $null
foreach ($l in $logs) {
    $ok = $l.testCase.objKey
    if ($ok -and $ok -match '^([^:]+):') { $prefix = $matches[1]; break }
}
$execUi = if ($prefix) { "$tmUi/$prefix/testexecutions/$($execution.id)" } else { "$tmUi" }

# --- robot logs (Orchestrator) by jobKey ---------------------------------
function Get-RobotLogs([string]$jobKey) {
    if (-not $hasOrchScopes) { return $null }
    if (-not $jobKey -or $jobKey -eq "00000000-0000-0000-0000-000000000000") { return $null }
    $h = @{ Authorization = "Bearer $tmToken" }
    if ($folderId) { $h['X-UIPATH-OrganizationUnitId'] = "$folderId" }
    $uri = "$orchApi/odata/RobotLogs?`$filter=JobKey eq $jobKey&`$orderby=TimeStamp asc&`$top=500"
    $res = Get-Api $uri $h
    if ($res) { return $res.value }
    return $null
}

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
  td.k{width:190px;color:#5e6c84;font-weight:600}
  tr.err td{background:#fff5f4;color:#bf2600}
  tr.warn td{background:#fffae6}
  a{color:#0052cc}
  .empty{color:#97a0af;font-style:italic;font-size:13px}
  .lvl{font-weight:700;font-size:11px}
  details.raw summary{cursor:pointer;color:#5e6c84;font-size:12px}
</style></head><body>
<header>
  <h1>Test Manager Report - $(HtmlEncode $projectName)</h1>
  <div class="meta">
    Execution: $(HtmlEncode $execution.id) &nbsp;|&nbsp;
    Status: $(HtmlEncode (First-Prop $execution @('status','state'))) &nbsp;|&nbsp;
    <a style="color:#8ab4ff" href="$(HtmlEncode $execUi)">Open in Test Manager</a>
  </div>
</header>
<div class="wrap">
"@)

if ($logs.Count -eq 0) {
    [void]$sb.Append('<p class="empty">No test case logs found for this execution.</p>')
}

foreach ($log in $logs) {
    $tc     = $log.testCase
    $name   = First-Prop $tc @('name','packageEntryPointName','automationTestCaseName')
    if (-not $name) { $name = First-Prop $log @('automationTestCaseName','testCaseId') }
    $objKey = First-Prop $tc @('objKey')
    $status = [string](First-Prop $log @('result','businessResult','status'))
    $cls = switch -Regex ($status) { 'ass'{'pass';break} 'ail|error|cancel'{'fail';break} default{'other'} }
    $title = if ($objKey) { "$name  ($objKey)" } else { "$name" }

    [void]$sb.Append("<details class='case' open><summary><span>$(HtmlEncode $title)</span><span class='badge $cls'>$(HtmlEncode $status)</span></summary><div class='body'>")

    # --- Execution details (real fields from the paged log object) ---
    [void]$sb.Append("<div class='section'><h3>Execution details</h3><table>")
    $detailMap = [ordered]@{
        'Test case'        = $name
        'Object key'       = $objKey
        'Result'           = (First-Prop $log @('result'))
        'Business result'  = (First-Prop $log @('businessResult'))
        'Execution type'   = (First-Prop $log @('executionType'))
        'Started'          = (First-Prop $log @('executionStart'))
        'Ended'            = (First-Prop $log @('executionEnd'))
        'Robot'            = (First-Prop $log @('robotName'))
        'Host machine'     = (First-Prop $log @('hostMachineName'))
        'Test case version'= (First-Prop $log @('testCaseVersion'))
        'Job key'          = (First-Prop $log @('jobKey'))
        'Postcondition met'= (First-Prop $log @('isPostConditionMet'))
        'Has error'        = (First-Prop $log @('hasError'))
        'Info'             = (First-Prop $log @('info'))
        'Input arguments'  = (First-Prop $log @('inputArguments'))
        'Output arguments' = (First-Prop $log @('outputArguments'))
    }
    foreach ($k in $detailMap.Keys) {
        $v = $detailMap[$k]
        if ($null -ne $v -and "$v" -ne "") {
            [void]$sb.Append("<tr><td class='k'>$(HtmlEncode $k)</td><td>$(HtmlEncode $v)</td></tr>")
        }
    }
    [void]$sb.Append("</table></div>")

    # --- Fetch single-log detail (may carry assertions / attachments) ---
    $detail = Get-Api "$tmApi/$projectId/testcaselogs/$($log.id)" $headers
    $assertions  = First-Prop $detail @('assertions','testCaseAssertions')
    $attachments = First-Prop $detail @('attachments','files')
    $healing     = First-Prop $detail @('healingLogs','healing','selfHealingLogs')

    # --- Logs (Orchestrator robot logs by jobKey) ---
    $robotLogs = Get-RobotLogs (First-Prop $log @('jobKey'))

    # --- Assertions ---
    [void]$sb.Append("<div class='section'><h3>Assertions</h3>")
    if ($assertions) {
        [void]$sb.Append("<table><tr><th>Result</th><th>Message</th></tr>")
        foreach ($a in $assertions) {
            $ar = First-Prop $a @('status','result','passed','outcome')
            $am = First-Prop $a @('message','expression','name','description','actual')
            [void]$sb.Append("<tr><td>$(HtmlEncode $ar)</td><td>$(HtmlEncode $am)</td></tr>")
        }
        [void]$sb.Append("</table>")
    }
    elseif ($robotLogs) {
        # Fallback: surface assertion/verify-related log lines as the assertion view.
        $assertLines = $robotLogs | Where-Object { $_.Message -match '(?i)verif|assert|expected|actual' }
        if ($assertLines) {
            [void]$sb.Append("<table><tr><th>Level</th><th>Message</th></tr>")
            foreach ($e in $assertLines) {
                $rowcls = if ($e.Level -match '(?i)error|fatal') { "err" } elseif ($e.Level -match '(?i)warn') { "warn" } else { "" }
                [void]$sb.Append("<tr class='$rowcls'><td class='lvl'>$(HtmlEncode $e.Level)</td><td>$(HtmlEncode $e.Message)</td></tr>")
            }
            [void]$sb.Append("</table>")
        } else { [void]$sb.Append("<p class='empty'>No assertion entries found in logs.</p>") }
    }
    else { [void]$sb.Append("<p class='empty'>No assertion data available.</p>") }
    [void]$sb.Append("</div>")

    # --- Logs (RobotLogs) ---
    [void]$sb.Append("<div class='section'><h3>Logs</h3>")
    if ($robotLogs) {
        [void]$sb.Append("<table><tr><th>Time</th><th>Level</th><th>Message</th></tr>")
        foreach ($e in $robotLogs) {
            $rowcls = if ($e.Level -match '(?i)error|fatal') { "err" } elseif ($e.Level -match '(?i)warn') { "warn" } else { "" }
            [void]$sb.Append("<tr class='$rowcls'><td>$(HtmlEncode $e.TimeStamp)</td><td class='lvl'>$(HtmlEncode $e.Level)</td><td>$(HtmlEncode $e.Message)</td></tr>")
        }
        [void]$sb.Append("</table>")
    } else {
        [void]$sb.Append("<p class='empty'>No robot logs returned. Needs OR.Monitoring scope + folder 'View Logs' permission (and the job's folder must resolve).</p>")
    }
    [void]$sb.Append("</div>")

    # --- Healing Logs (Test Cloud only) ---
    [void]$sb.Append("<div class='section'><h3>Healing Logs</h3>")
    if ($healing) {
        $txt = if ($healing -is [string]) { $healing } else { ($healing | ConvertTo-Json -Depth 6) }
        [void]$sb.Append("<pre>$(HtmlEncode $txt)</pre>")
    } else { [void]$sb.Append("<p class='empty'>No healing logs (available for Test Cloud users only).</p>") }
    [void]$sb.Append("</div>")

    # --- Attachments ---
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

    [void]$sb.Append("</div></details>")
}

[void]$sb.Append("</div></body></html>")

$dir = Split-Path -Parent $outPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[System.IO.File]::WriteAllText($outPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Report written to $outPath  ($($logs.Count) test cases)"
