# Sophos Central → PRTG Sensor

PowerShell-Skript für einen PRTG **EXE/Script Advanced**-Sensor, der Sophos Central
über die offizielle API abfragt und die Ergebnisse als Kanäle im PRTG-Dashboard anzeigt.

## Was das Skript abfragt

| Kanal | Quelle | Alarm |
|---|---|---|
| Endpoints Gesamt | `/endpoint/v1/endpoints` | – |
| Health Gut | `health.overall = good` | – |
| Health Verdaechtig | `health.overall = suspicious` | Warnung bei > 0 |
| Health Schlecht | `health.overall = bad` | **Fehler bei > 0** |
| Health Unbekannt | kein Health-Status gemeldet | – |
| Tamper Protection deaktiviert | `tamperProtectionEnabled = false` | Warnung bei > 0 |
| Offline länger X Tage | `lastSeenAt` älter als X Tage (Standard 7) | – |
| Alerts Hoch | `/common/v1/alerts`, `severity = high` | **Fehler bei > 0** |
| Alerts Mittel | `severity = medium` | Warnung bei > 0 |
| Alerts Niedrig | `severity = low` | – |

Der Sensortext zeigt zusätzlich eine Zusammenfassung, z. B.:
`142 Endpoints | Gut: 139, Verdaechtig: 2, Schlecht: 1 | Alerts: 0 hoch / 3 mittel / 5 niedrig`

## Ablauf der API-Abfrage

1. **Token holen**: `POST https://id.sophos.com/api/v2/oauth2/token` (OAuth2 Client Credentials, `scope=token`)
2. **whoami**: `GET https://api.central.sophos.com/whoami/v1` → liefert Tenant-ID und Datenregion (z. B. `api-eu01`)
3. **Endpoints**: `GET {dataRegion}/endpoint/v1/endpoints` mit Header `X-Tenant-ID` (inkl. Paginierung)
4. **Alerts**: `GET {dataRegion}/common/v1/alerts` (inkl. Paginierung)

## Einrichtung

### 1. API-Anmeldedaten in Sophos Central erstellen

1. In **Sophos Central Admin** anmelden
2. **Globale Einstellungen → API-Anmeldedaten-Verwaltung** (API Credentials Management)
3. **Anmeldedaten hinzufügen**, Rolle **Service Principal ReadOnly** genügt
4. **Client-ID** und **Client-Secret** notieren (das Secret wird nur einmal angezeigt!)

> Wichtig: Es müssen **Tenant**-Anmeldedaten sein. Bei Partner-/Organisations-Anmeldedaten
> müssen zusätzlich `-TenantId` und `-DataRegion` als Parameter angegeben werden.

### 2. Skript auf dem PRTG-Probe-Server ablegen

Datei `Sophos-Central-PRTG.ps1` kopieren nach:

```
C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\
```

(auf dem Server, auf dem die **Probe** läuft, die den Sensor ausführt — bei Remote Probes auf dem Probe-Server, nicht auf dem Core-Server)

### 3. Skript einmal manuell testen

Auf dem Probe-Server in einer PowerShell ausführen:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\Sophos-Central-PRTG.ps1" -ClientId "DEINE-CLIENT-ID" -ClientSecret "DEIN-SECRET"
```

Erwartete Ausgabe: XML, das mit `<prtg>` beginnt und `<result>`-Blöcke enthält.
Bei einem Fehler steht die Ursache im `<text>`-Element.

### 4. Sensor in PRTG anlegen

1. Gerät auswählen (z. B. ein Dummy-Gerät „Sophos Central") → **Sensor hinzufügen**
2. Sensortyp: **EXE/Script (Erweitert)** / **EXE/Script Advanced**
3. **EXE/Skript**: `Sophos-Central-PRTG.ps1` auswählen
4. **Parameter**:
   ```
   -ClientId "DEINE-CLIENT-ID" -ClientSecret "DEIN-SECRET"
   ```
   Optional:
   ```
   -OfflineDays 14
   -TenantId "..." -DataRegion "https://api-eu01.central.sophos.com"
   ```
5. **Timeout** des Sensors auf mindestens **120 Sekunden** stellen (bei vielen Endpoints)
6. Abfrageintervall: **5–15 Minuten** genügt (die Sophos-API hat Rate-Limits)

## Fehlerbehebung („die API-Abfrage funktioniert nicht")

| Symptom | Ursache | Lösung |
|---|---|---|
| `Token-Abruf fehlgeschlagen … HTTP 401` | Client-ID/Secret falsch oder Secret abgelaufen | Neue API-Anmeldedaten in Sophos Central erstellen |
| `Die Anfrage wurde abgebrochen: Es konnte kein geschützter SSL/TLS-Kanal erstellt werden` | TLS 1.2 nicht aktiv | Das Skript erzwingt TLS 1.2 bereits; sonst Windows/.NET aktualisieren |
| Sensor meldet „Ausführung nicht möglich" / Execution Policy | PowerShell Execution Policy blockiert | PRTG startet Skripte mit Bypass; beim manuellen Test `-ExecutionPolicy Bypass` verwenden |
| `whoami-Abfrage fehlgeschlagen: HTTP 403` | Anmeldedaten haben keine ausreichende Rolle | Rolle **Service Principal ReadOnly** (oder höher) zuweisen |
| `Die API-Anmeldedaten sind vom Typ 'partner'` | Partner-Anmeldedaten statt Tenant | `-TenantId` und `-DataRegion` als Parameter mitgeben |
| Timeout / keine Verbindung | Firewall/Proxy blockiert ausgehendes HTTPS | Vom Probe-Server Zugriff auf `id.sophos.com`, `api.central.sophos.com` und `api-<region>.central.sophos.com` (Port 443) freigeben |
| Sensor zeigt „XML: The returned XML does not match the expected schema" | Skript gibt Fehlermeldung/Warnung vor dem XML aus | Skript manuell auf dem Probe-Server testen und Ausgabe prüfen |
| HTTP 429 | Rate-Limit der Sophos-API | Abfrageintervall des Sensors erhöhen (≥ 5 Minuten) |

## Parameter-Übersicht

| Parameter | Pflicht | Standard | Beschreibung |
|---|---|---|---|
| `-ClientId` | ja | – | Client-ID der Sophos-API-Anmeldedaten |
| `-ClientSecret` | ja | – | Client-Secret |
| `-TenantId` | nein | automatisch | Nur bei Partner-/Org-Anmeldedaten nötig |
| `-DataRegion` | nein | automatisch | z. B. `https://api-eu01.central.sophos.com` |
| `-OfflineDays` | nein | `7` | Ab wann ein Endpoint als offline zählt |
| `-IdentityUrl` | nein | `https://id.sophos.com` | Nur für Tests (Mock-Server) |
| `-CentralUrl` | nein | `https://api.central.sophos.com` | Nur für Tests (Mock-Server) |

## Getestet

Das Skript wurde mit PowerShell 7 gegen eine simulierte Sophos-Central-API
(Token, whoami, Endpoints mit Paginierung, Alerts) End-to-End getestet:
Header (`Authorization`, `X-Tenant-ID`), Token-Request-Body, Paginierung,
alle Kanalwerte und das PRTG-Fehler-XML wurden verifiziert.
