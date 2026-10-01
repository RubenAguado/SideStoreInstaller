# Todo en uno: Windows 11 -> regenerar pairing file de SideStore (iloader). Ejecutar en la torre.
# Uso: clic derecho > "Ejecutar con PowerShell"  (o pegar el contenido entero en una consola PowerShell)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Paso($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Find-Iloader {
    Get-ChildItem "$env:LOCALAPPDATA\iloader","$env:ProgramFiles\iloader","$env:LOCALAPPDATA\Programs\iloader" -Filter 'iloader.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User') + ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
}

function Ensure-Winget {
    Refresh-Path
    if (Get-Command winget -ErrorAction SilentlyContinue) { return }
    Write-Host "winget no esta instalado; intentando instalarlo..." -ForegroundColor Yellow

    # Metodo 1: registrar el App Installer que ya trae Windows 10/11 pero sin registrar
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
        Refresh-Path
    } catch { Write-Host "  metodo 1 (registrar App Installer) no valio: $($_.Exception.Message)" }
    if (Get-Command winget -ErrorAction SilentlyContinue) { Write-Host "winget listo." -ForegroundColor Green; return }

    # Metodo 2: modulo oficial Microsoft.WinGet.Client + Repair-WinGetPackageManager
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        Install-Module Microsoft.WinGet.Client -Force -Scope CurrentUser -Repository PSGallery -ErrorAction Stop
        Import-Module Microsoft.WinGet.Client
        Repair-WinGetPackageManager -AllUsers -ErrorAction Stop
        Refresh-Path
    } catch { Write-Host "  metodo 2 (modulo WinGet.Client) no valio: $($_.Exception.Message)" }
    if (Get-Command winget -ErrorAction SilentlyContinue) { Write-Host "winget listo." -ForegroundColor Green; return }

    # Metodo 3: descargar el msixbundle oficial + VCLibs (aka.ms/getwinget)
    try {
        $tmp = Join-Path $env:TEMP 'winget-setup'
        New-Item -ItemType Directory -Force $tmp | Out-Null
        $vc = Join-Path $tmp 'VCLibs.appx'
        $bundle = Join-Path $tmp 'winget.msixbundle'
        Invoke-WebRequest 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' -OutFile $vc -UseBasicParsing
        Invoke-WebRequest 'https://aka.ms/getwinget' -OutFile $bundle -UseBasicParsing
        Add-AppxPackage -Path $vc -ErrorAction SilentlyContinue
        Add-AppxPackage -Path $bundle -ErrorAction Stop
        Refresh-Path
    } catch { Write-Host "  metodo 3 (msixbundle) no valio: $($_.Exception.Message)" }
    if (Get-Command winget -ErrorAction SilentlyContinue) { Write-Host "winget listo." -ForegroundColor Green; return }

    throw "No he podido instalar winget. Instala 'App Installer' desde Microsoft Store (o https://aka.ms/getwinget), cierra y abre PowerShell y reintenta."
}

function Test-Url($url) {
    $h = ([uri]$url).Host
    $r = [ordered]@{ Url = $url; DNS = 'FALLA'; TCP443 = '-'; HTTP = '-'; IP = '' }
    try {
        $ip = (Resolve-DnsName $h -Type A -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1).IPAddress
        $r.DNS = 'ok'; $r.IP = $ip
    } catch { return [pscustomobject]$r }
    try {
        $c = New-Object Net.Sockets.TcpClient
        $t = $c.BeginConnect($ip, 443, $null, $null)
        if ($t.AsyncWaitHandle.WaitOne(6000) -and $c.Connected) { $r.TCP443 = 'ok' } else { $r.TCP443 = 'TIMEOUT' }
        $c.Close()
    } catch { $r.TCP443 = 'FALLA' }
    if ($r.TCP443 -eq 'ok') {
        try {
            $resp = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 10 -Headers @{ 'User-Agent' = 'ps' }
            $r.HTTP = [string]$resp.StatusCode
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            $r.HTTP = if ($code) { [string]$code } else { 'FALLA' }
        }
    }
    [pscustomobject]$r
}

Paso "0/4 Comprobando URLs de SideStore"
$urls = @(
    'https://sidestore.io',
    'https://sidestore.xyz',
    'https://docs.sidestore.io',
    'https://apps.sidestore.io',
    'https://ani.sidestore.io',
    'https://ani.sidestore.zip',
    'https://cdn.altstore.io',
    'https://iloader.app',
    'https://github.com/SideStore/SideStore',
    'https://api.github.com/repos/nab138/iloader/releases/latest'
)
$res = foreach ($u in $urls) { Test-Url $u }
$res | Format-Table Url, IP, DNS, TCP443, HTTP -AutoSize
$malas = $res | Where-Object { $_.DNS -ne 'ok' -or $_.TCP443 -ne 'ok' -or $_.HTTP -notmatch '^[23]' }
if ($malas) {
    Write-Host "URLs con problemas:" -ForegroundColor Yellow
    foreach ($m in $malas) {
        $why = if ($m.DNS -ne 'ok') { "DNS no resuelve (dominio muerto o DNS/Pi-hole lo bloquea)" }
               elseif ($m.TCP443 -ne 'ok') { "resuelve pero no conecta (bloqueo de IP/ISP, p.ej. LaLiga con Cloudflare, o servidor caido)" }
               else { "responde HTTP $($m.HTTP)" }
        Write-Host "  - $($m.Url): $why"
    }
    Write-Host "Prueba con otro dominio de la lista (p.ej. .xyz) o con VPN/otro DNS. Si falla github, iloader no se podra descargar." -ForegroundColor Yellow
} else {
    Write-Host "Todas las URLs responden." -ForegroundColor Green
}

Paso "1/4 Driver Apple Mobile Device Support"
if (Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue) {
    Write-Host "Ya instalado."
} else {
    Ensure-Winget
    winget install --id Apple.AppleMobileDeviceSupport -e --accept-package-agreements --accept-source-agreements
    Start-Sleep 3
    if (-not (Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue)) {
        throw "El driver no quedo instalado. Prueba 'winget install Apple.iTunes' y reintenta."
    }}

Paso "2/4 iloader"
$exe = Find-Iloader
if ($exe) {
    Write-Host "Ya instalado."
} else {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/nab138/iloader/releases/latest' -Headers @{ 'User-Agent' = 'ps' }
    $asset = $rel.assets | Where-Object name -eq 'iloader-windows-x64.msi'
    if (-not $asset) { throw "No encuentro iloader-windows-x64.msi en la release $($rel.tag_name)." }
    $msi = Join-Path $env:TEMP $asset.name
    Write-Host "Descargando iloader $($rel.tag_name)..."
    Invoke-WebRequest $asset.browser_download_url -OutFile $msi
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /passive" -Wait    $exe = Find-Iloader
}

Paso "3/4 Esperando el iPad por USB"
Write-Host "Conecta el iPad con cable, desbloqueado, y toca 'Confiar' si lo pide."
$visto = $false
for ($i = 0; $i -lt 60 -and -not $visto; $i++) {
    $visto = [bool](Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_05AC' -and $_.FriendlyName -match 'iPad|iPhone|Apple Mobile Device' })
    if (-not $visto) { Start-Sleep 2 }
}
if ($visto) { Write-Host "iPad detectado." -ForegroundColor Green }
else { Write-Host "No lo detecto en 2 min; sigue igualmente, iloader tambien lo busca por Wi-Fi." -ForegroundColor Yellow }

Paso "4/4 iloader"
if ($exe) { Start-Process $exe.FullName } else { Write-Host "Abre iloader desde el menu Inicio." }
$pasos = @(
    "Pulsa 'Delete Stored Pairing' (descarta el pairing viejo).",
    "Pulsa tu iPad en la lista y toca 'Confiar' en el iPad (codigo).",
    "Pulsa 'Manage Pairing File'.",
    "Junto a 'SideStore' (y LiveContainer si sale) pulsa 'Place'. Debe salir en verde 'Pairing file placed successfully!'."
)
for ($n = 0; $n -lt $pasos.Count; $n++) {
    Write-Host "`nPaso $($n+1)/$($pasos.Count): $($pasos[$n])" -ForegroundColor Yellow
    Read-Host "Cuando lo hayas hecho, pulsa Enter"
}

Write-Host "`nAbre SideStore en el iPad y prueba un refresco." -ForegroundColor Green
$ok = Read-Host "Funciona todo? (s = si, desinstalar iloader y los programas/drivers de Apple / n = dejarlo)"
if ($ok -notmatch '^[sSyY]') {
    Write-Host "Se deja todo instalado. Si sigue dando error: reinicia iPad y PC y repite los pasos de iloader."
    Read-Host "Enter para cerrar"
    return
}

Paso "Limpieza"
Get-Process iloader -ErrorAction SilentlyContinue | Stop-Process -Force

$claves = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'

function Quitar($patron, $nombre) {
    $apps = Get-ItemProperty $claves -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $patron }
    if (-not $apps) { Write-Host "${nombre}: no instalado."; return }
    foreach ($a in $apps) {
        Write-Host "Desinstalando $($a.DisplayName)..."
        if ($a.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
            Start-Process msiexec.exe -ArgumentList "/x $($a.PSChildName) /qn /norestart" -Wait
        } elseif ($a.QuietUninstallString) {
            Start-Process cmd.exe -ArgumentList "/c $($a.QuietUninstallString)" -Wait
        } elseif ($a.UninstallString) {
            Start-Process cmd.exe -ArgumentList "/c $($a.UninstallString) /quiet /uninstall" -Wait
        } else {
            Write-Host "  sin desinstalador; quitalo a mano desde Configuracion > Aplicaciones." -ForegroundColor Yellow
        }
    }
}

# Orden importante: iTunes primero, luego los componentes de los que depende.
Quitar '^iloader' 'iloader'
Remove-Item "$env:LOCALAPPDATA\iloader","$env:APPDATA\iloader","$env:APPDATA\app.iloader*","$env:LOCALAPPDATA\app.iloader*" -Recurse -Force -ErrorAction SilentlyContinue
if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget uninstall --id Apple.iTunes -e --silent 2>$null | Out-Null
}
Quitar '^iTunes$' 'iTunes'
Quitar '^Apple Mobile Device Support' 'Apple Mobile Device Support (driver)'
Quitar '^Apple Application Support' 'Apple Application Support'
Quitar '^Apple Software Update' 'Apple Software Update'
Quitar '^Bonjour' 'Bonjour'

Remove-Item (Join-Path $env:TEMP 'iloader-windows-x64.msi') -Force -ErrorAction SilentlyContinue

Write-Host "`nHecho. Todo desinstalado; el script se queda para relanzarlo cuando lo necesites." -ForegroundColor Green
Write-Host "Si algun driver sigue apareciendo, reinicia el PC." -ForegroundColor Yellow
Read-Host "Enter para cerrar"
