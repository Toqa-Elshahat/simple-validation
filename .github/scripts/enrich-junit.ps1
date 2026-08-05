#Requires -Version 5.1
<#
.SYNOPSIS
    Enrich an existing JUnit results.xml (produced by `uipcli test run --out junit`)
    with Test Manager execution details and Orchestrator robot logs.

    For every <testcase> it:
      - matches the case to its Test Manager test-case log (by name / objKey),
      - fetches the robot logs for that case by jobKey,
      - writes execution details + full robot logs into <system-out>,
      - appends the error-level log lines (the assertion failure) into the
        existing <failure> body so dorny/test-reporter shows *why* it failed.

.NOTES
    Environment variables (same app/secrets as the other scripts):
      ORCHESTRATOR_ORG      - UiPath organization (account) name
      ORCHESTRATOR_TENANT   - UiPath tenant name
      ORCHESTRATOR_FOLDER   - Orchestrator folder the job ran in (e.g. Shared)
      TM_PROJECT_NAME       - Test Manager project name
      UIPATH_TM_CLIENT_ID   - External app client id
      UIPATH_TM_SECRET      - External app client secret

    Optional:
      RESULTS_XML           - path to results.xml (default .\results\results.xml)

    App needs: TM.Projects TM.TestSets TM.TestExecutions OR.Folders OR.Monitoring
    and folder "View Logs" permission for robot logs to be retrievable.
    If robot logs can't be fetched the script still runs - it just injects the
    execution-detail summary and leaves a note.
#>

$ErrorActionPreference = 'Stop'

$org         = $env:ORCHESTRATOR_ORG
$tenant      = $env:ORCHESTRATOR_TENANT
$folderName  = $env:ORCHESTRATOR_FOLDER
$projectName = $env:TM_PROJECT_NAME
$resultsXml  = if ($env:RESULTS_XML) { $env:RESULTS_XML } else { "$PWD\results\results.xml" }

foreach ($name in 'ORCHESTRATOR_ORG','ORCHESTRATOR_TENANT','TM_PROJECT_NAME','UIPATH_TM_CLIENT_ID','UIPATH_TM_SECRET') {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        Write-Error "Required environment variable '$name' is not set."
        exit 1
    }
}

if (-not (Test-Path $resultsXml)) {
    Write-Warning "results.xml not found at '$resultsXml' - nothing to enrich."
    exit 0
}

# --- helpers -------------------------------------------------------------
function Get-Api([string]$uri, [hashtable]$headers) {
    try { return Invoke-RestMethod -Headers $headers -Uri $uri -ErrorAction Stop }
    catch { Write-Warning "GET $uri failed: $($_.Exception.Message)"; return $null }
}
function First-Prop([object]$obj, [string[]]$names) {
    foreach ($n in $names) {
        if ($obj -and $obj.PSObject.Properties.Name -contains $n -and $null -ne $obj.$n -and "$($obj.$n)" -ne "") {
            return $obj.$n
        }
    }
    return $null
}
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
    } catch { Write-Warning "Token request failed for scope '$scope': $($_.Exception.Message)"; return $null }
}

# --- auth (fall back to TM-only if OR scopes aren't granted) --------------
$hasOrchScopes = $true
$token = Get-Token "TM.Projects TM.TestSets TM.TestExecutions OR.Folders OR.Monitoring"
if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Warning "Falling back to TM-only token; robot logs will be skipped."
    $hasOrchScopes = $false
    $token = Get-Token "TM.Projects TM.TestSets TM.TestExecutions"
}
if ([string]::IsNullOrWhiteSpace($token)) { Write-Error "Failed to obtain an access token."; exit 1 }

$headers = @{ Authorization = "Bearer $token" }
$tmApi   = "https://cloud.uipath.com/$org/$tenant/testmanager_/api/v2"
$orchApi = "https://cloud.uipath.com/$org/$tenant/orchestrator_"

# --- resolve folder id for robot-log scoping ------------------------------
$folderId = $null
if ($folderName -and $hasOrchScopes) {
    $encFolder = $folderName.Replace("'", "''")
    $folders = Get-Api "$orchApi/odata/Folders?`$filter=DisplayName eq '$encFolder'" $headers
    $folderId = $folders.value | Select-Object -First 1 -ExpandProperty Id -ErrorAction SilentlyContinue
    if (-not $folderId) { Write-Warning "Could not resolve Orchestrator folder id for '$folderName'." }
}

# --- resolve project + latest execution + logs ----------------------------
$encodedName = [uri]::EscapeDataString($projectName)
$projectSearch = Get-Api "$tmApi/projects?search=$encodedName&top=50" $headers
$project = $projectSearch.data | Where-Object { $_.name -eq $projectName } | Select-Object -First 1
if (-not $project) { $project = $projectSearch.data | Select-Object -First 1 }
if (-not $project) { Write-Error "No Test Manager project found matching '$projectName'"; exit 1 }
$projectId = $project.id

$orderBy = [uri]::EscapeDataString("created desc")
$execSearch = Get-Api "$tmApi/$projectId/testexecutions?top=1&orderby=$orderBy" $headers
$execution  = $execSearch.data | Select-Object -First 1
if (-not $execution) { Write-Warning "No test executions found - leaving results.xml untouched."; exit 0 }

$logsResult = Get-Api "$tmApi/$projectId/testcaselogs/testexecution/$($execution.id)/paged?top=500" $headers
$logs = @($logsResult.data)

# --- build a name -> log lookup (several name shapes) ----------------------
$byName = @{}
foreach ($log in $logs) {
    $names = @(
        $log.testCase.name,
        $log.testCase.packageEntryPointName,
        ($log.testCase.automationTestCaseName -replace '\.xaml$','')
    )
    foreach ($n in $names) {
        if ($n) { $byName[$n.ToString().ToLower()] = $log }
    }
}

function Resolve-Log([string]$testcaseName) {
    if (-not $testcaseName) { return $null }
    $k = $testcaseName.ToLower()
    if ($byName.ContainsKey($k)) { return $byName[$k] }
    # try last dotted segment: "simple.validation_Tests.webtestcase" -> "webtestcase"
    if ($k -match '\.([^.]+)$' -and $byName.ContainsKey($matches[1])) { return $byName[$matches[1]] }
    # try stripping .xaml
    $k2 = ($k -replace '\.xaml$','')
    if ($byName.ContainsKey($k2)) { return $byName[$k2] }
    return $null
}

# --- robot logs by jobKey --------------------------------------------------
function Get-RobotLogs([string]$jobKey) {
    if (-not $hasOrchScopes) { return $null }
    if (-not $jobKey -or $jobKey -eq "00000000-0000-0000-0000-000000000000") { return $null }
    $h = @{ Authorization = "Bearer $token" }
    if ($folderId) { $h['X-UIPATH-OrganizationUnitId'] = "$folderId" }
    $uri = "$orchApi/odata/RobotLogs?`$filter=JobKey eq $jobKey&`$orderby=TimeStamp asc&`$top=500"
    $res = Get-Api $uri $h
    if ($res) { return $res.value }
    return $null
}

# --- load + enrich the JUnit XML ------------------------------------------
[xml]$doc = Get-Content -Raw -Path $resultsXml
$cases = $doc.SelectNodes("//testcase")
Write-Host "Enriching $($cases.Count) <testcase> nodes from execution $($execution.id)..."

$enriched = 0
foreach ($node in $cases) {
    $caseName = $node.GetAttribute("name")
    $log = Resolve-Log $caseName
    if (-not $log) { Write-Warning "No TM log matched testcase '$caseName'."; continue }

    $robotLogs = Get-RobotLogs (First-Prop $log @('jobKey'))

    # --- execution-detail summary text ---
    $sbOut = New-Object System.Text.StringBuilder
    [void]$sbOut.AppendLine("=== Execution details ===")
    foreach ($pair in @(
        @('Test case',        (First-Prop $log @('testCase')).name),
        @('Object key',       (First-Prop $log @('testCase')).objKey),
        @('Result',           (First-Prop $log @('result'))),
        @('Business result',  (First-Prop $log @('businessResult'))),
        @('Started',          (First-Prop $log @('executionStart'))),
        @('Ended',            (First-Prop $log @('executionEnd'))),
        @('Robot',            (First-Prop $log @('robotName'))),
        @('Host machine',     (First-Prop $log @('hostMachineName'))),
        @('Job key',          (First-Prop $log @('jobKey'))),
        @('Postcondition met',(First-Prop $log @('isPostConditionMet'))),
        @('Info',             (First-Prop $log @('info')))
    )) {
        if ($null -ne $pair[1] -and "$($pair[1])" -ne "") {
            [void]$sbOut.AppendLine(("{0,-18}: {1}" -f $pair[0], $pair[1]))
        }
    }

    [void]$sbOut.AppendLine("")
    [void]$sbOut.AppendLine("=== Robot logs ===")
    if ($robotLogs) {
        foreach ($e in $robotLogs) {
            [void]$sbOut.AppendLine(("[{0}] [{1}] {2}" -f $e.TimeStamp, $e.Level, $e.Message))
        }
    } elseif (-not $hasOrchScopes) {
        [void]$sbOut.AppendLine("(robot logs skipped - app lacks OR.Folders/OR.Monitoring scopes)")
    } else {
        [void]$sbOut.AppendLine("(no robot logs returned - check OR.Monitoring scope + folder 'View Logs' permission)")
    }

    # --- write <system-out> (replace body, keep node) ---
    $so = $node.SelectSingleNode("system-out")
    if (-not $so) { $so = $doc.CreateElement("system-out"); [void]$node.AppendChild($so) }
    while ($so.HasChildNodes) { [void]$so.RemoveChild($so.FirstChild) }
    [void]$so.AppendChild($doc.CreateCDataSection($sbOut.ToString()))

    # --- enrich <failure> body with error-level lines (the assertion) ---
    $fail = $node.SelectSingleNode("failure")
    if (-not $fail) { $fail = $node.SelectSingleNode("error") }
    if ($fail) {
        $errLines = @()
        if ($robotLogs) {
            $errLines = $robotLogs |
                Where-Object { $_.Level -match '(?i)error|fatal' -or $_.Message -match '(?i)assert|verif|expected|actual' } |
                ForEach-Object { "[{0}] {1}" -f $_.Level, $_.Message }
        }
        $origMsg = $fail.GetAttribute("message")
        $body = @()
        if ($origMsg) { $body += $origMsg }
        if ($errLines.Count -gt 0) {
            $body += ""
            $body += "--- Assertion / error log ---"
            $body += $errLines
        }
        while ($fail.HasChildNodes) { [void]$fail.RemoveChild($fail.FirstChild) }
        [void]$fail.AppendChild($doc.CreateCDataSection(($body -join "`n")))
    }

    $enriched++
}

$doc.Save($resultsXml)
Write-Host "Enriched $enriched of $($cases.Count) test cases -> $resultsXml"
