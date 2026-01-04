# PreMigrate_Merged_Fixed_FINAL.ps1
<#
.SYNOPSIS
  PreMigrate_Merged.ps1 – előkészítő szkript Intune tenant-to-tenant eszközmigrációhoz (v8 kompatibilitással)

.DESCRIPTION
  Begyűjti a gép és felhasználó állapotát, kiválasztja a migrációs módot (local/blob/none), elindítja az adatmentést,
  majd minden kulcsfontosságú értéket registry-be ír “OG_” előtaggal, hogy a StartMigrate és PostMigrate szkriptek determinisztikusan dolgozhassanak.

.NOTES
  Futási követelmény: SYSTEM kontextus, PowerShell 5.1+
  Verzió: 1.2 (javított: registry, robocopy, karakterkódolás, OG_SyncRoot/MigrateMethod)
.OWNER
  Steve Weiner
.CONTRIBUTORS
  Logan Lautt
#>

#[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = 'Stop'

# Logging function
function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "$ts $Message"
}

# Load config.json
$settings = Get-Content -Path "$PSScriptRoot\config_modified.json" -Raw | ConvertFrom-Json
$logPath = "$($settings.logPath)\preMigrate.log"
if (!(Test-Path $settings.logPath)) { New-Item -Path $settings.logPath -ItemType Directory -Force | Out-Null }
Start-Transcript -Path $logPath -Append
$global:transcriptStarted = $true
Write-Log "PreMigrate indítása..."

# Critical error exit
function Exit-Script {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$FunctionName,
        [string]$LocalPath = $settings.localPath
    )
    Write-Log "[$FunctionName] Hiba. Kilépés kóddal $ExitCode."
    if ($global:transcriptStarted) {
        Stop-Transcript
        $global:transcriptStarted = $false
    }
    if ($ExitCode -eq 1) {
        try {
           # Remove-Item -Path $LocalPath -Recurse -Force -Verbose
           # Write-Log "Eltávolítva: $LocalPath"
        } catch {
            Write-Log "Nem sikerült törölni: $LocalPath"
        }
        try {
            reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}" /v Disabled /t REG_DWORD /d 0 /f | Out-Host
            Write-Log "Logon provider engedélyezve."
        } catch {
            Write-Log "Nem sikerült engedélyezni a logon providert."
        }
        shutdown -r -t 90
        Exit -1
    } else {
        Exit $ExitCode
    }
}

# Initialization
function Initialize-Script {
    param(
        [bool]$InstallTag = $true,
        [string]$LocalPath = $settings.localPath
    )
    Write-Log "Inicializáció..."
    if (-not (Test-Path $LocalPath)) {
        New-Item -Path $LocalPath -ItemType Directory -Force | Out-Null
        Write-Log "Létrehozva: $LocalPath"
    }
    if ($InstallTag) {
        New-Item -Path (Join-Path $LocalPath 'preMigrateInstalled.txt') -ItemType File -Force | Out-Null
        Write-Log "preMigrateInstalled.txt létrehozva."
    }
    Write-Log "Fut mint: $(whoami)"
}

try {
    Initialize-Script
    Write-Log "Inicializáció kész."
} catch {
    Exit-Script -ExitCode 1 -FunctionName 'Initialize-Script'
}

# MS Graph authentication
function MSGraph-Authenticate {
    param(
        [string]$Tenant       = $settings.sourceTenant.tenantName,
        [string]$ClientId     = $settings.sourceTenant.clientId,
        [string]$ClientSecret = $settings.sourceTenant.clientSecret
    )
    Write-Log "MS Graph hitelesítés..."
    $body = @{
        grant_type    = "client_credentials"
        scope         = "https://graph.microsoft.com/.default"
        client_id     = $ClientId
        client_secret = $ClientSecret
    }
    $tokenRp = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token" `
        -Method POST -Headers @{ 'Content-Type'='application/x-www-form-urlencoded' } `
        -Body $body
    $token = "Bearer $($tokenRp.access_token)"
    $global:headers = @{
        Authorization = $token
        'Content-Type' = 'application/json'
    }
    Write-Log "MS Graph hitelesítve."
}

# Device info collection (merged, filterless, modernized)
function Get-DeviceObject {
    Write-Log "Eszközadatok gyűjtése..."
    try {
        $serial = (Get-CimInstance -ClassName Win32_Bios).SerialNumber
        $hostname = $env:COMPUTERNAME
        $dsout = dsregcmd /status | Select-String 'AzureAdJoined','DomainJoined'
        $aadJoined = ($dsout | Where-Object { $_ -match 'AzureAdJoined' } ).ToString().Split(':')[1].Trim()
        $domJoined = ($dsout | Where-Object { $_ -match 'DomainJoined' } ).ToString().Split(':')[1].Trim()
        $blk = (Get-BitLockerVolume -MountPoint C).ProtectionStatus
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Issuer -match 'Microsoft Intune MDM Device CA' }
        $mdm = [bool]$cert
        $intuneId = if ($mdm) { $cert.Subject.TrimStart('CN=') } else { $null }

        # Autopilot device query (filterless, PowerShell-side filtering)
        $uri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities"
        Write-Log "Autopilot lekérdezés URI: $uri"
        try {
            $autopilot = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
            $apDevice = $autopilot.value | Where-Object { $_.serialNumber -eq $serial }
            $autoId = if ($apDevice) { $apDevice.id } else { $null }
            $groupTag = if ($apDevice) { $apDevice.groupTag } else { $null }
        } catch {
            Write-Log "Autopilot API hiba: $($_.Exception.Message)"
            $autoId = $null
            $groupTag = $null
        }

        $deviceObject = [PSCustomObject]@{
            serialNumber  = $serial
            hostname      = $hostname
            azureAdJoined = $aadJoined
            domainJoined  = $domJoined
            bitLocker     = $blk
            mdm           = $mdm
            intuneId      = $intuneId
            autopilotId   = $autoId
            groupTag      = $groupTag
        }

        Write-Log "Eszközobjektum elkészült: $($deviceObject | ConvertTo-Json -Compress)"
        return $deviceObject
    } catch {
        Write-Log "Hiba az eszközadatok gyűjtésekor: $($_.Exception.Message)"
        exit 1
    }
}

try {
    MSGraph-Authenticate
    $device = Get-DeviceObject
    Write-Log "Eszközobjektum elkészült."
} catch {
    Exit-Script -ExitCode 1 -FunctionName 'Get-DeviceObject'
}

# User info collection
function Get-UserObject {
    Write-Log "Felhasználóadatok gyűjtése..."
    $up = (Get-WmiObject -Class Win32_ComputerSystem).UserName
    if (-not $up) {
        Write-Log "Nincs bejelentkezett felhasználó. Kilépés."
        Exit-Script -ExitCode 1 -FunctionName 'Get-UserObject'
    }
    $sid = (New-Object System.Security.Principal.NTAccount($up)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $profile = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -Name ProfileImagePath
    $sam = $up.Split('\')[-1]
    $upn = if ($device.domainJoined -eq 'NO') {
        try {
            (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$sid\IdentityCache\$sid" -Name UserName -ErrorAction Stop).UserName
        } catch { $null }
    } else { $null }
    $eid = if ($upn -and $device.azureAdJoined -eq 'YES') {
        try {
            (Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/users/$upn" -Headers $headers).id
        } catch { $null }
    } else { $null }

    return [PSCustomObject]@{
        user        = $up
        SID         = $sid
        profilePath = $profile
        SAMName     = $sam
        UPN         = $upn
        entraId     = $eid
    }
}

try {
    $user = Get-UserObject
    Write-Log "Felhasználóobjektum elkészült."
} catch {
    Exit-Script -ExitCode 1 -FunctionName 'Get-UserObject'
}

# GUID generation
$guid = (New-Guid).Guid
Write-Log "Migration GUID: $guid"

# Migration method determination and backup
function Determine-MigrationMethod {
    param(
        [array]$Locations = $settings.locations,
        [string]$LocalPath = $settings.localPath
    )

    Write-Log "Szabad hely ellenőrzése és mentés előkészítése..."
    
    try {
        $free = (Get-Volume -DriveLetter C).SizeRemaining
    } catch {
        Write-Log "Nem sikerült lekérni a szabad helyet: $($_.Exception.Message)"
        return 'none'
    }

    $totalSize = 0
    $validPaths = 0

    foreach ($loc in $Locations) {
        $path = "C:\Users\$($user.SAMName)\$loc"
        if (Test-Path $path) {
            try {
                $files = Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue
                $size = ($files | Measure-Object Length -Sum).Sum
                $totalSize += $size
                $validPaths++
                Write-Log "Mappa: $path | Fájlok száma: $($files.Count) | Méret: $size bájt"
            } catch {
                Write-Log "Hiba a mappa feldolgozásakor: $path - $($_.Exception.Message)"
            }
        } else {
            Write-Log "Nem található mappa: $path"
        }
    }

    if ($validPaths -eq 0) {
        Write-Log "Nincs elérhető mentendő mappa. Kilépés."
        return 'none'
    }

    $needLocal = $totalSize * 3
    $needBlob  = $totalSize * 2

    Write-Log "Összesített mentési méret: $totalSize bájt | Szükséges hely (local): $needLocal | Szükséges hely (blob): $needBlob | Elérhető: $free"

    if ($free -gt $needLocal)       { return 'local' }
    elseif ($free -gt $needBlob)    { return 'blob'  }
    else                            { return 'none'  }
}

try {
    $migrateMethod = Determine-MigrationMethod
    Write-Log "Migrációs mód: $migrateMethod"
} catch {
    Exit-Script -ExitCode 1 -FunctionName 'Determine-MigrationMethod'
}

# Profile backup if local mode
if ($migrateMethod -eq 'local') {
    Write-Log "Profil mentés indítása helyi mentéshez..."
    $userProfilePath = $user.profilePath
    $backupRoot = "$($settings.localPath)\ProfileBackup"
    if (!(Test-Path $backupRoot)) {
        New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
        Write-Log "Létrehozva: $backupRoot"
    }
    foreach ($location in $settings.locations) {
        $source = Join-Path $userProfilePath $location
        $destination = Join-Path $backupRoot $location
        if (Test-Path $source) {
            Write-Log "Mentés: $source -> $destination"
            robocopy $source $destination /E /ZB /R:0 /W:0 /V /XJ /FFT | Out-Null
            $rc = $LASTEXITCODE
            Write-Log "Robocopy visszatérési kód: $rc"
            if ($rc -eq 0) {
                Write-Log "Sikeres mentés: $source"
            } elseif ($rc -eq 1) {
                Write-Log "Robocopy figyelmeztetés: $source"
            } else {
                Write-Log "Robocopy hiba: $source"
            }
        } else {
            Write-Log "Nem található: $source"
        }
    }
    Write-Log "Profil mentés befejezve."
}

# Registry write with OG_ prefix + GUID, MigrateMethod, CurrentDomain
$regPath = $settings.regPath
Write-Log "Registry-be írás: $regPath"

$props = @{}
$device.PSObject.Properties | ForEach-Object { $props["OG_$($_.Name)"] = $_.Value }
$user.PSObject.Properties   | ForEach-Object { $props["OG_$($_.Name)"] = $_.Value }
$props['GUID']           = $guid
$props['MigrateMethod']  = $migrateMethod
$props['CurrentDomain']  = (Get-WmiObject Win32_ComputerSystem).Domain

# OG_SyncRoot javítás: csak akkor írjuk, ha van ilyen property és az nem log szöveg
if ($props.ContainsKey('OG_SyncRoot')) {
    $syncRootVal = $props['OG_SyncRoot']
    # Ha a SyncRoot egy log szöveg, ne írjuk be
    if ($syncRootVal -is [string] -and $syncRootVal -match 'Felhasználóadatok gyűjtése') {
        $props.Remove('OG_SyncRoot')
    }
}

foreach ($name in $props.Keys) {
    $value = $props[$name]
    if (-not [string]::IsNullOrEmpty($value)) {
        try {
            if ($value -is [bool]) {
                $regValue = if ($value) { 1 } else { 0 }
                $type = 'REG_DWORD'
            } elseif ($value -is [int]) {
                $regValue = $value
                $type = 'REG_DWORD'
            } else {
                $regValue = $value
                $type = 'REG_SZ'
            }
            reg.exe add $regPath /v $name /t $type /d $regValue /f | Out-Host
            Write-Log "Registry: $name = $regValue"
        } catch {
            Write-Log "Hiba registry íráskor: $name"
        }
    }
}

Write-Log "PreMigrate befejezve."
if ($global:transcriptStarted) {
    Stop-Transcript
    $global:transcriptStarted = $false
}
