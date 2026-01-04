<#
POSTMIGRATE.PS1
Synopsis
PostMigrate.ps1 is run after the migration reboots have completed and the user signs into the PC.
DESCRIPTION
This script is used to update the device group tag in Entra ID and set the primary user in Intune and migrate the bitlocker recovery key. The device is then registered with AutoPilot.
USE
.\postMigrate.ps1 [-ForceRegisterTasks]
.OWNER
Steve Weiner
.CONTRIBUTORS
Logan Lautt

.PARAMETER ForceRegisterTasks
If specified, the script will (re)register the scheduled tasks for post-migration steps.
If omitted, scheduled task registration is skipped.
#>

param(
    [switch]$ForceRegisterTasks
)

$ErrorActionPreference = "SilentlyContinue"

function log {
    param([string]$message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "$ts $message"
}

# Load config
$config = Get-Content "C:\Migration\PostMigrate\config_modified.json" | ConvertFrom-Json

# Start logging
Start-Transcript -Path "$($config.logPath)\postMigrate.log" -Verbose
log "Starting PostMigrate.ps1..."

# Disable postMigrate task
Disable-ScheduledTask -TaskName "postMigrate" -ErrorAction SilentlyContinue
log "Disabled postMigrate task"

# Enable displayLastUserName
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DontDisplayLastUserName" -Value 0 -Verbose
log "Enabled displayLastUserName"

# Authenticate to Graph
function msGraphAuthenticate {
    param(
        [string]$tenantName,
        [string]$clientId,
        [string]$clientSecret
    )
    $headers = @{ "Content-Type" = "application/x-www-form-urlencoded" }
    $body = "grant_type=client_credentials&scope=https://graph.microsoft.com/.default"
    $body += "&client_id=$clientId&client_secret=$clientSecret"
    $response = Invoke-RestMethod "https://login.microsoftonline.com/$tenantName/oauth2/v2.0/token" -Method 'POST' -Headers $headers -Body $body
    $token = "Bearer $($response.access_token)"
    return @{ "Authorization" = $token; "Content-Type" = "application/json" }
}

if ($config.targetTenant.tenantName) {
    log "Authenticating to target tenant..."
    $headers = msGraphAuthenticate -tenantName $config.targetTenant.tenantName -clientId $config.targetTenant.clientId -clientSecret $config.targetTenant.clientSecret
    log "Authenticated to target tenant"
} else {
    log "Authenticating to source tenant..."
    $headers = msGraphAuthenticate -tenantName $config.sourceTenant.tenantName -clientId $config.sourceTenant.clientId -clientSecret $config.sourceTenant.clientSecret
    log "Authenticated to source tenant"
}

# Set Primary User
$intuneDeviceId = ((Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Issuer -match "Microsoft Intune MDM Device CA" } | Select-Object Subject).Subject).TrimStart("CN=")
$targetUserId = (Get-ItemProperty -Path "HKLM:\SOFTWARE\IntuneMigration" -Name "NEW_entraUserID").NEW_entraUserID
$sourceUserId = (Get-ItemProperty -Path "HKLM:\SOFTWARE\IntuneMigration" -Name "OLD_entraUserID").OLD_entraUserID
$userId = if ([string]::IsNullOrEmpty($targetUserId)) { $sourceUserId } else { $targetUserId }
$userUri = "https://graph.microsoft.com/beta/users/$userId"
$id = "@odata.id"
$JSON = @{ $id = $userUri } | ConvertTo-Json
try {
    Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$intuneDeviceId/users/`$ref" -Method Post -Headers $headers -Body $JSON -ContentType "application/json"
    log "Primary user set to $userId"
} catch {
    log "Error setting primary user: $_"
}

# Update GroupTag
$entraDeviceId = ((Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Issuer -match "MS-Organization-Access" } | Select-Object Subject).Subject).TrimStart("CN=")
$entraId = (Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/devices?`$filter=deviceid eq '$entraDeviceId'" -Headers $headers).value.id
$tag1 = (Get-ItemProperty -Path "HKLM:\SOFTWARE\IntuneMigration" -Name "OLD_groupTag").OLD_groupTag
$tag2 = $config.groupTag
$groupTag = if ([string]::IsNullOrEmpty($tag1)) { $tag2 } elseif ([string]::IsNullOrEmpty($tag2)) { $tag1 } else { $null }

if (![string]::IsNullOrEmpty($groupTag)) {
    $entraDeviceObject = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/devices/$entraId" -Headers $headers
    $physicalIds = $entraDeviceObject.physicalIds
    $newTag = "[OrderID]:$groupTag"
    $physicalIds += $newTag
    $body = @{ physicalIds = $physicalIds } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/devices/$entraId" -Method Patch -Headers $headers -Body $body
        log "Group tag updated to $groupTag"
    } catch {
        log "Error updating group tag: $_"
    }
} else {
    log "No group tag found"
}

# Migrate BitLocker Key
function migrateBitlockerKey {
    $volume = Get-BitLockerVolume -MountPoint "C:"
    $protectorId = ($volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }).KeyProtectorId
    if ($protectorId) {
        BackupToAAD-BitLockerKeyProtector -MountPoint "C:" -KeyProtectorId $protectorId
        log "BitLocker recovery key migrated"
    } else {
        log "No BitLocker recovery key found"
    }
}

if ($config.bitlockerMethod -eq "migrate") {
    try {
        migrateBitlockerKey
    } catch {
        log "Error migrating BitLocker key: $_"
    }
}

# Register device in Autopilot
$serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
$hardwareHash = (Get-CimInstance -Namespace root/cimv2/mdm/dmmap -ClassName MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'").DeviceHardwareData
$tag = if ([string]::IsNullOrEmpty($groupTag)) { "" } else { $groupTag }

$json = @"
{
    "@odata.type": "#microsoft.graph.importedWindowsAutopilotDeviceIdentity",
    "groupTag":"$tag",
    "serialNumber":"$serial",
    "productKey":"",
    "hardwareIdentifier":"$hardwareHash",
    "assignedUserPrincipalName":"",
    "state":{
        "@odata.type":"microsoft.graph.importedWindowsAutopilotDeviceIdentityState",
        "deviceImportStatus":"pending",
        "deviceRegistrationId":"",
        "deviceErrorCode":0,
        "deviceErrorName":""
    }
}
"@

try {
    Invoke-RestMethod -Method Post -Body $json -ContentType "application/json" -Uri "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities" -Headers $headers
    log "Device registered in Autopilot"
} catch {
    log "Error registering device in Autopilot: $_"
}

# Remove scheduled tasks
$tasksToRemove = @("reboot", "postMigrate")
foreach ($task in $tasksToRemove) {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    log "Removed scheduled task: $task"
}

# Remove MigrationUser
Remove-LocalUser -Name "MigrationInProgress" -Confirm:$false -ErrorAction SilentlyContinue
log "Removed MigrationUser"

# Register Scheduled Tasks if -ForceRegisterTasks is specified
if ($ForceRegisterTasks) {
    $tasks = @{
        "RestoreProfile"        = "C:\ProgramData\IntuneMigration\restoreprofile.xml"
        "SetPrimaryUser"        = "C:\ProgramData\IntuneMigration\setprimaryuser.xml"
        "GroupTag"              = "C:\ProgramData\IntuneMigration\grouptag.xml"
        "MigrateBitlockerKey"   = "C:\ProgramData\IntuneMigration\migratebitlockerkey.xml"
        "AutopilotRegistration" = "C:\ProgramData\IntuneMigration\autopilotregistration.xml"
    }

    foreach ($taskName in $tasks.Keys) {
        if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
            try {
                Register-ScheduledTask -Xml (Get-Content $tasks[$taskName] | Out-String) -TaskName $taskName
                log "Registered Scheduled Task: $taskName"
            } catch {
                log "Failed to register Scheduled Task: $taskName"
            }
        } else {
            log "Scheduled Task already exists: $taskName"
        }
    }
}

log "PostMigrate.ps1 complete"
Stop-Transcript
