<#
.SYNOPSIS
    Synchronizes a Teams App Permission Policy with one or more Azure AD groups.

.DESCRIPTION
    This script connects to Azure AD (legacy) and Microsoft Teams, retrieves members
    from specified AAD groups, compares them with the current Teams App Permission
    Policy assignments, and synchronizes membership bidirectionally:
      - Adds users present in AAD groups but missing from the Teams policy.
      - Removes users present in the Teams policy but absent from AAD groups (if -RemoveOrphans is used).

    Batch assignment is used by default for performance (up to $BatchSize users per job).
    Falls back to individual Grant-Cs* assignment if the batch operation fails.

    A full transcript and per-step CSV exports are generated in the output directory.

.PARAMETER PolicyName
    Name of the Teams App Permission Policy to synchronize.
    Example: "Teams-PermissionPolicy01"

.PARAMETER GroupNames
    One or more Azure AD group display names to use as the source of truth.
    Example: @("AAD-GROUP1", "AAD-GROUP2")

.PARAMETER SetupPolicyFilter
    Optional. If provided, only users assigned this Teams App Setup Policy will be
    considered for assignment. Leave empty to skip this filter.
    Example: "TeamsAppSetupPolicy-01"

.PARAMETER OutputPath
    Directory where CSV reports and the transcript will be saved.
    Defaults to ".\output" relative to the script location.

.PARAMETER BatchSize
    Number of users per batch assignment job. Max supported by Teams is 5000.
    Defaults to 1000.

.PARAMETER RemoveOrphans
    Switch. If set, users found in the Teams policy but absent from the AAD groups
    will have the policy removed (set to Global/default).

.PARAMETER WhatIf
    Switch. Simulates all assignment/removal operations without making changes.

.EXAMPLE
    .\Set-TeamsAppPermPolicyBulk.ps1 `
        -PolicyName "Teams-PermissionPolicy01" `
        -GroupNames @("AAD-GROUP1", "AAD-GROUP2") `
        -SetupPolicyFilter "TeamsAppSetupPolicy-01" `
        -RemoveOrphans `
        -WhatIf

.EXAMPLE
    .\Set-TeamsAppPermPolicyBulk.ps1 `
        -PolicyName "Teams-PermissionPolicy01" `
        -GroupNames "AAD-GROUP1" `
        -OutputPath "C:\Reports\TeamsSync"

.NOTES
    Author      : Brahim O.
    Version     : 2.0
    Requires    : AzureAD module, MicrosoftTeams module
    Permissions : AzureAD read, Teams policy assignment
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)]
    [string]$PolicyName,

    [Parameter(Mandatory)]
    [string[]]$GroupNames,

    [string]$SetupPolicyFilter = "",

    [string]$OutputPath = "",

    [ValidateRange(1, 5000)]
    [int]$BatchSize = 1000,

    [switch]$RemoveOrphans,

    [switch]$WhatIf
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

# ============================================================
#  INIT
# ============================================================

if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "output"
}

$RunStamp   = Get-Date -Format "yyyy-MM-dd_HH-mm"
$CsvDir     = Join-Path $OutputPath "run-$RunStamp"
$Transcript = Join-Path $OutputPath "Sync-TeamsAppSetupPolicy-01-TeamsAppPermissionPolicy-$RunStamp.log"

foreach ($dir in @($OutputPath, $CsvDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
}

Start-Transcript -Path $Transcript

# ============================================================
#  LOGGING
# ============================================================

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","SIM")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry     = "$timestamp [$Level] $Message"
    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red     }
        "WARN"    { Write-Host $entry -ForegroundColor Yellow  }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green   }
        "SIM"     { Write-Host $entry -ForegroundColor Cyan    }
        default   { Write-Host $entry                          }
    }
}

# ============================================================
#  BANNER
# ============================================================

function Show-Banner {
    param ([string]$Title)
    $line = "*" * 65
    Write-Host ""
    Write-Host $line -ForegroundColor Yellow
    Write-Host ("*{0,-63}*" -f "  $Title") -ForegroundColor Yellow
    Write-Host $line -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================
#  PART I — Connect
# ============================================================

function Connect-Services {
    try {
        Write-Log "Connecting to AzureAD..."
        Connect-AzureAD | Out-Null
        Write-Log "Connected to AzureAD." "SUCCESS"

        Write-Log "Connecting to Microsoft Teams..."
        Connect-MicrosoftTeams | Out-Null
        Write-Log "Connected to Microsoft Teams." "SUCCESS"
    }
    catch {
        Write-Log "Connection failed: $_" "ERROR"
        Stop-Transcript
        exit 1
    }
}

Show-Banner "PART I  —  Connecting to AzureAD and Microsoft Teams"

foreach ($mod in @("AzureAD", "MicrosoftTeams")) {
    if (-not (Get-Module -Name $mod -ListAvailable)) {
        Write-Log "Required module '$mod' is not installed. Please install it and retry." "ERROR"
        Stop-Transcript
        exit 1
    }
    if (-not (Get-Module -Name $mod)) {
        Write-Log "Importing module '$mod'..."
        Import-Module $mod
    }
    else {
        Write-Log "Module '$mod' already loaded." "SUCCESS"
    }
}

Connect-Services

Write-Log "Script started — PSVersion: $($PSVersionTable.PSVersion) | ScriptRoot: $PSScriptRoot"
Write-Log "Policy      : $PolicyName"
Write-Log "Groups      : $($GroupNames -join ', ')"
Write-Log "SetupFilter : $(if ($SetupPolicyFilter) { $SetupPolicyFilter } else { '(none)' })"
Write-Log "RemoveOrph. : $RemoveOrphans | WhatIf: $WhatIf | BatchSize: $BatchSize"

# ============================================================
#  PART II — AAD Group members (enabled only)
# ============================================================

Show-Banner "PART II  —  AAD Group membership extraction"

function Get-AADGroupMembers {
    param ([string[]]$Groups)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($groupName in $Groups) {
        Write-Log "Processing group: $groupName"
        $grp = Get-AzureADGroup -All $true | Where-Object { $_.DisplayName -eq $groupName }

        if (-not $grp) {
            Write-Log "Group '$groupName' not found in AzureAD. Skipping." "WARN"
            continue
        }

        $members = Get-AzureADGroupMember -ObjectId $grp.ObjectId -All $true |
                   Where-Object { $_.ObjectType -eq "User" }

        foreach ($m in $members) {
            $enabled = (Get-AzureADUser -ObjectId $m.UserPrincipalName).AccountEnabled
            $results.Add([PSCustomObject]@{
                GroupName         = $groupName
                ObjectId          = $m.ObjectId
                DisplayName       = $m.DisplayName
                UserPrincipalName = $m.UserPrincipalName
                UserType          = $m.UserType
                AccountEnabled    = $enabled
            })
        }
        Write-Log "Group '$groupName' — $($members.Count) member(s) retrieved." "SUCCESS"
    }
    return $results
}

$allAADMembers     = Get-AADGroupMembers -Groups $GroupNames
$enabledAADMembers = $allAADMembers | Where-Object { $_.AccountEnabled -eq $true }

Write-Log "Total AAD members : $($allAADMembers.Count) | Enabled: $($enabledAADMembers.Count)" "SUCCESS"
$allAADMembers     | Export-Csv "$CsvDir\AAD-AllMembers-$RunStamp.csv"     -Delimiter "," -NoTypeInformation
$enabledAADMembers | Export-Csv "$CsvDir\AAD-EnabledMembers-$RunStamp.csv" -Delimiter "," -NoTypeInformation

# ============================================================
#  PART III — Teams policy members
# ============================================================

Show-Banner "PART III  —  Teams App Permission Policy extraction"

function Get-PolicyMembers {
    param ([string]$Policy)
    try {
        Write-Log "Querying Teams policy: $Policy ..."
        $users = Get-CsOnlineUser -Filter "TeamsAppPermissionPolicy -eq '$Policy'" |
                 Select-Object UserPrincipalName, TeamsAppPermissionPolicy -ErrorAction Stop
        Write-Log "Users found in policy '$Policy': $($users.Count)" "SUCCESS"
        return $users
    }
    catch {
        Write-Log "Failed to retrieve policy members: $_" "ERROR"
        Stop-Transcript
        exit 1
    }
}

$policyMembers = Get-PolicyMembers -Policy $PolicyName
$policyMembers | Export-Csv "$CsvDir\Teams-PolicyMembers-$RunStamp.csv" -Delimiter "," -NoTypeInformation

# ============================================================
#  PART IV — Compare AAD vs Teams policy
# ============================================================

Show-Banner "PART IV  —  Comparing AAD groups vs Teams policy"

# FIX BUG 3 — $comparison wrappé dans @() pour éviter $null si listes identiques
$comparison = @(Compare-Object `
    -ReferenceObject  ($enabledAADMembers | Select-Object -ExpandProperty UserPrincipalName | Sort-Object -Unique) `
    -DifferenceObject ($policyMembers     | Select-Object -ExpandProperty UserPrincipalName | Sort-Object -Unique) `
    -ErrorAction SilentlyContinue)

# FIX BUG 2 — cast en [string[]]@() pour éviter $null avec StrictMode
# <= : in AAD, NOT in Teams policy  => TO ADD
# => : in Teams policy, NOT in AAD  => TO REMOVE
[string[]]$toAdd    = @(($comparison | Where-Object { $_.SideIndicator -eq "<=" }).InputObject)
[string[]]$toRemove = @(($comparison | Where-Object { $_.SideIndicator -eq "=>" }).InputObject)

Write-Log "Users to ADD    (in AAD, missing from policy) : $($toAdd.Count)"    "SUCCESS"
Write-Log "Users to REMOVE (in policy, missing from AAD) : $($toRemove.Count)" "WARN"

$toAdd    | ForEach-Object { [PSCustomObject]@{ UserPrincipalName = $_ } } |
    Export-Csv "$CsvDir\Delta-ToAdd-$RunStamp.csv"    -Delimiter "," -NoTypeInformation
$toRemove | ForEach-Object { [PSCustomObject]@{ UserPrincipalName = $_ } } |
    Export-Csv "$CsvDir\Delta-ToRemove-$RunStamp.csv" -Delimiter "," -NoTypeInformation

# ============================================================
#  PART V — Teams user detail + SetupPolicy filter
# ============================================================

Show-Banner "PART V  —  Policy detail verification (SetupPolicy filter)"

function Get-TeamsUserDetails {
    param ([string[]]$UPNList)

    $details = [System.Collections.Generic.List[PSCustomObject]]::new()
    $total   = $UPNList.Count
    $i       = 0

    # FIX BUG 4 — guard contre $total = 0 (division par zero dans Write-Progress)
    if ($total -eq 0) {
        Write-Log "No users to fetch details for." "WARN"
        return $details
    }

    foreach ($upn in $UPNList) {
        $i++
        Write-Progress -Activity "Fetching Teams user details..." `
                       -Status "$i / $total" `
                       -PercentComplete ([int](($i / $total) * 100))
        try {
            $csUser   = Get-CsOnlineUser -Identity $upn -ErrorAction Stop |
                        Select-Object DisplayName, Identity, UserPrincipalName, AccountEnabled
            $policies = Get-CsUserPolicyAssignment -Identity $csUser.Identity

            # FIX BUG 5 — PolicySource est un objet, on extrait .AssignmentType explicitement
            $getPolicy = {
                param($type, $field)
                $match = $policies | Where-Object { $_.PolicyType -eq $type } | Select-Object -First 1
                if ($match) {
                    if ($field -eq "PolicySource") { ($match.PolicySource | Select-Object -First 1).AssignmentType }
                    else { $match.$field }
                }
                else { "Null" }
            }

            $details.Add([PSCustomObject]@{
                DisplayName                    = $csUser.DisplayName
                UserPrincipalName              = $csUser.UserPrincipalName
                AccountEnabled                 = $csUser.AccountEnabled
                TeamsAppSetupPolicy            = & $getPolicy "TeamsAppSetupPolicy"      "PolicyName"
                TeamsAppSetupPolicySource      = & $getPolicy "TeamsAppSetupPolicy"      "PolicySource"
                TeamsAppPermissionPolicy       = & $getPolicy "TeamsAppPermissionPolicy" "PolicyName"
                TeamsAppPermissionPolicySource = & $getPolicy "TeamsAppPermissionPolicy" "PolicySource"
            })
        }
        catch {
            Write-Log "Could not retrieve details for '$upn': $_" "WARN"
        }
    }

    Write-Progress -Activity "Fetching Teams user details..." -Completed
    return $details
}

$toAddDetails = Get-TeamsUserDetails -UPNList $toAdd
$toAddDetails | Export-Csv "$CsvDir\ToAdd-Details-$RunStamp.csv" -Delimiter "," -NoTypeInformation

if ($SetupPolicyFilter) {
    Write-Log "Applying SetupPolicy filter: '$SetupPolicyFilter'"
    $compliant    = $toAddDetails | Where-Object {
        $_.AccountEnabled -eq $true -and
        $_.TeamsAppSetupPolicy -eq $SetupPolicyFilter -and
        $_.TeamsAppPermissionPolicy -eq "Null"
    }
    $nonCompliant = $toAddDetails | Where-Object { $_ -notin $compliant }
    Write-Log "Compliant (will be assigned) : $($compliant.Count)"    "SUCCESS"
    Write-Log "Non-compliant (skipped)      : $($nonCompliant.Count)" "WARN"
    $nonCompliant | Export-Csv "$CsvDir\NonCompliant-$RunStamp.csv" -Delimiter "," -NoTypeInformation
    # FIX BUG 8 — cast en [string[]]@() pour éviter $null si $compliant est vide
    $finalToAdd = [string[]]@($compliant.UserPrincipalName)
}
else {
    Write-Log "No SetupPolicy filter applied — all enabled AAD users will be processed."
    $finalToAdd = [string[]]@($toAddDetails |
                  Where-Object { $_.AccountEnabled -eq $true } |
                  Select-Object -ExpandProperty UserPrincipalName)
}

Write-Log "Final users to assign : $($finalToAdd.Count)" "SUCCESS"

# ============================================================
#  PART VI — Batch assignment with fallback
# ============================================================

Show-Banner "PART VI  —  Assigning Teams App Permission Policy"

# FIX BUG 6 — timeout + deduplication pour éviter boucle infinie et double-export
function Wait-BatchJobs {
    param (
        [string[]]$JobIds,
        [int]$TimeoutMinutes = 60
    )

    $globalReport = [System.Collections.Generic.List[PSCustomObject]]::new()
    $running      = $true
    $startTime    = Get-Date
    $completedIds = [System.Collections.Generic.HashSet[string]]::new()

    while ($running) {
        $completed = 0

        if ((Get-Date) -gt $startTime.AddMinutes($TimeoutMinutes)) {
            Write-Log "Batch monitoring timeout reached ($TimeoutMinutes min). Exiting wait loop." "WARN"
            break
        }

        foreach ($jobId in $JobIds) {
            $jobData = Get-CsBatchPolicyAssignmentOperation -OperationId $jobId
            Write-Log "Job [$jobId] status: $($jobData.OverallStatus)"

            if ($jobData.OverallStatus -eq "Completed") {
                $completed++
                if (-not $completedIds.Contains($jobId)) {
                    $completedIds.Add($jobId) | Out-Null
                    $detail = Get-CsBatchPolicyAssignmentOperation -OperationId $jobId |
                              Select-Object -ExpandProperty UserState
                    foreach ($d in $detail) { $globalReport.Add($d) }
                }
            }
        }

        Write-Log "$completed / $($JobIds.Count) batch job(s) completed."

        if ($completed -eq $JobIds.Count) {
            $running = $false
            Write-Log "All batch jobs completed." "SUCCESS"
        }
        else {
            Start-Sleep -Seconds 30
        }
    }

    return $globalReport
}

# FIX BUG 7 — $WhatIf non hérité dans les fonctions, passé via -Simulate [bool]
function Invoke-PolicyAssignment {
    param (
        [string[]]$UPNList,
        [string]$Policy,
        [string]$Action,
        [bool]$Simulate = $false
    )

    if ($UPNList.Count -eq 0) {
        Write-Log "No users to process for action '$Action'. Skipping." "WARN"
        return
    }

    $policyTarget = if ($Action -eq "Remove") { $null } else { $Policy }
    $jobIds       = [System.Collections.Generic.List[string]]::new()
    $batchFailed  = $false

    try {
        Write-Log "Starting batch $Action for $($UPNList.Count) user(s) (BatchSize=$BatchSize)..."
        $offset = 0

        while ($offset -lt $UPNList.Count) {
            $end   = [Math]::Min($offset + $BatchSize - 1, $UPNList.Count - 1)
            $slice = $UPNList[$offset..$end]

            if ($Simulate) {
                Write-Log "SIMULATION: Batch $Action — users $offset to $($offset + $slice.Count - 1) | Policy: $policyTarget" "SIM"
                $offset += $BatchSize
                continue
            }

            $opName = "Batch-$Action-$Policy-offset$offset"
            $jobId  = New-CsBatchPolicyAssignmentOperation `
                          -PolicyType    TeamsAppPermissionPolicy `
                          -PolicyName    $policyTarget `
                          -Identity      $slice `
                          -OperationName $opName `
                          -ErrorAction   Stop

            Write-Log "Batch job started: [$jobId] ($($slice.Count) users)" "SUCCESS"
            $jobIds.Add($jobId)
            $offset += $BatchSize
        }

        if (-not $Simulate -and $jobIds.Count -gt 0) {
            $batchReport = Wait-BatchJobs -JobIds $jobIds
            $batchReport | Export-Csv "$CsvDir\BatchReport-$Action-$RunStamp.csv" -Delimiter "," -NoTypeInformation
            Write-Log "Batch $Action report exported." "SUCCESS"
        }
    }
    catch {
        Write-Log "Batch $Action failed: $_. Falling back to individual assignment." "WARN"
        $batchFailed = $true
    }

    if ($batchFailed) {
        Write-Log "Starting individual $Action fallback for $($UPNList.Count) user(s)..."
        $fallbackResults = [System.Collections.Generic.List[PSCustomObject]]::new()
        $i = 0

        foreach ($upn in $UPNList) {
            $i++
            Write-Progress -Activity "Individual policy $Action..." `
                           -Status "$i / $($UPNList.Count)" `
                           -PercentComplete ([int](($i / $UPNList.Count) * 100))

            if ($Simulate) {
                Write-Log "SIMULATION: Grant-CsTeamsAppPermissionPolicy -Identity $upn -PolicyName $policyTarget" "SIM"
                $fallbackResults.Add([PSCustomObject]@{ UPN = $upn; Status = "Simulated"; Action = $Action })
                continue
            }

            try {
                Grant-CsTeamsAppPermissionPolicy -Identity $upn -PolicyName $policyTarget -ErrorAction Stop
                Write-Log "[$Action] OK: $upn" "SUCCESS"
                $fallbackResults.Add([PSCustomObject]@{ UPN = $upn; Status = "Success"; Action = $Action })
            }
            catch {
                Write-Log "[$Action] FAILED: $upn — $_" "ERROR"
                $fallbackResults.Add([PSCustomObject]@{ UPN = $upn; Status = "Failed: $_"; Action = $Action })
            }
        }

        Write-Progress -Activity "Individual policy $Action..." -Completed
        $fallbackResults | Export-Csv "$CsvDir\FallbackReport-$Action-$RunStamp.csv" -Delimiter "," -NoTypeInformation
        Write-Log "Individual $Action report exported." "SUCCESS"
    }
}

Invoke-PolicyAssignment -UPNList $finalToAdd -Policy $PolicyName -Action "Assign" -Simulate $WhatIf.IsPresent

# ============================================================
#  PART VII — Remove orphans (optional)
# ============================================================

if ($RemoveOrphans) {
    Show-Banner "PART VII  —  Removing orphan users from Teams policy"
    Write-Log "RemoveOrphans enabled — $($toRemove.Count) user(s) will be unassigned." "WARN"
    Invoke-PolicyAssignment -UPNList $toRemove -Policy $PolicyName -Action "Remove" -Simulate $WhatIf.IsPresent
}
else {
    Show-Banner "PART VII  —  Remove orphans skipped (use -RemoveOrphans to enable)"
    Write-Log "Orphan users in policy (not in AAD): $($toRemove.Count) — no action taken." "WARN"
}

# ============================================================
#  SUMMARY
# ============================================================

Show-Banner "SUMMARY"

Write-Log "Policy targeted        : $PolicyName"
Write-Log "AAD groups parsed      : $($GroupNames -join ', ')"
Write-Log "Total AAD enabled      : $($enabledAADMembers.Count)"
Write-Log "Users assigned         : $($finalToAdd.Count)" "SUCCESS"
Write-Log "Orphans in policy      : $($toRemove.Count) $(if ($RemoveOrphans) { '(removed)' } else { '(skipped — use -RemoveOrphans)' })" "WARN"
Write-Log "WhatIf mode            : $WhatIf"
Write-Log "Reports saved to       : $CsvDir"
Write-Log "Transcript saved to    : $Transcript"
Write-Log "Script completed."

Stop-Transcript
