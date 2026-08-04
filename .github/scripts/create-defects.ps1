#Requires -Version 5.1
<#
.SYNOPSIS
    Query failed test case logs from the latest Test Manager execution and
    create a defect per failure. Test Manager forwards each defect to ADO via
    the connector configured on the project (TM-01).

.NOTES
    Expects the following environment variables to be set by the caller:
      ORCHESTRATOR_ORG      - UiPath organization (account) name
      ORCHESTRATOR_TENANT   - UiPath tenant name
      TM_PROJECT_NAME       - Test Manager project name
      UIPATH_TM_CLIENT_ID   - External app client id (TM scopes)
      UIPATH_TM_SECRET      - External app client secret

    The external application behind UIPATH_TM_CLIENT_ID must have ALL of these
    Application Scopes granted, otherwise the token/defect calls return 403:
      TM.Projects  TM.TestSets  TM.TestExecutions  TM.Defects
#>

$ErrorActionPreference = 'Stop'

$org         = $env:ORCHESTRATOR_ORG
$tenant      = $env:ORCHESTRATOR_TENANT
$projectName = $env:TM_PROJECT_NAME

# 0) fail fast with a clear message if any required input is missing
foreach ($name in 'ORCHESTRATOR_ORG','ORCHESTRATOR_TENANT','TM_PROJECT_NAME','UIPATH_TM_CLIENT_ID','UIPATH_TM_SECRET') {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Error "Required environment variable '$name' is not set."
        exit 1
    }
}

# 1) exchange client_id/secret for a token scoped to Test Manager
#    (this app needs TM.Projects / TM.TestSets / TM.TestExecutions / TM.Defects
#    under Application Scope(s), separate from the Orchestrator PAT)
$tmBody = @{
    grant_type    = "client_credentials"
    client_id     = $env:UIPATH_TM_CLIENT_ID
    client_secret = $env:UIPATH_TM_SECRET
    scope         = "TM.Projects TM.TestSets TM.TestExecutions TM.Defects"
}

$tokenResponse = Invoke-RestMethod -Method Post `
    -Uri "https://cloud.uipath.com/$org/identity_/connect/token" `
    -ContentType "application/x-www-form-urlencoded" `
    -Body $tmBody

$tmToken = $tokenResponse.access_token
if ([string]::IsNullOrWhiteSpace($tmToken)) {
    Write-Error "Failed to obtain a Test Manager access token. Check UIPATH_TM_CLIENT_ID/SECRET and that the app has the TM.* scopes granted."
    exit 1
}

$headers = @{ Authorization = "Bearer $tmToken" }
$tmApi   = "https://cloud.uipath.com/$org/$tenant/testmanager_/api/v2"

# 2) resolve the Test Manager project's GUID from its name
#    (the API takes a projectId GUID in the path, not a project key)
$encodedName = [uri]::EscapeDataString($projectName)
$projectSearch = Invoke-RestMethod -Headers $headers `
    -Uri "$tmApi/projects?search=$encodedName&top=50"

$project = $projectSearch.data | Where-Object { $_.name -eq $projectName } | Select-Object -First 1
if (-not $project) { $project = $projectSearch.data | Select-Object -First 1 }
if (-not $project) {
    Write-Error "No Test Manager project found matching name '$projectName'"
    exit 1
}
$projectId = $project.id

# 3) find the execution that just ran (most recent one for this project)
$orderBy = [uri]::EscapeDataString("created desc")
$executionSearch = Invoke-RestMethod -Headers $headers `
    -Uri "$tmApi/$projectId/testexecutions?top=1&orderby=$orderBy"

$execution = $executionSearch.data | Select-Object -First 1
if (-not $execution) {
    Write-Host "No test executions found for this project - nothing to file."
    exit 0
}

# 4) pull only the failed test case logs for that execution
#    (onlyFailed filters server-side - passed cases never come back)
$logsResult = Invoke-RestMethod -Headers $headers `
    -Uri "$tmApi/$projectId/testcaselogs/testexecution/$($execution.id)/paged?onlyFailed=true&top=200"

$failedLogs = $logsResult.data

if (-not $failedLogs -or $failedLogs.Count -eq 0) {
    Write-Host "No failed test cases in this execution - nothing to file."
    exit 0
}

# 5) create a defect per failure - Test Manager forwards this to ADO
#    via the connector configured on the project (TM-01)
foreach ($log in $failedLogs) {
    $body = @{
        testCaseId      = $log.testCaseId
        testExecutionId = $execution.id
    } | ConvertTo-Json

    Invoke-RestMethod -Headers $headers -Method Post `
        -Uri "$tmApi/$projectId/defects" `
        -ContentType "application/json" -Body $body

    Write-Host "Defect filed in ADO for test case $($log.testCaseId)"
}
