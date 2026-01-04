<#
    Invoke-PreflightChecks.ps1 (v1.2-PS51)
    - Windows PowerShell 5.1 kompatibilis (nincs ternary)
    - Dinamikus domain/DC felderítés; DNS SRV; TCP 443/389/636 (ha -UseLdaps)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string]$ConfigPath,
    [string]$OutFolder = './PreflightOutput',
    [switch]$UseLdaps
)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if(-not (Test-Path $OutFolder)){ New-Item -ItemType Directory -Path $OutFolder | Out-Null }
function New-Result([string]$Name,[string]$Status,[string]$Details){ [pscustomobject]@{ Name=$Name; Status=$Status; Details=$Details } }
$results = @()

try{ $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json; $results += New-Result 'Config betöltés' 'OK' $ConfigPath } catch{ $results += New-Result 'Config betöltés' 'FAIL' $_.Exception.Message }

function Get-LdapContext { param([string]$DomainFqdn,[string]$PreferredDc,[string]$FallbackBase)
    $base=$null;$fqdn=$DomainFqdn;$server=$PreferredDc
    try{ $root=[ADSI]'LDAP://RootDSE'; $base=$root.defaultNamingContext; if(-not $fqdn){ $fqdn = ($root.rootDomainNamingContext -replace 'DC=','' -replace ',','.') } }catch{}
    if(-not $base -and $env:USERDNSDOMAIN){ $base='DC=' + ($env:USERDNSDOMAIN -replace '\.',',DC='); if(-not $fqdn){ $fqdn=$env:USERDNSDOMAIN } }
    if(-not $base -and $FallbackBase){ $base=$FallbackBase }
    if(-not $server -and $fqdn){ try{ $srv = nltest /dsgetdc:$fqdn; $addrLines = $srv -match 'Address'; if($addrLines){ $server = ($addrLines | ForEach-Object { ($_ -split ':')[-1].Trim() } | Select-Object -First 1) } }catch{} }
    [pscustomobject]@{ BaseDn=$base; Server=$server; DomainFqdn=$fqdn }
}
$ctx = Get-LdapContext -DomainFqdn $config.ad.domainFqdn -PreferredDc $config.ad.preferredDc -FallbackBase $config.ad.ldapBase

# Base DN
$baseStatus = if($null -ne $ctx.BaseDn -and $ctx.BaseDn -ne ''){'OK'} else {'FAIL'}
$results += New-Result 'LDAP Base DN' $baseStatus $ctx.BaseDn

# Preferred DC
$prefDcStatus = if($null -ne $ctx.Server -and $ctx.Server -ne ''){'INFO'} else {'WARN'}
$prefDcDetails = if($null -ne $ctx.Server -and $ctx.Server -ne ''){ $ctx.Server } else { '(auto-discovery sikertelen)' }
$results += New-Result 'Preferred DC' $prefDcStatus $prefDcDetails

# Domain FQDN
$domainStatus = if($null -ne $ctx.DomainFqdn -and $ctx.DomainFqdn -ne ''){'OK'} else {'WARN'}
$results += New-Result 'Domain FQDN' $domainStatus $ctx.DomainFqdn

# DNS SRV
if($ctx.DomainFqdn){ try{ $srv = Resolve-DnsName -Type SRV ('_ldap._tcp.dc._msdcs.' + $ctx.DomainFqdn) -ErrorAction Stop; $targets = ($srv | Select-Object -ExpandProperty NameTarget) -join ', '; $results += New-Result 'DNS SRV _ldap._tcp.dc._msdcs' 'OK' ("talált DC-k: {0}" -f $targets) } catch { $results += New-Result 'DNS SRV _ldap._tcp.dc._msdcs' 'FAIL' 'Nincs SRV válasz' } }

# TCP reachability
foreach($host in @('login.microsoftonline.com','graph.microsoft.com')){ try{ $r = Test-NetConnection -ComputerName $host -Port 443; $status = if($r.TcpTestSucceeded){'OK'} else {'FAIL'}; $rtt = if($null -ne $r.PingReplyDetails){ $r.PingReplyDetails.RoundtripTime } else { $null }; $details = if($null -ne $rtt){ "RTT={0}" -f $rtt } else { '' }; $results += New-Result ("TCP 443: {0}" -f $host) $status $details } catch { $results += New-Result ("TCP 443: {0}" -f $host) 'WARN' 'Teszt hiba' } }

if($ctx.Server){ try{ $r = Test-NetConnection -ComputerName $ctx.Server -Port 389; $status = if($r.TcpTestSucceeded){'OK'} else {'FAIL'}; $results += New-Result ("LDAP 389: {0}" -f $ctx.Server) $status '' } catch { $results += New-Result ("LDAP 389: {0}" -f $ctx.Server) 'WARN' 'Teszt hiba' } }
if($UseLdaps -and $ctx.Server){ try{ $r = Test-NetConnection -ComputerName $ctx.Server -Port 636; $status = if($r.TcpTestSucceeded){'OK'} else {'FAIL'}; $results += New-Result ("LDAPS 636: {0}" -f $ctx.Server) $status '' } catch { $results += New-Result ("LDAPS 636: {0}" -f $ctx.Server) 'WARN' 'Teszt hiba' } }

# Graph token
function Get-GraphHeaders($t,$cid,$sec){ try{ $headers=@{'Content-Type'='application/x-www-form-urlencoded'}; $body="grant_type=client_credentials&scope=https://graph.microsoft.com/.default&client_id=$cid&client_secret=$sec"; $resp=Invoke-RestMethod "https://login.microsoftonline.com/$t/oauth2/v2.0/token" -Method POST -Headers $headers -Body $body; return @{ Authorization = "Bearer $($resp.access_token)" } } catch { return $null } }
$srcH = Get-GraphHeaders $config.sourceTenant.tenantName $config.sourceTenant.clientId $config.sourceTenant.clientSecret
$srcStatus = if($null -ne $srcH){'OK'} else {'FAIL'}
$results += New-Result 'Graph token (source)' $srcStatus ''
$dstH = Get-GraphHeaders $config.targetTenant.tenantName $config.targetTenant.clientId $config.targetTenant.clientSecret
$dstStatus = if($null -ne $dstH){'OK'} else {'FAIL'}
$results += New-Result 'Graph token (target)' $dstStatus ''

# Intune/Autopilot
$intuneIssuer = 'Microsoft Intune MDM Device CA'
$mdmCert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Issuer -match $intuneIssuer }
$mdmStatus = if($mdmCert){'PRESENT'} else {'ABSENT'}
$results += New-Result 'Intune MDM tanúsítvány' $mdmStatus ''
$apKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot' -Name 'CloudAssignedMdmId' -ErrorAction SilentlyContinue
$apStatus = if($apKey){'PRESENT'} else {'ABSENT'}
$results += New-Result 'Autopilot regisztráció' $apStatus ''

# Pending reboot
$pending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
$pendStatus = if($pending){'YES'} else {'NO'}
$results += New-Result 'Pending reboot' $pendStatus ''

$results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutFolder 'PreflightResults.json') -Encoding utf8
$results | Export-Csv -NoTypeInformation -Path (Join-Path $OutFolder 'PreflightResults.csv') -Encoding UTF8
$results | Format-Table -AutoSize | Out-Host
$failCount = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
Write-Host ("Összes ellenőrzés: {0} | FAIL: {1}" -f $results.Count, $failCount)
