# MigrateDryRun_Package_v1

## Fájlok
- `startMigrate_dryrun.ps1` — DRY-RUN támogatású migrációs script.
- `Generate-MoveLDIF.ps1` — LDIF generálása (computer + primary user mozgatáshoz).
- `Tests/StartMigrate.Tests.ps1` — Pester alap tesztek.
- `Preflight/Invoke-PreflightChecks.ps1` — előfeltétel-ellenőrző.

## Előfeltételek
- PowerShell 5.1+ (Windows)
- Active Directory modul _nem kötelező_; .NET DirectoryServices API-t használunk.
- Pester tesztek futtatásához: Pester 5.x (`Install-Module Pester -Scope CurrentUser`).

## Használat

### 1) DRY-RUN script
```powershell
# DRY-RUN
.\startMigrate_dryrun.ps1 -ConfigPath .\config_modified.json -DryRun -NoGraphDelete -NoReboot -Verbose

# Éles (példa: reboot és graph delete nélkül)
.\startMigrate_dryrun.ps1 -ConfigPath .\config_modified.json -NoGraphDelete -NoReboot -Verbose
```

Kimenet: `startMigrate_dryrun.log` és `startMigrate_dryrun_report.json` a config `localPath` mappájában.

### 2) LDIF generálás
```powershell
.\Generate-MoveLDIF.ps1 -ConfigPath .\config_modified.json -OutputPath .\move_objects.ldf
# Futtatás (AD mozgatás):
ldifde -i -f .\move_objects.ldf
```

### 3) Pester tesztek
```powershell
# Pester 5.x szükséges
Invoke-Pester -Path .\Tests -Output Detailed
```

### 4) Preflight
```powershell
.\Preflight\Invoke-PreflightChecks.ps1 -ConfigPath .\config_modified.json -OutFolder .\PreflightOutput
```

## Biztonsági megjegyzés
A `config_modified.json` plaintext jelszót tartalmazhat. Javasolt DPAPI-val titkosított tárolás vagy Credential Manager használata.
