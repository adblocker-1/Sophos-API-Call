<#
.SYNOPSIS
    PRTG Custom Sensor (EXE/Script Advanced) fuer Sophos Central.

.DESCRIPTION
    Fragt die Sophos Central API ab und liefert das Ergebnis als PRTG-XML:
      1. OAuth2-Token holen        (https://id.sophos.com/api/v2/oauth2/token)
      2. Tenant + Datenregion      (https://api.central.sophos.com/whoami/v1)
      3. Endpoints abfragen        ({dataRegion}/endpoint/v1/endpoints)
      4. Alerts abfragen           ({dataRegion}/common/v1/alerts)

    Kanaele:
      - Endpoints Gesamt
      - Health Gut / Verdaechtig / Schlecht
      - Tamper Protection deaktiviert
      - Offline laenger als X Tage
      - Alerts Hoch / Mittel / Niedrig

.PARAMETER ClientId
    Client-ID der Sophos Central API-Anmeldedaten
    (Sophos Central Admin -> Globale Einstellungen -> API-Anmeldedaten-Verwaltung).

.PARAMETER ClientSecret
    Client-Secret der API-Anmeldedaten.

.PARAMETER TenantId
    Optional: Tenant-ID. Nur noetig bei Partner-/Organisations-Anmeldedaten.
    Bei normalen Tenant-Anmeldedaten wird sie automatisch ermittelt.

.PARAMETER DataRegion
    Optional: API-Host der Datenregion, z.B. https://api-eu01.central.sophos.com
    Wird normalerweise automatisch ermittelt.

.PARAMETER OfflineDays
    Ab wie vielen Tagen ohne Kontakt ein Endpoint als "offline" zaehlt (Standard: 7).

.EXAMPLE
    .\Sophos-Central-PRTG.ps1 -ClientId "xxxx" -ClientSecret "yyyy"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$ClientSecret,

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
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body   = $reader.ReadToEnd()
            $reader.Close()
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

# =====================================================================
# 3) Endpoints abfragen (mit Paginierung)
# =====================================================================
$endpoints = @()
try {
    $uri = "$DataRegion/endpoint/v1/endpoints?pageSize=500"
    $pageCount = 0
    while ($uri -and $pageCount -lt 40) {
        $pageCount++
        $page = Invoke-RestMethod -Method Get -Uri $uri -Headers $tenantHeaders -TimeoutSec 60
        if ($page.items) { $endpoints += $page.items }
        if ($page.pages.nextKey) {
            $nextKey = [uri]::EscapeDataString($page.pages.nextKey)
            $uri = "$DataRegion/endpoint/v1/endpoints?pageSize=500&pageFromKey=$nextKey"
        } else {
            $uri = $null
        }
    }
}
catch {
    Out-PrtgError ("Endpoint-Abfrage fehlgeschlagen: " + (Get-HttpErrorText $_))
}

$totalEndpoints  = $endpoints.Count
$healthGood      = 0
$healthSuspect   = 0
$healthBad       = 0
$healthUnknown   = 0
$tamperDisabled  = 0
$offlineCount    = 0

$offlineLimit = (Get-Date).ToUniversalTime().AddDays(-1 * $OfflineDays)

foreach ($ep in $endpoints) {
    switch ($ep.health.overall) {
        'good'       { $healthGood++ }
        'suspicious' { $healthSuspect++ }
        'bad'        { $healthBad++ }
        default      { $healthUnknown++ }
    }
    if ($ep.tamperProtectionEnabled -eq $false) { $tamperDisabled++ }
    if ($ep.lastSeenAt) {
        try {
            $lastSeen = [System.DateTimeOffset]::Parse(
                $ep.lastSeenAt,
                [System.Globalization.CultureInfo]::InvariantCulture
            ).UtcDateTime
            if ($lastSeen -lt $offlineLimit) { $offlineCount++ }
        } catch { }
    }
}

# =====================================================================
# 4) Alerts abfragen (mit Paginierung)
# =====================================================================
$alertsHigh   = 0
$alertsMedium = 0
$alertsLow    = 0
try {
    $uri = "$DataRegion/common/v1/alerts?pageSize=100"
    $pageCount = 0
    while ($uri -and $pageCount -lt 40) {
        $pageCount++
        $page = Invoke-RestMethod -Method Get -Uri $uri -Headers $tenantHeaders -TimeoutSec 60
        foreach ($alert in $page.items) {
            switch ($alert.severity) {
                'high'   { $alertsHigh++ }
                'medium' { $alertsMedium++ }
                'low'    { $alertsLow++ }
            }
        }
        if ($page.pages.nextKey) {
            $nextKey = [uri]::EscapeDataString($page.pages.nextKey)
            $uri = "$DataRegion/common/v1/alerts?pageSize=100&pageFromKey=$nextKey"
        } else {
            $uri = $null
        }
    }
}
catch {
    Out-PrtgError ("Alert-Abfrage fehlgeschlagen: " + (Get-HttpErrorText $_))
}

# =====================================================================
# 5) PRTG-XML ausgeben
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

Add-Channel $xml 'Endpoints Gesamt'               $totalEndpoints
Add-Channel $xml 'Health Gut'                     $healthGood
Add-Channel $xml 'Health Verdaechtig'             $healthSuspect -LimitMaxWarning 0
Add-Channel $xml 'Health Schlecht'                $healthBad     -LimitMaxError 0
Add-Channel $xml 'Health Unbekannt'               $healthUnknown
Add-Channel $xml 'Tamper Protection deaktiviert'  $tamperDisabled -LimitMaxWarning 0
Add-Channel $xml "Offline laenger $OfflineDays Tage" $offlineCount
Add-Channel $xml 'Alerts Hoch'                    $alertsHigh    -LimitMaxError 0
Add-Channel $xml 'Alerts Mittel'                  $alertsMedium  -LimitMaxWarning 0
Add-Channel $xml 'Alerts Niedrig'                 $alertsLow

$statusText = "$totalEndpoints Endpoints | Gut: $healthGood, Verdaechtig: $healthSuspect, Schlecht: $healthBad | Alerts: $alertsHigh hoch / $alertsMedium mittel / $alertsLow niedrig"
[void]$xml.AppendLine("  <text>$statusText</text>")
[void]$xml.AppendLine('</prtg>')

Write-Output $xml.ToString()
exit 0
