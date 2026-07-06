<#
.SYNOPSIS
    Signiert Sophos-Central-PRTG.ps1 mit einem Code-Signing-Zertifikat
    (Authenticode), damit das Skript unter AllSigned/RemoteSigned laeuft,
    ohne die Execution Policy zu aendern.

.DESCRIPTION
    Muss unter Windows in einer PowerShell **als Administrator** ausgefuehrt
    werden (auf dem PRTG-Probe-Server).

    Drei Varianten fuer das Zertifikat:
      1. -Thumbprint  : vorhandenes Code-Signing-Zertifikat aus dem
                        Zertifikatspeicher verwenden (z.B. von der Firmen-CA)
      2. -PfxPath     : Zertifikat aus einer PFX-Datei verwenden
      3. (ohne beides): es wird ein selbstsigniertes Code-Signing-Zertifikat
                        erstellt (Laufzeit 5 Jahre)

    Bei Variante 2 und 3 wird das Zertifikat automatisch in die Speicher
    "Vertrauenswuerdige Stammzertifizierungsstellen" (Root) und
    "Vertrauenswuerdige Herausgeber" (TrustedPublisher) des Computers
    importiert, damit die Signatur fuer ALLE Konten gueltig ist - auch fuer
    das Dienstkonto der PRTG-Probe - und keine Ausfuehrungs-Rueckfrage kommt.

    WICHTIG: Nach jeder Aenderung an der .ps1-Datei muss neu signiert werden!

.PARAMETER ScriptPath
    Pfad zum zu signierenden Skript.
    Standard: Sophos-Central-PRTG.ps1 im selben Ordner wie dieses Skript.

.PARAMETER Thumbprint
    Thumbprint eines vorhandenen Code-Signing-Zertifikats
    (gesucht wird in Cert:\CurrentUser\My und Cert:\LocalMachine\My).

.PARAMETER PfxPath
    Pfad zu einer PFX-Datei mit Code-Signing-Zertifikat.

.PARAMETER PfxPassword
    Passwort der PFX-Datei (als SecureString abgefragt, wenn nicht angegeben).

.PARAMETER TimestampServer
    Zeitstempel-Server, damit die Signatur auch nach Ablauf des Zertifikats
    gueltig bleibt. Standard: DigiCert.

.EXAMPLE
    # Selbstsigniertes Zertifikat erstellen und signieren (als Administrator):
    .\Sign-SophosScript.ps1

.EXAMPLE
    # Vorhandenes Zertifikat der Firmen-CA verwenden:
    .\Sign-SophosScript.ps1 -Thumbprint "A1B2C3D4E5F6..."

.EXAMPLE
    # Zertifikat aus PFX-Datei verwenden:
    .\Sign-SophosScript.ps1 -PfxPath "C:\Zertifikate\codesign.pfx"
#>

[CmdletBinding(DefaultParameterSetName = 'SelfSigned')]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'Sophos-Central-PRTG.ps1'),

    [Parameter(ParameterSetName = 'Thumbprint', Mandatory = $true)]
    [string]$Thumbprint,

    [Parameter(ParameterSetName = 'Pfx', Mandatory = $true)]
    [string]$PfxPath,

    [Parameter(ParameterSetName = 'Pfx')]
    [SecureString]$PfxPassword,

    [string]$TimestampServer = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ScriptPath)) {
    throw "Skript nicht gefunden: $ScriptPath"
}

if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    throw "Authenticode-Signierung ist nur unter Windows moeglich. Bitte auf dem PRTG-Probe-Server ausfuehren."
}

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Importiert das Zertifikat (nur oeffentlicher Teil) in Root + TrustedPublisher
# des Computers, damit die Signatur fuer alle Konten als vertrauenswuerdig gilt.
function Install-TrustedCertificate {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    if (-not (Test-IsAdministrator)) {
        throw ("Fuer den Import in die Computer-Zertifikatspeicher sind Administratorrechte noetig. " +
               "Bitte PowerShell 'Als Administrator ausfuehren' und erneut starten.")
    }

    foreach ($storeName in @('Root', 'TrustedPublisher')) {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
            $storeName, [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $alreadyThere = $store.Certificates | Where-Object { $_.Thumbprint -eq $Certificate.Thumbprint }
        if (-not $alreadyThere) {
            # Nur den oeffentlichen Teil ablegen (ohne privaten Schluessel)
            $publicOnly = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
                ,$Certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
            $store.Add($publicOnly)
            Write-Host "Zertifikat in LocalMachine\$storeName importiert."
        }
        else {
            Write-Host "Zertifikat ist bereits in LocalMachine\$storeName vorhanden."
        }
        $store.Close()
    }
}

# ---------------------------------------------------------------------
# 1) Zertifikat beschaffen
# ---------------------------------------------------------------------
$cert = $null

switch ($PSCmdlet.ParameterSetName) {

    'Thumbprint' {
        $clean = $Thumbprint -replace '\s', ''
        foreach ($location in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
            $found = Get-ChildItem $location -CodeSigningCert -ErrorAction SilentlyContinue |
                     Where-Object { $_.Thumbprint -eq $clean }
            if ($found) { $cert = $found | Select-Object -First 1; break }
        }
        if (-not $cert) {
            throw "Kein Code-Signing-Zertifikat mit Thumbprint '$clean' in CurrentUser\My oder LocalMachine\My gefunden."
        }
        Write-Host "Verwende vorhandenes Zertifikat: $($cert.Subject) ($($cert.Thumbprint))"
        # Von einer CA ausgestellte Zertifikate sind i.d.R. bereits vertrauenswuerdig.
        # TrustedPublisher ist fuer AllSigned trotzdem noetig:
        Install-TrustedCertificate -Certificate $cert
    }

    'Pfx' {
        if (-not (Test-Path $PfxPath)) { throw "PFX-Datei nicht gefunden: $PfxPath" }
        if (-not $PfxPassword) {
            $PfxPassword = Read-Host -AsSecureString -Prompt "Passwort der PFX-Datei"
        }
        $cert = Get-PfxCertificate -FilePath $PfxPath -Password $PfxPassword
        if (-not $cert.HasPrivateKey) { throw "Die PFX-Datei enthaelt keinen privaten Schluessel." }
        Write-Host "Verwende Zertifikat aus PFX: $($cert.Subject) ($($cert.Thumbprint))"
        Install-TrustedCertificate -Certificate $cert
    }

    'SelfSigned' {
        # Gibt es schon ein frueher von diesem Skript erstelltes Zertifikat?
        $subject = 'CN=PRTG Sophos Sensor Code Signing'
        $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
                Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date) } |
                Sort-Object NotAfter -Descending | Select-Object -First 1
        if ($cert) {
            Write-Host "Verwende vorhandenes selbstsigniertes Zertifikat: $($cert.Thumbprint)"
        }
        else {
            Write-Host "Erstelle selbstsigniertes Code-Signing-Zertifikat ..."
            $cert = New-SelfSignedCertificate `
                -Type CodeSigningCert `
                -Subject $subject `
                -KeyAlgorithm RSA -KeyLength 2048 `
                -HashAlgorithm SHA256 `
                -NotAfter (Get-Date).AddYears(5) `
                -CertStoreLocation 'Cert:\CurrentUser\My'
            Write-Host "Zertifikat erstellt: $($cert.Thumbprint) (gueltig bis $($cert.NotAfter.ToShortDateString()))"
        }
        Install-TrustedCertificate -Certificate $cert
    }
}

# ---------------------------------------------------------------------
# 2) Skript signieren
# ---------------------------------------------------------------------
Write-Host "Signiere: $ScriptPath"
$result = Set-AuthenticodeSignature `
    -FilePath $ScriptPath `
    -Certificate $cert `
    -HashAlgorithm SHA256 `
    -TimestampServer $TimestampServer

# ---------------------------------------------------------------------
# 3) Signatur pruefen
# ---------------------------------------------------------------------
$check = Get-AuthenticodeSignature -FilePath $ScriptPath
Write-Host ""
Write-Host "Signaturstatus : $($check.Status)"
Write-Host "Zertifikat     : $($check.SignerCertificate.Subject)"
Write-Host "Gueltig bis    : $($check.SignerCertificate.NotAfter)"

if ($check.Status -eq 'Valid') {
    Write-Host ""
    Write-Host "Fertig! Das Skript ist signiert und kann ohne Aenderung der Execution Policy ausgefuehrt werden." -ForegroundColor Green
    Write-Host "WICHTIG: Nach jeder Aenderung an der .ps1-Datei muss dieses Skript erneut ausgefuehrt werden."
}
else {
    Write-Warning "Signaturstatus ist '$($check.Status)' - $($check.StatusMessage)"
    exit 1
}
