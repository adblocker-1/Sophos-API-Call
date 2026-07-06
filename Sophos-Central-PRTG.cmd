@echo off
rem =====================================================================
rem  PRTG-Wrapper fuer Sophos-Central-PRTG.ps1
rem
rem  Startet das PowerShell-Skript mit -ExecutionPolicy Bypass, sodass
rem  die Execution Policy des Systems NICHT geaendert werden muss.
rem
rem  Beide Dateien (diese .cmd und die .ps1) muessen im selben Ordner
rem  liegen, z. B.:
rem    C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\
rem
rem  In PRTG beim Sensor "EXE/Script Advanced" diese .cmd-Datei
rem  auswaehlen und die Parameter wie gewohnt angeben, z. B.:
rem    -ClientId "..." -ClientSecret "..." -DeviceType computer
rem =====================================================================

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Sophos-Central-PRTG.ps1" %*
exit /b %errorlevel%
