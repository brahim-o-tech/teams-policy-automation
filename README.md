# teams-policy-automation

> PowerShell automation for synchronizing Microsoft Teams App Permission Policies with Azure AD group memberships.

---

## Origin & Disclaimer

This script is derived from a production script used in a real Microsoft 365 environment.
It has been anonymized, refactored, and generalized for public release.

**It is provided as-is, without warranty of any kind, and has not been tested in this exact form.**
Always run with `-WhatIf` first to simulate changes before applying anything in production.
Use at your own risk.

---

## Overview

This script keeps a **Teams App Permission Policy** in sync with one or more **Azure AD groups**.
It compares group membership against current policy assignments and:

- ✅ **Adds** users present in AAD groups but missing from the Teams policy
- 🗑️ **Removes** users present in the Teams policy but absent from AAD groups *(optional, via `-RemoveOrphans`)*
- 🔍 **Filters** by Teams App Setup Policy before assigning *(optional, via `-SetupPolicyFilter`)*
- 🚀 Uses **batch assignment** for performance, with automatic fallback to individual assignment
- 📄 Exports **CSV reports** and a full **transcript** at every step

---

## Requirements

| Requirement | Details |
|---|---|
| PowerShell | 5.1 or later |
| Module | `AzureAD` (legacy) |
| Module | `MicrosoftTeams` |
| Permissions | Azure AD read, Teams policy assignment |

Install required modules if needed:

```powershell
Install-Module AzureAD
Install-Module MicrosoftTeams
```

---

## Usage

### Basic — add users only
```powershell
.\Set-TeamsAppPermPolicyBulk.ps1 `
    -PolicyName  "Teams-PermissionPolicy01" `
    -GroupNames  @("AAD-GROUP1", "AAD-GROUP2")
```

### With Setup Policy filter
```powershell
.\Set-TeamsAppPermPolicyBulk.ps1 `
    -PolicyName        "Teams-PermissionPolicy01" `
    -GroupNames        @("AAD-GROUP1", "AAD-GROUP2") `
    -SetupPolicyFilter "TeamsAppSetupPolicy-01"
```

### Full sync — add and remove orphans
```powershell
.\Set-TeamsAppPermPolicyBulk.ps1 `
    -PolicyName    "Teams-PermissionPolicy01" `
    -GroupNames    @("AAD-GROUP1", "AAD-GROUP2") `
    -RemoveOrphans
```

### Simulation — no changes applied ⚠️ always run this first
```powershell
.\Set-TeamsAppPermPolicyBulk.ps1 `
    -PolicyName "Teams-PermissionPolicy01" `
    -GroupNames @("AAD-GROUP1", "AAD-GROUP2") `
    -RemoveOrphans `
    -WhatIf
```

## How it works

| Step | Description |
|---|---|
| 1 | Connect to AzureAD and Microsoft Teams |
| 2 | Retrieve members from AAD groups — enabled accounts only |
| 3 | Retrieve current Teams App Permission Policy members |
| 4 | Compare both lists — identify users to add and to remove |
| 5 | Optional: filter by Teams App Setup Policy (`-SetupPolicyFilter`) |
| 6 | Assign policy via batch job (`New-CsBatchPolicyAssignmentOperation`) |
| 6b | Fallback: individual `Grant-CsTeamsAppPermissionPolicy` if batch fails |
| 7 | Optional: remove orphan users from policy (`-RemoveOrphans`) |
| 8 | Export summary report + full transcript |

---
## Output

Each run creates a timestamped folder under `OutputPath`:

| File | Description |
|---|---|
| `AAD-AllMembers-*.csv` | All AAD group members |
| `AAD-EnabledMembers-*.csv` | Enabled accounts only |
| `Teams-PolicyMembers-*.csv` | Current policy assignment |
| `Delta-ToAdd-*.csv` | Users to be added |
| `Delta-ToRemove-*.csv` | Users to be removed |
| `ToAdd-Details-*.csv` | Detailed Teams info per user |
| `NonCompliant-*.csv` | Skipped (setup policy mismatch) |
| `BatchReport-Assign-*.csv` | Batch job results (add) |
| `BatchReport-Remove-*.csv` | Batch job results (remove) |
| `FallbackReport-*.csv` | Individual fallback results |
| `Sync-...-*.log` | Full transcript |

---

## Repository structure

| Path | Description |
|---|---|
| `src/Set-TeamsAppPermPolicyBulk.ps1` | Main script (v2) |
| `examples/example-run.ps1` | Example invocations |
| `LICENSE` | License file |
| `README.md` | This file |

---

## Author

**Brahim O.**
Feel free to open issues or submit pull requests.

---

## License

This project is licensed under the terms of the [LICENSE](LICENSE) file.
