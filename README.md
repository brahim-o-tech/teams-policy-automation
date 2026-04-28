# teams-policy-automation
PowerShell automation for Microsoft Teams App Permission Policy assignment based on Azure AD group membership.

# Teams Policy Automation

# Overview

This repository provides a PowerShell script to automate Microsoft Teams App Permission Policy assignment based on Azure AD group membership.

In large environments, managing Teams policies manually is not scalable. This project demonstrates a structured and automated approach to enforce policy consistency.

---

# Problem Statement

Microsoft Teams does not support group-based assignment for App Permission Policies.

This limitation leads to:

- Manual user-by-user policy assignment
- Operational overhead for administrators
- Risk of inconsistent policy enforcement across users

---

# Solution

This script bridges this gap by:

- Retrieving users from Azure AD groups
- Comparing them with existing Teams policy assignments
- Automatically assigning the policy to missing users
- Providing execution logging and reporting

---

## ⚙️ Features

- Group-based user resolution (via Microsoft Graph)
- Bulk policy assignment
- WhatIf mode (safe simulation)
- CSV reporting (users to add, already compliant)
- Error handling per user

---

# Requirements

- PowerShell 7+
- Microsoft Graph PowerShell SDK
- MicrosoftTeams module
- Appropriate administrative permissions

---

# Usage

```powershell
.\src\Set-TeamsAppPolicyBulk.ps1 `
  -PolicyName "RestrictedApps" `
  -GroupNames "Group1","Group2" `
  -WhatIf
