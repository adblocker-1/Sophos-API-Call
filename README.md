# Sophos Central → PRTG Sensor

PowerShell-Skript für einen PRTG **EXE/Script Advanced**-Sensor, der Sophos Central
über die offizielle API abfragt und die Ergebnisse als Kanäle im PRTG-Dashboard anzeigt.
Über den Parameter `-DeviceType` lässt sich nach Produkt filtern, sodass pro Produkt
ein eigener Sensor angelegt werden kann.

## Produktfilter (`-DeviceType`)

| Wert | Bedeutung | Datenquelle |
|---|---|---|
| `all` (Standard) | Alle Endpoints (Clients + Server) | `/endpoint/v1/endpoints` |
| `computer` | Nur Endpoint Clients (Workstations) | `/endpoint/v1/endpoints?type=computer` |
| `server` | Nur Endpoint Server | `/endpoint/v1/endpoints?type=server` |
| `mobile` | Alle Mobilgeräte (Sophos Mobile) | `/mobile/v1/devices` |
| `ios` | Nur iOS-Geräte | `/mobile/v1/devices` (gefiltert) |
| `android` | Nur Android-Geräte | `/mobile/v1/devices` (gefiltert) |

Die Alerts (`/common/v1/alerts`) werden automatisch passend zum Filter eingeschränkt:
`computer` → Produkt *endpoint*, `server` → Produkt *server*, `mobile`/`ios`/`android` → Produkt *mobile*,
`all` → alle Produkte.

## Kanäle

**Bei `all` / `computer` / `server`:**

| Kanal | Quelle | Alarm |
|---|---|---|
| Geraete Gesamt | Anzahl Endpoints | – |
| Health Gut / Verdaechtig / Schlecht / Unbekannt | `health.overall` | Warnung bei verdächtig > 0, **Fehler bei schlecht > 0** |
| Tamper Protection deaktiviert | `tamperProtectionEnabled = false` | Warnung bei > 0 |
| Offline laenger X Tage | `lastSeenAt` älter als X Tage | – |
| Alerts Hoch / Mittel / Niedrig | `severity` | **Fehler bei hoch > 0**, Warnung bei mittel > 0 |

**Bei `mobile` / `ios` / `android`:**

| Kanal | Quelle | Alarm |
|---|---|---|
| Geraete Gesamt | Anzahl Mobilgeräte | – |
| Geraete iOS / Android / Andere | `osPlatform` | – |
| Offline laenger X Tage | letzter Sync älter als X Tage | – |
| Alerts Hoch / Mittel / Niedrig | `severity` (Produkt *mobile*) | **Fehler bei hoch > 0**, Warnung bei mittel > 0 |

Der Sensortext zeigt zusätzlich eine Zusammenfassung, z. B.:
`142 Geraete (computer) | Gut: 139, Verdaechtig: 2, Schlecht: 1 | Alerts: 0 hoch / 3 mittel / 5 niedrig`

## Ablauf der API-Abfrage

1. **Token holen**: `POST https://id.sophos.com/api/v2/oauth2/token` (OAuth2 Client Credentials, `scope=token`)
2. **whoami**: `GET https://api.central.sophos.com/whoami/v1` → liefert Tenant-ID und Datenregion (z. B. `api-eu01`)
3. **Geräte**: Endpoint- oder Mobile-API mit Header `X-Tenant-ID` (inkl. Paginierung)
4. **Alerts**: `GET {dataRegion}/common/v1/alerts` (inkl. Paginierung, nach Produkt gefiltert)

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
powershell -ExecutionPolicy Bypass -File "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\Sophos-Central-PRTG.ps1" -ClientId "DEINE-CLIENT-ID" -ClientSecret "DEIN-SECRET" -DeviceType computer
```

Erwartete Ausgabe: XML, das mit `<prtg>` beginnt und `<result>`-Blöcke enthält.
Bei einem Fehler steht die Ursache im `<text>`-Element.

### 4. Sensoren in PRTG anlegen (einer pro Produkt)

1. Gerät auswählen (z. B. ein Dummy-Gerät „Sophos Central") → **Sensor hinzufügen**
2. Sensortyp: **EXE/Script (Erweitert)** / **EXE/Script Advanced**
3. **EXE/Skript**: `Sophos-Central-PRTG.ps1` auswählen
4. **Parameter** — z. B. drei Sensoren:
   ```
   -ClientId "DEINE-CLIENT-ID" -ClientSecret "DEIN-SECRET" -DeviceType computer
   -ClientId "DEINE-CLIENT-ID" -ClientSecret "DEIN-SECRET" -DeviceType server
   -ClientId "DEINE-CLIENT-ID" -ClientSecret "DEIN-SECRET" -DeviceType mobile
   ```
   Optional zusätzlich: `-OfflineDays 14`
5. **Timeout** des Sensors auf mindestens **120 Sekunden** stellen (bei vielen Geräten)
6. Abfrageintervall: **5–15 Minuten** genügt (die Sophos-API hat Rate-Limits)

## Fehlerbehebung („die API-Abfrage funktioniert nicht")

| Symptom | Ursache | Lösung |
|---|---|---|
| `Token-Abruf fehlgeschlagen … HTTP 401` | Client-ID/Secret falsch oder Secret abgelaufen | Neue API-Anmeldedaten in Sophos Central erstellen |
| `Die Anfrage wurde abgebrochen: Es konnte kein geschützter SSL/TLS-Kanal erstellt werden` | TLS 1.2 nicht aktiv | Das Skript erzwingt TLS 1.2 bereits; sonst Windows/.NET aktualisieren |
| Sensor meldet „Ausführung nicht möglich" / Execution Policy | PowerShell Execution Policy blockiert | PRTG startet Skripte mit Bypass; beim manuellen Test `-ExecutionPolicy Bypass` verwenden |
| `whoami-Abfrage fehlgeschlagen: HTTP 403` | Anmeldedaten haben keine ausreichende Rolle | Rolle **Service Principal ReadOnly** (oder höher) zuweisen |
| `Mobile-Geraete-Abfrage fehlgeschlagen: HTTP 403/404` | Kein Sophos-Mobile-Produkt lizenziert/aktiv | `-DeviceType mobile/ios/android` nur mit Sophos-Mobile-Lizenz nutzbar |
| `Die API-Anmeldedaten sind vom Typ 'partner'` | Partner-Anmeldedaten statt Tenant | `-TenantId` und `-DataRegion` als Parameter mitgeben |
| Timeout / keine Verbindung | Firewall/Proxy blockiert ausgehendes HTTPS | Vom Probe-Server Zugriff auf `id.sophos.com`, `api.central.sophos.com` und `api-<region>.central.sophos.com` (Port 443) freigeben |
| Sensor zeigt „XML: The returned XML does not match the expected schema" | Skript gibt Fehlermeldung/Warnung vor dem XML aus | Skript manuell auf dem Probe-Server testen und Ausgabe prüfen |
| HTTP 429 | Rate-Limit der Sophos-API | Abfrageintervall des Sensors erhöhen (≥ 5 Minuten) |

## Parameter-Übersicht

| Parameter | Pflicht | Standard | Beschreibung |
|---|---|---|---|
| `-ClientId` | ja | – | Client-ID der Sophos-API-Anmeldedaten |
| `-ClientSecret` | ja | – | Client-Secret |
| `-DeviceType` | nein | `all` | Produktfilter: `all`, `computer`, `server`, `mobile`, `ios`, `android` |
| `-TenantId` | nein | automatisch | Nur bei Partner-/Org-Anmeldedaten nötig |
| `-DataRegion` | nein | automatisch | z. B. `https://api-eu01.central.sophos.com` |
| `-OfflineDays` | nein | `7` | Ab wann ein Gerät als offline zählt |
| `-IdentityUrl` | nein | `https://id.sophos.com` | Nur für Tests (Mock-Server) |
| `-CentralUrl` | nein | `https://api.central.sophos.com` | Nur für Tests (Mock-Server) |

## Getestet

Das Skript wurde mit PowerShell 7 gegen eine simulierte Sophos-Central-API
End-to-End getestet — alle sechs `-DeviceType`-Varianten: Header
(`Authorization`, `X-Tenant-ID`), Token-Request-Body, `type=`-Filter der
Endpoint-API, beide Paginierungsstile (nextKey und seitenbasiert),
Alert-Produktfilter, alle Kanalwerte und das PRTG-Fehler-XML.
