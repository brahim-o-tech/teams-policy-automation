
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$PolicyName,

    [Parameter(Mandatory)]
    [string[]]$GroupNames,

    [string]$OutputPath = ".\output",

    [switch]$WhatIf
)

# -------------------------------
# Logging
# -------------------------------
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $log = "$time [$Level] $Message"
    Write-Output $log
}

# -------------------------------
# Init
# -------------------------------
if (!(Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

Write-Log "Starting Teams Policy Automation"

# -------------------------------
# Connect
# -------------------------------
Connect-MgGraph -Scopes "User.Read.All","Group.Read.All"
Connect-MicrosoftTeams

# -------------------------------
# Get AAD users
# -------------------------------
$aadUsers = @()

foreach ($group in $GroupNames) {
    Write-Log "Processing group: $group"

    $grp = Get-MgGroup -Filter "displayName eq '$group'"
    $members = Get-MgGroupMember -GroupId $grp.Id

    foreach ($m in $members) {
        $aadUsers += $m.UserPrincipalName
    }
}

$aadUsers = $aadUsers | Sort-Object -Unique

# -------------------------------
# Get Teams policy users
# -------------------------------
$policyUsers = Get-CsOnlineUser -Filter "TeamsAppPermissionPolicy -eq '$PolicyName'" |
               Select-Object -ExpandProperty UserPrincipalName

# -------------------------------
# Compare
# -------------------------------
$usersToAdd = $aadUsers | Where-Object { $_ -notin $policyUsers }
$alreadyCompliant = $aadUsers | Where-Object { $_ -in $policyUsers }

Write-Log "Users to add: $($usersToAdd.Count)"
Write-Log "Already compliant: $($alreadyCompliant.Count)"

# -------------------------------
# Export report
# -------------------------------
$usersToAdd | Export-Csv "$OutputPath\UsersToAdd.csv" -NoTypeInformation
$alreadyCompliant | Export-Csv "$OutputPath\AlreadyCompliant.csv" -NoTypeInformation

# -------------------------------
# Apply policy
# -------------------------------
foreach ($user in $usersToAdd) {

    if ($WhatIf) {
        Write-Log "SIMULATION: Would assign policy to $user"
    }
    else {
        try {
            Grant-CsTeamsAppPermissionPolicy -Identity $user -PolicyName $PolicyName
            Write-Log "Assigned policy to $user"
        }
        catch {
            Write-Log "Error assigning policy to $user : $_" "ERROR"
        }
    }
}

Write-Log "Execution completed"
