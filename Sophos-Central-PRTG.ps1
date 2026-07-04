<#
.SYNOPSIS
    PRTG Custom Sensor (EXE/Script Advanced) fuer Sophos Central.

.DESCRIPTION
    Fragt die Sophos Central API ab und liefert das Ergebnis als PRTG-XML:
      1. OAuth2-Token holen        (https://id.sophos.com/api/v2/oauth2/token)
      2. Tenant + Datenregion      (https://api.central.sophos.com/whoami/v1)
      3. Geraete abfragen          ({dataRegion}/endpoint/v1/endpoints bzw.
                                    {dataRegion}/mobile/v1/devices)
      4. Alerts abfragen           ({dataRegion}/common/v1/alerts)

    Mit -DeviceType laesst sich nach Produkt filtern, sodass pro Produkt
    ein eigener PRTG-Sensor angelegt werden kann:
      all      = alle Endpoints (Clients + Server, wie Endpoint-API)
      computer = nur Endpoint Clients (Workstations)
      server   = nur Endpoint Server
      mobile   = alle Mobilgeraete (iOS + Android, Sophos Mobile)
      ios      = nur iOS-Geraete
      android  = nur Android-Geraete

.PARAMETER ClientId
    Client-ID der Sophos Central API-Anmeldedaten
    (Sophos Central Admin -> Globale Einstellungen -> API-Anmeldedaten-Verwaltung).

.PARAMETER ClientSecret
    Client-Secret der API-Anmeldedaten.

.PARAMETER DeviceType
    Produktfilter: all | computer | server | mobile | ios | android
    (Standard: all)

.PARAMETER TenantId
    Optional: Tenant-ID. Nur noetig bei Partner-/Organisations-Anmeldedaten.
    Bei normalen Tenant-Anmeldedaten wird sie automatisch ermittelt.

.PARAMETER DataRegion
    Optional: API-Host der Datenregion, z.B. https://api-eu01.central.sophos.com
    Wird normalerweise automatisch ermittelt.

.PARAMETER OfflineDays
    Ab wie vielen Tagen ohne Kontakt ein Geraet als "offline" zaehlt (Standard: 7).

.EXAMPLE
    .\Sophos-Central-PRTG.ps1 -ClientId "xxxx" -ClientSecret "yyyy" -DeviceType server
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$ClientSecret,

    [ValidateSet('all', 'computer', 'server', 'mobile', 'ios', 'android')]
    [string]$DeviceType = 'all',

    [string]$TenantId = "",

    [string]$DataRegion = "",

    [int]$OfflineDays = 7,

    # Nur fuer Tests: Basis-URLs der Sophos-Dienste ueberschreiben
    [string]$IdentityUrl = 'https://id.sophos.com',
    [string]$CentralUrl  = 'https://api.central.sophos.com'
)

# --- PRTG erwartet UTF-8 auf stdout ---
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# --- TLS 1.2 erzwingen (haeufigste Fehlerursache unter Windows PowerShell 5.1) ---
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Out-PrtgError {
    param([string]$Message)
    # XML-kritische Zeichen entfernen
    $Message = ($Message -replace '[<>&]', ' ').Trim()
    Write-Output "<prtg><error>1</error><text>$Message</text></prtg>"
    exit 2
}

function Get-HttpErrorText {
    param($ErrorRecord)
    $text = $ErrorRecord.Exception.Message
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp) {
            $status = [int]$resp.StatusCode
            $body   = ''
            if ($resp.GetType().GetMethod('GetResponseStream')) {
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body   = $reader.ReadToEnd()
                $reader.Close()
            }
            if ($body.Length -gt 300) { $body = $body.Substring(0, 300) }
            $text = "HTTP $status - $body"
        }
    } catch { }
    return $text
}

# =====================================================================
# 1) OAuth2-Token holen
# =====================================================================
try {
    $tokenBody = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = 'token'
    }
    $tokenResponse = Invoke-RestMethod -Method Post `
        -Uri "$($IdentityUrl.TrimEnd('/'))/api/v2/oauth2/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $tokenBody `
        -TimeoutSec 30
    $accessToken = $tokenResponse.access_token
    if (-not $accessToken) { throw "Kein access_token in der Antwort erhalten." }
}
catch {
    Out-PrtgError ("Token-Abruf fehlgeschlagen (Client-ID/Secret pruefen): " + (Get-HttpErrorText $_))
}

$authHeaders = @{
    Authorization = "Bearer $accessToken"
    Accept        = 'application/json'
}

# =====================================================================
# 2) Tenant-ID und Datenregion ermitteln (falls nicht uebergeben)
# =====================================================================
if (-not $TenantId -or -not $DataRegion) {
    try {
        $whoami = Invoke-RestMethod -Method Get `
            -Uri "$($CentralUrl.TrimEnd('/'))/whoami/v1" `
            -Headers $authHeaders `
            -TimeoutSec 30

        if ($whoami.idType -ne 'tenant') {
            Out-PrtgError ("Die API-Anmeldedaten sind vom Typ '" + $whoami.idType + "'. " +
                "Bitte -TenantId und -DataRegion als Parameter angeben oder Tenant-Anmeldedaten verwenden.")
        }
        if (-not $TenantId)   { $TenantId   = $whoami.id }
        if (-not $DataRegion) { $DataRegion = $whoami.apiHosts.dataRegion }
    }
    catch {
        Out-PrtgError ("whoami-Abfrage fehlgeschlagen: " + (Get-HttpErrorText $_))
    }
}

$DataRegion = $DataRegion.TrimEnd('/')
$tenantHeaders = $authHeaders.Clone()
$tenantHeaders['X-Tenant-ID'] = $TenantId

# Generische paginierte GET-Abfrage. Unterstuetzt beide Sophos-Stile:
#   a) pages.nextKey  -> &pageFromKey=...   (Endpoint-/Common-API)
#   b) pages.current/pages.total -> &page=n (Mobile-API)
function Get-SophosItems {
    param(
        [string]$BaseUri,          # inkl. erster Query-Parameter (?pageSize=...)
        [hashtable]$Headers,
        [string]$ErrorContext
    )
    $items = @()
    $uri = $BaseUri
    $pageCount = 0
    try {
        while ($uri -and $pageCount -lt 100) {
            $pageCount++
            $page = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers -TimeoutSec 60
            if ($page.items) { $items += $page.items }
            $uri = $null
            if ($page.pages.nextKey) {
                $nextKey = [uri]::EscapeDataString($page.pages.nextKey)
                $uri = "$BaseUri&pageFromKey=$nextKey"
            }
            elseif ($page.pages.current -and $page.pages.total -and
                    $page.pages.current -lt $page.pages.total) {
                $next = [int]$page.pages.current + 1
                $uri = "$BaseUri&page=$next"
            }
        }
    }
    catch {
        Out-PrtgError ("$ErrorContext fehlgeschlagen: " + (Get-HttpErrorText $_))
    }
    return ,$items
}

# Liest das erste vorhandene Zeitstempel-Feld eines Geraets als UTC-DateTime
function Get-LastContact {
    param($Device)
    foreach ($field in @('lastSeenAt', 'lastSyncedAt', 'lastCheckInAt')) {
        $value = $Device.$field
        if ($value) {
            try {
                return [System.DateTimeOffset]::Parse(
                    $value, [System.Globalization.CultureInfo]::InvariantCulture
                ).UtcDateTime
            } catch { }
        }
    }
    return $null
}

$offlineLimit = (Get-Date).ToUniversalTime().AddDays(-1 * $OfflineDays)
$isMobile = $DeviceType -in @('mobile', 'ios', 'android')

# Zuordnung DeviceType -> Alert-Produktfilter der Common-API
$alertProducts = switch ($DeviceType) {
    'computer' { @('endpoint') }
    'server'   { @('server') }
    'mobile'   { @('mobile') }
    'ios'      { @('mobile') }
    'android'  { @('mobile') }
    default    { @() }   # all = kein Filter
}

# =====================================================================
# 3) Geraete abfragen (je nach Produktfilter)
# =====================================================================
$xml = New-Object System.Text.StringBuilder
[void]$xml.AppendLine('<prtg>')

function Add-Channel {
    param(
        [System.Text.StringBuilder]$Builder,
        [string]$Name,
        [long]$Value,
        [string]$LimitMaxError = $null,
        [string]$LimitMaxWarning = $null
    )
    [void]$Builder.AppendLine('  <result>')
    [void]$Builder.AppendLine("    <channel>$Name</channel>")
    [void]$Builder.AppendLine("    <value>$Value</value>")
    [void]$Builder.AppendLine('    <unit>Count</unit>')
    if ($LimitMaxError -ne $null -and $LimitMaxError -ne '') {
        [void]$Builder.AppendLine("    <limitmaxerror>$LimitMaxError</limitmaxerror>")
        [void]$Builder.AppendLine('    <limitmode>1</limitmode>')
    }
    elseif ($LimitMaxWarning -ne $null -and $LimitMaxWarning -ne '') {
        [void]$Builder.AppendLine("    <limitmaxwarning>$LimitMaxWarning</limitmaxwarning>")
        [void]$Builder.AppendLine('    <limitmode>1</limitmode>')
    }
    [void]$Builder.AppendLine('  </result>')
}

if (-not $isMobile) {
    # ----- Endpoint-API: Clients und/oder Server -----
    $endpointUri = "$DataRegion/endpoint/v1/endpoints?pageSize=500"
    if ($DeviceType -in @('computer', 'server')) {
        $endpointUri += "&type=$DeviceType"
    }
    $endpoints = Get-SophosItems -BaseUri $endpointUri -Headers $tenantHeaders `
        -ErrorContext 'Endpoint-Abfrage'

    $totalDevices   = $endpoints.Count
    $healthGood     = 0
    $healthSuspect  = 0
    $healthBad      = 0
    $healthUnknown  = 0
    $tamperDisabled = 0
    $offlineCount   = 0

    foreach ($ep in $endpoints) {
        switch ($ep.health.overall) {
            'good'       { $healthGood++ }
            'suspicious' { $healthSuspect++ }
            'bad'        { $healthBad++ }
            default      { $healthUnknown++ }
        }
        if ($ep.tamperProtectionEnabled -eq $false) { $tamperDisabled++ }
        $lastContact = Get-LastContact $ep
        if ($lastContact -and $lastContact -lt $offlineLimit) { $offlineCount++ }
    }

    Add-Channel $xml 'Geraete Gesamt'                 $totalDevices
    Add-Channel $xml 'Health Gut'                     $healthGood
    Add-Channel $xml 'Health Verdaechtig'             $healthSuspect -LimitMaxWarning 0
    Add-Channel $xml 'Health Schlecht'                $healthBad     -LimitMaxError 0
    Add-Channel $xml 'Health Unbekannt'               $healthUnknown
    Add-Channel $xml 'Tamper Protection deaktiviert'  $tamperDisabled -LimitMaxWarning 0
    Add-Channel $xml "Offline laenger $OfflineDays Tage" $offlineCount

    $summary = "$totalDevices Geraete ($DeviceType) | Gut: $healthGood, Verdaechtig: $healthSuspect, Schlecht: $healthBad"
}
else {
    # ----- Mobile-API: iOS / Android -----
    $devices = Get-SophosItems -BaseUri "$DataRegion/mobile/v1/devices?pageSize=100" `
        -Headers $tenantHeaders -ErrorContext 'Mobile-Geraete-Abfrage'

    # Plattform pro Geraet ermitteln (Feldname variiert je nach API-Version)
    function Get-Platform {
        param($Device)
        foreach ($value in @($Device.osPlatform, $Device.os.platform, $Device.platform)) {
            if ($value) { return ([string]$value).ToLowerInvariant() }
        }
        return ''
    }

    if ($DeviceType -in @('ios', 'android')) {
        $devices = @($devices | Where-Object { (Get-Platform $_) -eq $DeviceType })
    }

    $totalDevices = $devices.Count
    $iosCount     = 0
    $androidCount = 0
    $otherCount   = 0
    $offlineCount = 0

    foreach ($dev in $devices) {
        switch (Get-Platform $dev) {
            'ios'     { $iosCount++ }
            'android' { $androidCount++ }
            default   { $otherCount++ }
        }
        $lastContact = Get-LastContact $dev
        if ($lastContact -and $lastContact -lt $offlineLimit) { $offlineCount++ }
    }

    Add-Channel $xml 'Geraete Gesamt'   $totalDevices
    Add-Channel $xml 'Geraete iOS'      $iosCount
    Add-Channel $xml 'Geraete Android'  $androidCount
    Add-Channel $xml 'Geraete Andere'   $otherCount
    Add-Channel $xml "Offline laenger $OfflineDays Tage" $offlineCount

    $summary = "$totalDevices Mobilgeraete ($DeviceType) | iOS: $iosCount, Android: $androidCount"
}

# =====================================================================
# 4) Alerts abfragen (nach Produkt gefiltert)
# =====================================================================
$alerts = Get-SophosItems -BaseUri "$DataRegion/common/v1/alerts?pageSize=100" `
    -Headers $tenantHeaders -ErrorContext 'Alert-Abfrage'

$alertsHigh   = 0
$alertsMedium = 0
$alertsLow    = 0
foreach ($alert in $alerts) {
    if ($alertProducts.Count -gt 0 -and $alert.product -notin $alertProducts) { continue }
    switch ($alert.severity) {
        'high'   { $alertsHigh++ }
        'medium' { $alertsMedium++ }
        'low'    { $alertsLow++ }
    }
}

Add-Channel $xml 'Alerts Hoch'    $alertsHigh   -LimitMaxError 0
Add-Channel $xml 'Alerts Mittel'  $alertsMedium -LimitMaxWarning 0
Add-Channel $xml 'Alerts Niedrig' $alertsLow

# =====================================================================
# 5) PRTG-XML ausgeben
# =====================================================================
$summary += " | Alerts: $alertsHigh hoch / $alertsMedium mittel / $alertsLow niedrig"
[void]$xml.AppendLine("  <text>$summary</text>")
[void]$xml.AppendLine('</prtg>')

Write-Output $xml.ToString()
exit 0
