# startMigrate.ps1 - Hybrid Azure AD Joined Device Migration Script (reworked v2, PPKG disabled)
# ---------------------------------------------------------------------------------
# Fő célok:
#  - Forrás Intune/Autopilot leválasztás + helyi nyomok teljes takarítása (FULL CLEANUP)
#  - OU-mozgatás + verifikáció (preferált DC használatával)
#  - Cél tenant SCP (CDJ\AAD) beállítása
#  - MDM auto-enrollment kulcsok beállítása (device-driven)
#  - Hybrid Azure AD Join elkészülésének ellenőrzése (dsregcmd + Graph)
#  - Health JSON generálása (OU_OK, AAD státusz, Graph találat, idők)
#  - PPKG telepítés KIKOMMENTELVE
# ---------------------------------------------------------------------------------

$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName System.Windows.Forms

function Log {
    param([string]$message)
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "$time - $message"
}

function msGraphAuthenticate {
    [CmdletBinding()] Param(
        [Parameter(Mandatory=$true)][string]$tenantName,
        [Parameter(Mandatory=$true)][string]$clientId,
        [Parameter(Mandatory=$true)][string]$clientSecret
    )
    $headers = @{ "Content-Type" = "application/x-www-form-urlencoded" }
    $body = "grant_type=client_credentials&scope=https://graph.microsoft.com/.default"
    $body += "&client_id=$clientId&client_secret=$clientSecret"
    $response = Invoke-RestMethod "https://login.microsoftonline.com/$tenantName/oauth2/v2.0/token" -Method 'POST' -Headers $headers -Body $body
    $token = "Bearer $($response.access_token)"
    return @{ "Authorization" = $token; "Content-Type" = "application/json" }
}

# --- dsregcmd /status parse ---
function Get-DsRegStatus {
    $out = dsregcmd /status
    $res = @{ AzureAdJoined=$false; DomainJoined=$false; TenantId=$null; DeviceId=$null }
    foreach ($line in $out) {
        if ($line -match 'AzureAdJoined\s*:\s*(\w+)') { $res.AzureAdJoined = ($matches[1] -eq 'YES') }
        if ($line -match 'DomainJoined\s*:\s*(\w+)')  { $res.DomainJoined  = ($matches[1] -eq 'YES') }
        if ($line -match 'TenantId\s*:\s*([0-9a-fA-F-]{36})') { $res.TenantId = $matches[1] }
        if ($line -match 'DeviceId\s*:\s*([0-9a-fA-F-]{36})') { $res.DeviceId = $matches[1] }
    }
    return $res
}

# --- Entra device keresése Graph-on deviceId alapján ---
function Get-EntraDeviceByDeviceId {
    param(
        [Parameter(Mandatory=$true)][string]$DeviceId,
        [Parameter(Mandatory=$true)][hashtable]$Headers
    )
    $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$DeviceId'"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $Headers -Method GET -ErrorAction Stop
        return $resp.value
    } catch {
        Log "Graph lookup error: $($_.Exception.Message)"
        return @()
    }
}

# --- Várakozás, amíg a hibrid join kész és a device meg is jelenik Graph-ban ---
function Wait-ForEntraPresence {
    param(
        [Parameter(Mandatory=$true)][string]$TargetTenantId,
        [Parameter(Mandatory=$true)][hashtable]$GraphHeaders,
        [int]$TimeoutMinutes = 45,
        [int]$PollSeconds    = 30
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        # gyorsító próbálkozás
        try { schtasks /Run /TN "Microsoft\Windows\Workplace Join\Automatic-Device-Join" | Out-Null } catch {}
        try { dsregcmd /refreshprt | Out-Null } catch {}

        $st = Get-DsRegStatus
        Log ("dsregcmd status: AzureAdJoined={0} TenantId={1} DeviceId={2}" -f $st.AzureAdJoined, $st.TenantId, $st.DeviceId)

        if ($st.AzureAdJoined -and $st.TenantId -and ($st.TenantId -ieq $TargetTenantId) -and $st.DeviceId) {
            $devs = Get-EntraDeviceByDeviceId -DeviceId $st.DeviceId -Headers $GraphHeaders
            if ($devs -and $devs.Count -ge 1) {
                Log "Entra device megtalálva a cél tenantban: $($devs[0].displayName) ($($st.DeviceId))"
                return $true
            } else {
                Log "AzureAdJoined=YES, de a Graph még nem látja az eszközt. Várakozás..."
            }
        } elseif ($st.AzureAdJoined -and $st.TenantId -and ($st.TenantId -ieq $TargetTenantId)) {
            Log "AzureAdJoined=YES, TenantId OK; DeviceId még nincs. Várakozás..."
        } else {
            Log "Hybrid join még nem kész vagy a TenantId nem egyezik. Várakozás..."
        }

        Start-Sleep -Seconds $PollSeconds
    } while ($sw.Elapsed.TotalMinutes -lt $TimeoutMinutes)

    return $false
}

# --- OU ellenőrzés (preferált DC támogatással) ---
function Test-ComputerInTargetOU {
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][string]$TargetOU,
        [Parameter(Mandatory=$true)][string]$DomainUser,
        [Parameter(Mandatory=$true)][string]$DomainPassword,
        [string]$PreferredDc
    )
    try {
        $ldapPath = if ([string]::IsNullOrWhiteSpace($PreferredDc)) { "LDAP://$TargetOU" } else { "LDAP://$PreferredDc/$TargetOU" }
        $base = New-Object System.DirectoryServices.DirectoryEntry($ldapPath, $DomainUser, $DomainPassword)
        $srch = New-Object System.DirectoryServices.DirectorySearcher($base)
        $srch.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
        $srch.Filter = "(&(objectClass=computer)(cn=$ComputerName))"
        $res = $srch.FindOne()
        return [bool]$res
    } catch {
        Log "OU verification error: $($_.Exception.Message)"
        return $false
    }
}

function Wait-ForComputerInOU {
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][string]$TargetOU,
        [Parameter(Mandatory=$true)][string]$DomainUser,
        [Parameter(Mandatory=$true)][string]$DomainPassword,
        [int]$TimeoutSec = 180,
        [int]$PollSec    = 10,
        [string]$PreferredDc
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        if (Test-ComputerInTargetOU -ComputerName $ComputerName -TargetOU $TargetOU -DomainUser $DomainUser -DomainPassword $DomainPassword -PreferredDc $PreferredDc) { return $true }
        Start-Sleep -Seconds $PollSec
    } while ((Get-Date) -lt $deadline)
    return $false
}

# ---------- Fő futás ----------
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$config = Get-Content "$ScriptRoot\config_modified.json" | ConvertFrom-Json

# Health metrika
$t0 = Get-Date
$ouOk   = $false
$hjOk   = $false
$errors = @()

# Mappák
if (-not (Test-Path $config.logPath)) { New-Item -Path $config.logPath -ItemType Directory -Force | Out-Null }
$localPath = "$($config.localPath)"
if (-not (Test-Path $localPath)) { New-Item -Path $localPath -ItemType Directory -Force | Out-Null }

Start-Transcript -Path "$($config.logPath)\startMigrate.log" -Append -Verbose
Log "StartMigrate (reworked v2): indul..."

# Opcionális: csomagfájlok lokális másolása
try {
    Copy-Item -Path ".\*" -Destination $localPath -Recurse -Force
    Log "Package tartalom átmásolva: $localPath"
} catch { Log "Másolási hiba: $($_.Exception.Message)"; $errors += $_.Exception.Message }

# Graph auth (forrás és cél)
Log "Graph auth - source tenant..."
$sourceHeaders = msGraphAuthenticate -tenantName $config.sourceTenant.tenantName -clientId $config.sourceTenant.clientId -clientSecret $config.sourceTenant.clientSecret
Log "Graph auth - target tenant..."
$targetHeaders = msGraphAuthenticate -tenantName $config.targetTenant.tenantName -clientId $config.targetTenant.clientId -clientSecret $config.targetTenant.clientSecret

# Intune MDM cert + Autopilot lokális azonosítók felderítése (mielőtt takarítunk)
$intuneIssuer = "Microsoft Intune MDM Device CA"
$intuneCert = Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Issuer -match $intuneIssuer }
$intuneId = $null
if ($intuneCert) {
    Log "Intune MDM cert talált."
    $intuneId = (( $intuneCert | Select-Object -First 1 -ExpandProperty Subject )).TrimStart("CN=")
    Log "(Megjegyzés) Intune azonosító (Subject CN alapú): $intuneId"
} else {
    Log "Intune MDM cert nem található."
}

$autopilotId = $null
try {
    $apDiag = "HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot"
    $ztd = Get-ItemProperty -Path "$apDiag\EstablishedCorrelations" -Name "ZtdRegistrationId" -ErrorAction SilentlyContinue
    if ($ztd -and $ztd.ZtdRegistrationId) { $autopilotId = $ztd.ZtdRegistrationId; Log "Autopilot ZtdRegistrationId: $autopilotId" }
} catch { Log "Autopilot ID olvasási hiba: $($_.Exception.Message)"; $errors += $_.Exception.Message }

# Azure AD kapcsolat bontása
Log "dsregcmd /leave futtatása..."
Start-Process -FilePath "dsregcmd.exe" -ArgumentList "/leave" -Wait
Log "AAD kapcsolat bontva."

# === FULL CLEANUP BLOKK ===
$ResetSCP = $false  # akkor állítsd $true-ra, ha utána AZONNAL írod az új SCP értékeket
try {
    Log "=== Intune / AAD nyomok teljes eltávolítása (FULL CLEANUP) ==="

    # 1) Intune MDM tanúsítvány(ok) törlése
    try {
        if ($intuneCert) {
            foreach ($cert in $intuneCert) {
                Log "Removing Intune MDM cert: $($cert.Subject)"
                $cert | Remove-Item -Force
            }
        } else {
            Log "No Intune MDM cert found."
        }
    } catch { Log "Cert cleanup error: $($_.Exception.Message)"; $errors += $_.Exception.Message }

    # 2) Enrollments hive + Status
    try {
        $enrollmentRoot = "HKLM:\SOFTWARE\Microsoft\Enrollments"
        if (Test-Path $enrollmentRoot) { Log "Removing enrollment hive: $enrollmentRoot"; Remove-Item -Path $enrollmentRoot -Recurse -Force } else { Log "Enrollment hive not found: $enrollmentRoot" }
        $enrollStatus = "HKLM:\SOFTWARE\Microsoft\Enrollments\Status"
        if (Test-Path $enrollStatus) { Log "Removing enrollment status: $enrollStatus"; Remove-Item -Path $enrollStatus -Recurse -Force }
    } catch { Log "Enrollments cleanup error: $($_.Exception.Message)"; $errors += $_.Exception.Message }

    # 3) OMADM nyomok
    try {
        $omadm = @(
            "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts",
            "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Logger"
        )
        foreach ($p in $omadm) { if (Test-Path $p) { Log "Removing OMADM key: $p"; Remove-Item -Path $p -Recurse -Force } }
    } catch { Log "OMADM cleanup error: $($_.Exception.Message)"; $errors += $_.Exception.Message }

    # 4) Autopilot diagnosztika
    try {
        $apDiagKey = "HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\AutoPilot"
        if (Test-Path $apDiagKey) { Log "Removing Autopilot diagnostic key: $apDiagKey"; Remove-Item -Path $apDiagKey -Recurse -Force }
    } catch { Log "Autopilot diag cleanup error: $($_.Exception.Message)"; $errors += $_.Exception.Message }

    # 5) Workplace account eltávolítás
    try {
        $upn = (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
        $aadAccount = Get-WmiObject -Namespace "root\\cimv2\\mdm\\dmmap" -Class MDM_EnterpriseModernAppManagement_AppManagement01 -ErrorAction SilentlyContinue
        if ($aadAccount -and $upn) { $aadAccount.DeleteEnterpriseAccount($upn); Log "Workplace account removed: $upn" } else { Log "No workplace account to remove." }
    } catch { Log "Workplace account cleanup error: $($_.Exception.Message)"; $errors += $_.Exception.Message }

    # 6) (OPCIONÁLIS) SCP CDJ\AAD kulcs nullázása
    if ($ResetSCP) {
        try {
            $cdj = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CDJ\AAD"
            if (Test-Path $cdj) { Log "Removing CDJ AAD key (will be re-created): $cdj"; Remove-Item -Path $cdj -Recurse -Force }
        } catch { Log "CDJ AAD cleanup error: $($_.Exception.Message)"; $errors += $_.Exception.Message }
    }

    Log "=== Full cleanup complete. ==="
} catch { Log "Full cleanup wrapper error: $($_.Exception.Message)"; $errors += $_.Exception.Message }

# Forrás tenant objektumok törlése (ha vannak azonosítók)
if ($intuneId) {
    try { Log "Forrás Intune managedDevice törlése: $intuneId"; Invoke-RestMethod -Method DELETE -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$intuneId" -Headers $sourceHeaders; Log "Intune object deleted." } catch { Log "Intune object delete error: $($_.Exception.Message)"; $errors += $_.Exception.Message }
}
if ($autopilotId) {
    try { Log "Forrás Autopilot objektum törlése: $autopilotId"; Invoke-RestMethod -Method DELETE -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$autopilotId" -Headers $sourceHeaders; Log "Autopilot object deleted." } catch { Log "Autopilot object delete error: $($_.Exception.Message)"; $errors += $_.Exception.Message }
}

# AD OU mozgatás + verifikáció (Preferred DC használatával)
$domainUser = $config.sourceTenant.domainCredentials.domainUser
$domainPassword = $config.sourceTenant.domainCredentials.domainPassword
$preferredDc = $config.ad.preferredDc
$ldapBase    = $config.ad.ldapBase
try {
    $computerName = $env:COMPUTERNAME

    # Keresési bázis: ha van ldapBase a configban, azt használjuk; különben a TargetOU DC-részeiből számolunk
    if ([string]::IsNullOrWhiteSpace($ldapBase)) {
        $dcParts = (($config.targetTenant.computerOU -split ',') | Where-Object { $_ -like 'DC=*' })
        $ldapBase = ($dcParts -join ',')
        if (-not $ldapBase) { $ldapBase = $config.targetTenant.computerOU }
    }

    $bindPath = if ([string]::IsNullOrWhiteSpace($preferredDc)) { "LDAP://$ldapBase" } else { "LDAP://$preferredDc/$ldapBase" }
    $searchRoot = New-Object System.DirectoryServices.DirectoryEntry($bindPath, $domainUser, $domainPassword)
    $searcher = New-Object System.DirectoryServices.DirectorySearcher($searchRoot)
    $searcher.Filter = "(&(objectClass=computer)(cn=$computerName))"
    $result = $searcher.FindOne()

    if ($result) {
        $entry = $result.GetDirectoryEntry()
        $currentDn = try { [string]$entry.distinguishedName } catch { $null }
        if ($currentDn -and ($currentDn -like "CN=$computerName,*$($config.targetTenant.computerOU)")) {
            Log "Computer already in target OU: $($config.targetTenant.computerOU)"
        } else {
            $targetPath = if ([string]::IsNullOrWhiteSpace($preferredDc)) { "LDAP://$($config.targetTenant.computerOU)" } else { "LDAP://$preferredDc/$($config.targetTenant.computerOU)" }
            $targetOUEntry = New-Object System.DirectoryServices.DirectoryEntry($targetPath, $domainUser, $domainPassword)
            $entry.MoveTo($targetOUEntry)
            $entry.CommitChanges()
            Log "Computer object moved to OU: $($config.targetTenant.computerOU)"
        }

        $ouOk = Wait-ForComputerInOU -ComputerName $computerName -TargetOU $config.targetTenant.computerOU -DomainUser $domainUser -DomainPassword $domainPassword -TimeoutSec 180 -PollSec 10 -PreferredDc $preferredDc
        if ($ouOk) { Log "OU verification: SUCCESS" } else { Log "OU verification: FAILED (timeout)" }
    } else {
        Log "Computer object not found in AD."
    }
} catch { Log "AD mozgatás hiba: $($_.Exception.Message)"; $errors += $_.Exception.Message }

# SCP registry beállítás (cél tenant)
try {
    $scpRegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CDJ\AAD"
    if (-not (Test-Path $scpRegPath)) { New-Item -Path $scpRegPath -Force | Out-Null; Log "SCP registry path created: $scpRegPath" } else { Log "SCP registry path already exists: $scpRegPath" }
    Set-ItemProperty -Path $scpRegPath -Name "TenantId"   -Value "$($config.targetTenant.tenantId)"
    Set-ItemProperty -Path $scpRegPath -Name "TenantName" -Value "$($config.targetTenant.tenantName)"
    Log "SCP registry values set for target tenant: $($config.targetTenant.tenantName)"
} catch { Log "SCP beállítás hiba: $($_.Exception.Message)"; $errors += $_.Exception.Message }

# MDM auto-enrollment kulcsok beállítása (device-driven)
try {
    $mdmKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM"
    New-Item -Path $mdmKey -Force | Out-Null
    New-ItemProperty -Path $mdmKey -Name "AutoEnrollMDM" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $mdmKey -Name "UseAADCredentialType" -Value 1 -PropertyType DWord -Force | Out-Null
    Log "MDM auto-enrollment registry kulcsok beállítva."
} catch { Log "MDM registry beállítás hiba: $($_.Exception.Message)"; $errors += $_.Exception.Message }

# Hybrid join ellenőrzés (PPKG NINCS, csak verifikáció)
$verifyTimeoutMin = 45
$pollSec = 30
$hjOk = Wait-ForEntraPresence -TargetTenantId $config.targetTenant.tenantId -GraphHeaders $targetHeaders -TimeoutMinutes $verifyTimeoutMin -PollSeconds $pollSec
if ($hjOk) {
    Log "Hybrid join + Entra objektum: OK"
} else {
    Log "TIMEOUT: $verifyTimeoutMin percen belül nem jelent meg az eszköz a cél tenantban"
}

# --- PPKG telepítés KIKOMMENTELVE ---
# try {
#     Install-ProvisioningPackage -PackagePath 'C:\\ProgramData\\IntuneMigration\\migrate.ppkg' -QuietInstall -Force -LogsDirectoryPath $config.logPath
#     Log "PPKG telepítés befejezve."
# } catch {
#     Log "PPKG install error: $($_.Exception.Message)"
# }

# Health JSON kiírása
try {
    $t1 = Get-Date
    $st = Get-DsRegStatus
    $health = [pscustomobject]@{
        DeviceName           = $env:COMPUTERNAME
        PreferredDC          = $preferredDc
        TargetTenant         = $config.targetTenant.tenantName
        TargetTenantId       = $config.targetTenant.tenantId
        TimeStart            = $t0
        TimeEnd              = $t1
        DurationSeconds      = [int]([TimeSpan]::FromTicks(($t1).Ticks - ($t0).Ticks).TotalSeconds)
        OU_TargetOU          = $config.targetTenant.computerOU
        OU_OK                = [bool]$ouOk
        AAD_AzureAdJoined    = [bool]$st.AzureAdJoined
        AAD_TenantId         = $st.TenantId
        AAD_DeviceId         = $st.DeviceId
        Graph_DeviceFound    = [bool]$hjOk  # itt a Wait-ForEntraPresence Graph-találaton alapul
        Errors               = $errors
    }
    $healthFile = Join-Path $config.logPath 'HybridJoin_Status.json'
    $health | ConvertTo-Json -Depth 4 | Set-Content -Path $healthFile -Encoding UTF8
    Log "Health JSON mentve: $healthFile"
} catch { Log "Health JSON írási hiba: $($_.Exception.Message)" }

Log "Vége. Opcionális: újraindítás 30 mp múlva..."
Stop-Transcript
# shutdown -r -t 30
