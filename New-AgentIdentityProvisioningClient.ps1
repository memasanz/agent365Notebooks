#Requires -Version 7.0
<#
.SYNOPSIS
Creates the interactive Microsoft Graph client used by notebooks 02 and 04.
.DESCRIPTION
Requires Microsoft.Graph.Authentication and an account authorized to manage
app registrations. GrantAdminConsent additionally requires authority to grant
tenant-wide delegated consent (normally Cloud Application Administrator or
Application Administrator).

This bootstraps a normal single-tenant public client, not an agent blueprint.
Existing redirect URIs, API permissions, and consent scopes are preserved.
No credentials are created and .env is not modified.
IncludeAgent365Registration adds notebook 04's two administrative delegated
permissions. GrantAdminConsent remains a separate, explicit opt-in.
.EXAMPLE
.\New-AgentIdentityProvisioningClient.ps1 -TenantId YOUR-TENANT-GUID -WhatIf
.EXAMPLE
.\New-AgentIdentityProvisioningClient.ps1 -TenantId YOUR-TENANT-GUID
.EXAMPLE
.\New-AgentIdentityProvisioningClient.ps1 -TenantId YOUR-TENANT-GUID -GrantAdminConsent
.EXAMPLE
.\New-AgentIdentityProvisioningClient.ps1 -TenantId YOUR-TENANT-GUID -ApplicationObjectId EXISTING-APP-OBJECT-GUID
.EXAMPLE
.\New-AgentIdentityProvisioningClient.ps1 -TenantId YOUR-TENANT-GUID -IncludeAgent365Registration -WhatIf
.EXAMPLE
.\New-AgentIdentityProvisioningClient.ps1 -TenantId YOUR-TENANT-GUID -IncludeAgent365Registration -GrantAdminConsent
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [guid] $TenantId,

    [ValidateNotNullOrEmpty()]
    [string] $DisplayName = 'AgentIdentityNotebookProvisioner',

    [guid] $ApplicationObjectId = [guid]::Empty,

    [switch] $GrantAdminConsent,

    [switch] $IncludeAgent365Registration
)

$ErrorActionPreference = 'Stop'
if ($TenantId -eq [guid]::Empty) {
    throw 'TenantId must be a nonempty tenant GUID.'
}
if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
    throw 'Install the prerequisite first: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
Import-Module Microsoft.Graph.Authentication

$connectionScopes = @('Application.ReadWrite.All')
if ($GrantAdminConsent) {
    $connectionScopes += 'DelegatedPermissionGrant.ReadWrite.All'
}
Connect-MgGraph -TenantId $TenantId.ToString() -Scopes $connectionScopes -ContextScope Process -NoWelcome
if ([guid](Get-MgContext).TenantId -ne $TenantId) {
    throw 'Microsoft Graph is connected to a different tenant. No changes were made.'
}

$graphBase = 'https://graph.microsoft.com/v1.0'
$graphAppId = '00000003-0000-0000-c000-000000000000'
$redirectUri = 'http://localhost:8400'
$permissions = @(
    'User.Read'
    'AgentIdentityBlueprint.Create'
    'AgentIdentityBlueprint.Read.All'
    'AgentIdentityBlueprintPrincipal.Create'
    'AgentIdentityBlueprintPrincipal.Read.All'
    'AgentIdentity.Create.All'
    'AgentIdentity.Read.All'
)
if ($IncludeAgent365Registration) {
    $permissions += @('AgentRegistration.ReadWrite.All', 'User.ReadBasic.All')
}

function Get-GraphCollection {
    param([string] $Uri)
    while ($Uri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType Hashtable
        foreach ($item in $page['value']) {
            $item
        }
        $Uri = $page['@odata.nextLink']
        if ($Uri -and -not $Uri.StartsWith("$graphBase/")) {
            throw 'Unexpected pagination URL outside Microsoft Graph v1.0.'
        }
    }
}

$graphPrincipals = @(Get-GraphCollection -Uri "$graphBase/servicePrincipals?`$filter=appId eq '$graphAppId'&`$select=id,oauth2PermissionScopes")
if ($graphPrincipals.Count -ne 1) {
    throw 'Could not uniquely resolve the Microsoft Graph service principal.'
}
$graphPrincipal = $graphPrincipals[0]
$newResourceAccess = @(
    foreach ($permission in $permissions) {
        $matches = @($graphPrincipal['oauth2PermissionScopes'] | Where-Object {
            $_['value'] -eq $permission -and $_['isEnabled']
        })
        if ($matches.Count -ne 1) {
            throw "Delegated permission '$permission' is unavailable in this tenant. No application changes were made."
        }
        @{ id = $matches[0]['id']; type = 'Scope' }
    }
)

$applicationSelect = 'id,appId,displayName,signInAudience,publicClient,requiredResourceAccess'
if ($ApplicationObjectId -ne [guid]::Empty) {
    $application = Invoke-MgGraphRequest -Method GET -Uri "$graphBase/applications/$ApplicationObjectId`?`$select=$applicationSelect" -OutputType Hashtable
} else {
    $filter = [uri]::EscapeDataString("displayName eq '$($DisplayName.Replace("'", "''"))'")
    $applications = @(Get-GraphCollection -Uri "$graphBase/applications?`$filter=$filter&`$select=$applicationSelect")
    if ($applications.Count -gt 1) {
        throw 'Multiple applications have this display name. Rerun with -ApplicationObjectId to select the intended app.'
    }
    $application = if ($applications.Count -eq 1) { $applications[0] } else { $null }
}
if ($application) {
    if ($application['signInAudience'] -ne 'AzureADMyOrg') {
        throw 'The existing application is not single-tenant. Use a dedicated single-tenant app instead.'
    }
    if ($application['@odata.type'] -and $application['@odata.type'] -ne '#microsoft.graph.application') {
        throw 'The selected object is not an ordinary app registration. Do not use an agent blueprint as the provisioning client.'
    }
}

$action = 'Create/reuse the public client, add notebook delegated permissions, and create/reuse its service principal'
if ($GrantAdminConsent) {
    $action += "; grant tenant-wide delegated consent for: $($permissions -join ', ')"
}
if (-not $PSCmdlet.ShouldProcess("$DisplayName in tenant $TenantId", $action)) {
    return
}

$requiredResourceAccess = @()
$redirectUris = @($redirectUri)
if ($application) {
    foreach ($resource in $application['requiredResourceAccess']) {
        if ($resource['resourceAppId'] -eq $graphAppId) {
            $newResourceAccess += @($resource['resourceAccess'])
        } else {
            $requiredResourceAccess += $resource
        }
    }
    if ($application['publicClient']) {
        $redirectUris += @($application['publicClient']['redirectUris'])
    }
}
$newResourceAccess = @($newResourceAccess | Group-Object { "$($_['id']):$($_['type'])" } | ForEach-Object {
    @{ id = $_.Group[0]['id']; type = $_.Group[0]['type'] }
})
$requiredResourceAccess += @{
    resourceAppId = $graphAppId
    resourceAccess = $newResourceAccess
}
$body = @{
    publicClient = @{ redirectUris = @($redirectUris | Sort-Object -Unique) }
    requiredResourceAccess = $requiredResourceAccess
}
if ($application) {
    $applicationId = $application['id']
    Invoke-MgGraphRequest -Method PATCH -Uri "$graphBase/applications/$applicationId" -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
    Write-Host "Configured existing application: $applicationId"
} else {
    $body['displayName'] = $DisplayName
    $body['signInAudience'] = 'AzureADMyOrg'
    $application = Invoke-MgGraphRequest -Method POST -Uri "$graphBase/applications" -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -OutputType Hashtable
    $applicationId = $application['id']
    Write-Host "Created application: $applicationId"
}
$clientId = $application['appId']
Write-Host "Application/client ID: $clientId"
Write-Host "If a later step fails, rerun with -ApplicationObjectId $applicationId to reuse this app."

$clientPrincipals = @(Get-GraphCollection -Uri "$graphBase/servicePrincipals?`$filter=appId eq '$clientId'&`$select=id,appId")
if ($clientPrincipals.Count -gt 1) {
    throw 'Multiple service principals found for the client application.'
}
if ($clientPrincipals.Count -eq 1) {
    $clientPrincipal = $clientPrincipals[0]
} else {
    $clientPrincipal = Invoke-MgGraphRequest -Method POST -Uri "$graphBase/servicePrincipals" -Body (@{ appId = $clientId } | ConvertTo-Json) -ContentType 'application/json' -OutputType Hashtable
}

if ($GrantAdminConsent) {
    $grantFilter = [uri]::EscapeDataString("clientId eq '$($clientPrincipal['id'])' and resourceId eq '$($graphPrincipal['id'])'")
    $grants = @(Get-GraphCollection -Uri "$graphBase/oauth2PermissionGrants?`$filter=$grantFilter" | Where-Object {
        $_['consentType'] -eq 'AllPrincipals'
    })
    if ($grants.Count -gt 1) {
        throw 'Multiple tenant-wide grants found; review the grants before proceeding.'
    }
    $scopeNames = @($permissions)
    if ($grants.Count -eq 1) {
        $scopeNames += @($grants[0]['scope'] -split ' ' | Where-Object { $_ })
    }
    $consentBody = @{ scope = ($scopeNames | Sort-Object -Unique) -join ' ' }
    if ($grants.Count -eq 1) {
        $grantId = $grants[0]['id']
        Invoke-MgGraphRequest -Method PATCH -Uri "$graphBase/oauth2PermissionGrants/$grantId" -Body ($consentBody | ConvertTo-Json) -ContentType 'application/json' | Out-Null
    } else {
        $consentBody['clientId'] = $clientPrincipal['id']
        $consentBody['resourceId'] = $graphPrincipal['id']
        $consentBody['consentType'] = 'AllPrincipals'
        Invoke-MgGraphRequest -Method POST -Uri "$graphBase/oauth2PermissionGrants" -Body ($consentBody | ConvertTo-Json) -ContentType 'application/json' | Out-Null
    }
    $verifiedGrants = @(Get-GraphCollection -Uri "$graphBase/oauth2PermissionGrants?`$filter=$grantFilter" | Where-Object {
        $_['consentType'] -eq 'AllPrincipals'
    })
    if ($verifiedGrants.Count -ne 1) {
        throw 'Could not verify the tenant-wide delegated consent grant.'
    }
    $grantedScopes = @($verifiedGrants[0]['scope'] -split ' ')
    if (@($permissions | Where-Object { $_ -notin $grantedScopes }).Count) {
        throw 'The consent grant is missing required notebook permissions.'
    }
}

$verifiedApp = Invoke-MgGraphRequest -Method GET -Uri "$graphBase/applications/$applicationId`?`$select=$applicationSelect" -OutputType Hashtable
$configuredScopeIds = @(
    foreach ($resource in $verifiedApp['requiredResourceAccess']) {
        if ($resource['resourceAppId'] -eq $graphAppId) {
            foreach ($access in $resource['resourceAccess']) {
                if ($access['type'] -eq 'Scope') { $access['id'] }
            }
        }
    }
)
if ($redirectUri -notin $verifiedApp['publicClient']['redirectUris'] -or
    @($newResourceAccess | Where-Object { $_['type'] -eq 'Scope' -and $_['id'] -notin $configuredScopeIds }).Count) {
    throw 'Read-back verification of the redirect URI or delegated permissions failed.'
}
$verifiedPrincipal = Invoke-MgGraphRequest -Method GET -Uri "$graphBase/servicePrincipals/$($clientPrincipal['id'])?`$select=id,appId" -OutputType Hashtable
if ($verifiedPrincipal['appId'] -ne $clientId) {
    throw 'The service principal does not reference the expected application.'
}

if (-not $GrantAdminConsent) {
    Write-Warning 'Admin consent was not granted by this script. Have an administrator grant the declared Graph delegated permissions in Entra, or rerun with -GrantAdminConsent as an authorized administrator.'
}
Write-Host "`nCopy these values into .env (preserve your other settings):"
Write-Host "ENTRA_TENANT_ID=$TenantId"
Write-Host "ENTRA_PROVISIONING_CLIENT_ID=$clientId"
[pscustomobject]@{
    TenantId = $TenantId.ToString()
    ApplicationObjectId = $applicationId
    ClientId = $clientId
    ServicePrincipalObjectId = $clientPrincipal['id']
    AdminConsentGranted = [bool]$GrantAdminConsent
}
