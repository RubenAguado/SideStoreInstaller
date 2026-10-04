@echo off
rem ============================================================================
rem  Instalar-SideStore.cmd  -  DOBLE CLIC para instalar SideStore en Windows.
rem  1) Pide permisos de administrador (UAC) si no los tiene.
rem  2) Usa sidestore-installer.ps1 de esta carpeta; si no esta, lo descarga.
rem  3) Lo ejecuta saltando la politica de ejecucion de PowerShell.
rem  Archivo ASCII a proposito (cmd lee mal los acentos).
rem ============================================================================
setlocal
title SideStore Installer

rem --- 1) Administrador ------------------------------------------------------
fltmc >nul 2>&1
if errorlevel 1 (
    echo Solicitando permisos de administrador, acepta el aviso de Windows...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
    if errorlevel 1 (
        echo.
        echo No se concedieron permisos de administrador. Cierra esto y vuelve a intentarlo.
        pause
    )
    exit /b
)

rem --- 2) Localizar o descargar el script -----------------------------------
set "PS1=%~dp0sidestore-installer.ps1"
if not exist "%PS1%" (
    set "PS1=%TEMP%\sidestore-installer.ps1"
    echo No encuentro sidestore-installer.ps1 junto a este archivo; descargandolo de GitHub...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; try { Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/RubenAguado/SideStoreInstaller/master/sidestore-installer.ps1' -OutFile $env:TEMP\sidestore-installer.ps1 } catch { Write-Host $_.Exception.Message; exit 1 }"
    if errorlevel 1 (
        echo.
        echo No se pudo descargar el script. Revisa tu conexion, DNS o VPN y vuelve a intentarlo.
        pause
        exit /b 1
    )
)

rem --- 3) Ejecutar -----------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath '%PS1%' -ErrorAction SilentlyContinue" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
exit /b %errorlevel%
