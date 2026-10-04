<#
.SYNOPSIS
    Instalador todo-en-uno de SideStore para Windows 10/11 (x64) usando iloader.

.DESCRIPTION
    Modo Instalar : prepara el PC (driver USB de Apple + iloader), espera al iPhone/iPad y te guia
                    hasta tener SideStore funcionando. Es el modo por defecto.
    Modo Pairing  : solo regenera el pairing file (iOS actualizado, SideStore lo pide otra vez).
    Modo Limpiar  : desinstala iloader y los componentes de Apple.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\sidestore-installer.ps1
    powershell -ExecutionPolicy Bypass -File .\sidestore-installer.ps1 -Modo Pairing
#>
[CmdletBinding()]
param(
    [ValidateSet('Instalar', 'Pairing', 'Limpiar')]
    [string]$Modo
)

# Nota: el archivo es ASCII a proposito (PowerShell 5.1 lee mal UTF-8 sin BOM).
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 12288 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$script:Dir      = Join-Path $env:LOCALAPPDATA 'SideStoreInstaller'
$script:Estado   = Join-Path $script:Dir 'estado.json'
$script:Servicio = 'Apple Mobile Device Service'
$script:Claves   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                   'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'

# ---------------------------------------------------------------- utilidades
function Paso($t)  { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Ok($t)    { Write-Host $t -ForegroundColor Green }
function Aviso($t) { Write-Host $t -ForegroundColor Yellow }
function Pausa($m = 'Pulsa Enter para continuar') { [void](Read-Host $m) }

function Confirmar([string]$Pregunta, [bool]$PorDefecto = $false) {
    $sufijo = if ($PorDefecto) { '[S/n]' } else { '[s/N]' }
    $r = Read-Host "$Pregunta $sufijo"
    if ([string]::IsNullOrWhiteSpace($r)) { return $PorDefecto }
    return ($r -match '^[sSyY]')
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
}

function Set-Estado([string]$Clave, $Valor) {
    $h = @{}
    if (Test-Path $script:Estado) {
        try { (Get-Content $script:Estado -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } } catch { }
    }
    $h[$Clave] = $Valor
    New-Item -ItemType Directory -Force $script:Dir | Out-Null
    $h | ConvertTo-Json | Set-Content $script:Estado -Encoding ASCII
}

function Get-Estado([string]$Clave) {
    if (-not (Test-Path $script:Estado)) { return $false }
    try { return [bool](Get-Content $script:Estado -Raw | ConvertFrom-Json).$Clave } catch { return $false }
}

function Invoke-Winget([string[]]$Argumentos) {
    $antes = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & winget @Argumentos | Out-Host
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $antes }
}

function Get-Archivo([string]$Url, [string]$Destino, [string]$Magia) {
    # $Magia: 'MSI' (D0 CF 11 E0) o 'EXE' (MZ). Evita guardar paginas HTML de error como si fueran instaladores.
    $ProgressPreference = 'SilentlyContinue'
    $ultimo = ''
    for ($i = 1; $i -le 3; $i++) {
        try {
            Remove-Item $Destino -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $Url -OutFile $Destino -UseBasicParsing -TimeoutSec 600 -Headers @{ 'User-Agent' = 'Mozilla/5.0 SideStoreInstaller' }
            if ((Get-Item $Destino).Length -lt 500KB) { throw 'archivo demasiado pequeno' }
            $fs = [IO.File]::OpenRead($Destino)
            try { $b = New-Object byte[] 4; [void]$fs.Read($b, 0, 4) } finally { $fs.Dispose() }
            $okMagia = if ($Magia -eq 'MSI') { ($b[0] -eq 0xD0 -and $b[1] -eq 0xCF -and $b[2] -eq 0x11 -and $b[3] -eq 0xE0) }
                       else { ($b[0] -eq 0x4D -and $b[1] -eq 0x5A) }
            if (-not $okMagia) { throw 'el archivo descargado no es un instalador valido' }
            return
        } catch {
            $ultimo = $_.Exception.Message
            Aviso "  intento $i/3 fallido: $ultimo"
            Start-Sleep (2 * $i)
        }
    }
    try {
        Aviso '  probando con BITS...'
        Start-BitsTransfer -Source $Url -Destination $Destino -ErrorAction Stop
        if ((Get-Item $Destino).Length -ge 500KB) { return }
    } catch { $ultimo = $_.Exception.Message }
    throw "No he podido descargar $Url ($ultimo). Comprueba tu conexion/DNS/VPN."
}

# ---------------------------------------------------------------- comprobaciones
function Test-Sistema {
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'iloader solo funciona en Windows de 64 bits.'
    }
    $arm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64')
    if ($arm -and [Environment]::OSVersion.Version.Build -lt 22000) {
        throw 'Windows 10 en ARM no esta soportado por iloader. Usa otro PC o Windows 11.'
    }
    if ($arm) { Aviso 'Windows ARM64 detectado: iloader (x64) va por emulacion y los drivers de Apple pueden dar problemas.' }
    Ok "Sistema compatible (Windows $([Environment]::OSVersion.Version), 64 bits)."
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
            $code = $null
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            $r.HTTP = if ($code) { [string]$code } else { 'FALLA' }
        }
    }
    [pscustomobject]$r
}

function Test-Red {
    $urls = @(
        'https://github.com/nab138/iloader',
        'https://iloader.app',
        'https://github.com/SideStore/SideStore',
        'https://sidestore.io',
        'https://docs.sidestore.io',
        'https://apps.sidestore.io',
        'https://cdn.altstore.io',
        'https://ani.sidestore.io',
        'https://www.apple.com/itunes/download/win64'
    )
    $res = foreach ($u in $urls) { Test-Url $u }
    $res | Format-Table Url, IP, DNS, TCP443, HTTP -AutoSize | Out-Host
    $malas = @($res | Where-Object { $_.DNS -ne 'ok' -or $_.TCP443 -ne 'ok' -or $_.HTTP -notmatch '^[23]' })
    if (-not $malas) { Ok 'Todas las URLs responden.'; return }
    Aviso 'URLs con problemas:'
    foreach ($m in $malas) {
        $why = if ($m.DNS -ne 'ok') { 'DNS no resuelve (dominio muerto o DNS/Pi-hole lo bloquea)' }
               elseif ($m.TCP443 -ne 'ok') { 'resuelve pero no conecta (bloqueo de IP/ISP, p.ej. LaLiga con Cloudflare, o servidor caido)' }
               else { "responde HTTP $($m.HTTP)" }
        Aviso "  - $($m.Url): $why"
    }
    if ($malas | Where-Object { $_.Url -match 'github\.com/nab138' }) {
        Aviso 'GitHub no responde: sin el no se puede descargar iloader. Prueba VPN u otro DNS (1.1.1.1 / 8.8.8.8).'
        if (-not (Confirmar 'Continuar igualmente?' $false)) { throw 'Cancelado: sin acceso a GitHub.' }
    } else {
        Aviso 'Si un dominio de SideStore falla, SideStore/iloader usan alternativas (p.ej. otro servidor anisette en los ajustes de iloader).'
    }
}

# ---------------------------------------------------------------- winget
function Initialize-Winget {
    Update-Path
    if (Get-Command winget -ErrorAction SilentlyContinue) { return }
    Aviso 'winget no esta instalado; intentando instalarlo...'

    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
        Update-Path
    } catch { Write-Host "  metodo 1 (registrar App Installer) no valio: $($_.Exception.Message)" }
    if (Get-Command winget -ErrorAction SilentlyContinue) { Ok 'winget listo.'; return }

    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        Install-Module Microsoft.WinGet.Client -Force -Scope CurrentUser -Repository PSGallery -ErrorAction Stop
        Import-Module Microsoft.WinGet.Client
        Repair-WinGetPackageManager -AllUsers -ErrorAction Stop
        Update-Path
    } catch { Write-Host "  metodo 2 (modulo WinGet.Client) no valio: $($_.Exception.Message)" }
    if (Get-Command winget -ErrorAction SilentlyContinue) { Ok 'winget listo.'; return }

    try {
        $tmp = Join-Path $env:TEMP 'winget-setup'
        New-Item -ItemType Directory -Force $tmp | Out-Null
        $ProgressPreference = 'SilentlyContinue'
        $vc = Join-Path $tmp 'VCLibs.appx'
        $bundle = Join-Path $tmp 'winget.msixbundle'
        Invoke-WebRequest 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' -OutFile $vc -UseBasicParsing
        Invoke-WebRequest 'https://aka.ms/getwinget' -OutFile $bundle -UseBasicParsing
        Add-AppxPackage -Path $vc -ErrorAction SilentlyContinue
        Add-AppxPackage -Path $bundle -ErrorAction Stop
        Update-Path
    } catch { Write-Host "  metodo 3 (msixbundle) no valio: $($_.Exception.Message)" }
    if (Get-Command winget -ErrorAction SilentlyContinue) { Ok 'winget listo.'; return }

    throw "No he podido instalar winget. Instala 'App Installer' desde Microsoft Store (o https://aka.ms/getwinget), cierra y abre PowerShell y reintenta."
}

# ---------------------------------------------------------------- driver de Apple (usbmuxd)
function Test-AppleServicio { [bool](Get-Service -Name $script:Servicio -ErrorAction SilentlyContinue) }

function Start-AppleServicio {
    $s = Get-Service -Name $script:Servicio -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Running') {
        try { Start-Service -InputObject $s -ErrorAction Stop } catch { Aviso "  no pude arrancar '$($script:Servicio)': $($_.Exception.Message)" }
    }
}

function Install-DriverApple {
    if (Test-AppleServicio) {
        Ok 'Driver de Apple ya instalado.'
        Start-AppleServicio
        return
    }
    Write-Host 'iloader necesita el servicio USB de Apple (viene con iTunes / Apple Mobile Device Support).'
    $hayWinget = $true
    try { Initialize-Winget } catch { $hayWinget = $false; Aviso $_.Exception.Message }

    $comun = @('--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    $metodos = @(
        @{ Nombre = 'winget: iTunes (recomendado por iloader)'; Winget = $true
           Accion = { Invoke-Winget (@('install', '--id', 'Apple.iTunes', '-e') + $comun) } },
        @{ Nombre = 'winget: Apple Mobile Device Support'; Winget = $true
           Accion = { Invoke-Winget (@('install', '--id', 'Apple.AppleMobileDeviceSupport', '-e') + $comun) } },
        @{ Nombre = 'descarga directa de iTunes desde apple.com'; Winget = $false
           Accion = {
               $exe = Join-Path $env:TEMP 'iTunes64Setup.exe'
               Get-Archivo 'https://www.apple.com/itunes/download/win64' $exe 'EXE'
               $p = Start-Process $exe -ArgumentList '/quiet', '/norestart' -Wait -PassThru
               Remove-Item $exe -Force -ErrorAction SilentlyContinue
               $p.ExitCode } },
        @{ Nombre = 'winget: Apple Devices (Microsoft Store)'; Winget = $true
           Accion = { Invoke-Winget @('install', '--id', '9NP83LWLPZ9K', '-e', '--source', 'msstore', '--silent', '--accept-package-agreements', '--accept-source-agreements') } }
    )
    foreach ($m in $metodos) {
        if ($m.Winget -and -not $hayWinget) { continue }
        Write-Host "Probando: $($m.Nombre)..." -ForegroundColor Cyan
        try { [void](& $m.Accion) } catch { Aviso "  no valio: $($_.Exception.Message)" }
        Start-Sleep 4
        if (Test-AppleServicio) {
            Start-AppleServicio
            Set-Estado 'apple' $true
            Ok 'Driver de Apple instalado.'
            return
        }
    }
    throw "No he podido instalar el driver de Apple. Instala iTunes a mano desde https://www.apple.com/itunes/download/win64 (no la version de la Store), reinicia el PC y vuelve a lanzar el script."
}

# ---------------------------------------------------------------- iloader
function Find-Iloader {
    foreach ($d in @("$env:ProgramFiles\iloader", "${env:ProgramFiles(x86)}\iloader", "$env:LOCALAPPDATA\iloader", "$env:LOCALAPPDATA\Programs\iloader")) {
        $p = Join-Path $d 'iloader.exe'
        if (Test-Path $p -PathType Leaf) { return Get-Item $p }
    }
    $apps = Get-ItemProperty $script:Claves -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^iloader' }
    foreach ($a in $apps) {
        $icono = ([string]$a.DisplayIcon) -replace ',-?\d+$', '' -replace '"', ''
        if ($icono -match 'iloader\.exe$' -and (Test-Path $icono -PathType Leaf)) { return Get-Item $icono }
        if ($a.InstallLocation) {
            $p = Join-Path $a.InstallLocation 'iloader.exe'
            if (Test-Path $p -PathType Leaf) { return Get-Item $p }
        }
    }
    $menus = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    foreach ($lnk in (Get-ChildItem $menus -Filter 'iloader*.lnk' -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $t = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk.FullName).TargetPath
            if ($t -and (Test-Path $t -PathType Leaf)) { return Get-Item $t }
        } catch { }
    }
    return $null
}

function Install-Iloader {
    $exe = Find-Iloader
    if ($exe) { Ok "iloader ya instalado: $($exe.FullName)"; return $exe }

    $msi = Join-Path $env:TEMP 'iloader-windows-x64.msi'
    $directa = 'https://github.com/nab138/iloader/releases/latest/download/iloader-windows-x64.msi'
    Write-Host 'Descargando la ultima version de iloader (release oficial de GitHub)...'
    try { Get-Archivo $directa $msi 'MSI' }
    catch {
        Aviso "Descarga directa fallida; pruebo con la API de GitHub... ($($_.Exception.Message))"
        $rel = Invoke-RestMethod 'https://api.github.com/repos/nab138/iloader/releases/latest' -Headers @{ 'User-Agent' = 'ps' }
        $asset = $rel.assets | Where-Object name -eq 'iloader-windows-x64.msi' | Select-Object -First 1
        if (-not $asset) { throw "No encuentro iloader-windows-x64.msi en la release $($rel.tag_name)." }
        Get-Archivo $asset.browser_download_url $msi 'MSI'
    }
    Write-Host "SHA256: $((Get-FileHash $msi -Algorithm SHA256).Hash)"

    $log = Join-Path $script:Dir 'iloader-msi.log'
    New-Item -ItemType Directory -Force $script:Dir | Out-Null
    Write-Host 'Instalando iloader...'
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart /l*v `"$log`"" -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { throw "msiexec devolvio el codigo $($p.ExitCode). Revisa el log: $log" }

    $exe = Find-Iloader
    if (-not $exe) { throw "iloader se instalo pero no encuentro iloader.exe. Abrelo desde el menu Inicio." }
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    Set-Estado 'iloader' $true
    Ok "iloader instalado: $($exe.FullName)"
    return $exe
}

function Start-Iloader($exe) {
    if (-not $exe) { Aviso 'Abre iloader desde el menu Inicio.'; return }
    # explorer.exe lo lanza sin privilegios de administrador (la GUI no los necesita).
    try { Start-Process explorer.exe -ArgumentList "`"$($exe.FullName)`"" } catch { Start-Process $exe.FullName }
}

# ---------------------------------------------------------------- dispositivo
function Test-Dispositivo {
    [bool](Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match 'VID_05AC' -and
        ($_.InstanceId -match 'PID_12[0-9A-F]{2}' -or $_.FriendlyName -match 'iPad|iPhone|iPod|Apple Mobile Device')
    })
}

function Wait-Dispositivo {
    Write-Host "Conecta el iPhone/iPad con cable USB, desbloqueado, y toca 'Confiar' si lo pide."
    Start-AppleServicio
    $visto = $false
    for ($i = 0; $i -lt 60 -and -not $visto; $i++) {
        $visto = Test-Dispositivo
        if (-not $visto) { Start-Sleep 2 }
    }
    if ($visto) { Ok 'Dispositivo detectado.' }
    else { Aviso 'No lo detecto en 2 min. Prueba otro cable/puerto USB. Sigo igualmente: iloader tambien puede verlo por Wi-Fi.' }
}

# ---------------------------------------------------------------- guias
function Show-Pasos($lista) {
    for ($n = 0; $n -lt $lista.Count; $n++) {
        Write-Host "`nPaso $($n + 1)/$($lista.Count): $($lista[$n])" -ForegroundColor Yellow
        Pausa 'Cuando lo hayas hecho, pulsa Enter'
    }
}

function Get-VersionIos {
    $v = Read-Host 'Version de iOS/iPadOS del dispositivo (solo el numero, p.ej. 17 o 26; Enter = 18 o superior)'
    if ($v -match '^\d+') { return [int]$Matches[0] }
    return 18
}

function Show-GuiaPrevia {
    Write-Host @'
Antes de empezar, en el iPhone/iPad:
  - Debe tener codigo de acceso (obligatorio) y estar conectado a una red Wi-Fi.
  - Instala LocalDevVPN desde la App Store: https://apps.apple.com/app/localdevvpn/id6755608044
  - Abre LocalDevVPN y pulsa 'Connect' (permite la configuracion VPN si lo pide).
  - Ten a mano tu Apple ID (con verificacion en dos pasos). No hace falta que sea el del dispositivo.
'@
    Pausa 'Cuando lo tengas, pulsa Enter'
}

function Show-GuiaInstalacion([int]$Ios) {
    Write-Host "`n--- En iloader (en el PC) ---" -ForegroundColor Cyan
    Show-Pasos @(
        "Inicia sesion con tu Apple ID (correo y contrasena; mayusculas importan) y escribe el codigo de 6 digitos que te llega al dispositivo.",
        "Selecciona tu dispositivo en la lista y toca 'Confiar' en el iPhone/iPad (con tu codigo).",
        "En 'Installers' pulsa 'SideStore (Stable)'. Espera a ver 'SideStore Installed!' (si avisa de 'Maximum certificates reached', deja que revoque el certificado antiguo)."
    )

    Write-Host "`n--- En el iPhone/iPad ---" -ForegroundColor Cyan
    $pasos = @("Ajustes > General > 'VPN y gestion de dispositivos' > en 'App de desarrollador' pulsa tu Apple ID.")
    if ($Ios -ge 18) {
        $pasos += "Pulsa 'Confiar en [tu Apple ID]' y luego 'Permitir y reiniciar' (te pide el codigo)."
    } else {
        $pasos += "Pulsa 'Confiar en [tu Apple ID]' y confirma con 'Confiar'."
    }
    if ($Ios -ge 16) {
        $pasos += "Ajustes > 'Privacidad y seguridad' > baja hasta el final > activa 'Modo desarrollador'. El dispositivo se reinicia; al volver, desbloquea y confirma 'Activar'."
    }
    $pasos += "Abre LocalDevVPN y pulsa 'Connect' (debe estar conectada cada vez que instales/refresques apps)."
    $pasos += "Abre SideStore e inicia sesion con el mismo Apple ID que usaste en iloader."
    $pasos += "Ve a 'My Apps' y toca el contador '7 DAYS' junto a SideStore para refrescarlo y terminar la configuracion. Si pregunta por revocar/crear certificado, responde 'Yes' / 'Refresh Now'."
    Show-Pasos $pasos
}

function Show-GuiaPairing {
    Write-Host "`n--- En iloader ---" -ForegroundColor Cyan
    Show-Pasos @(
        "Pulsa 'Delete Stored Pairing' (descarta el pairing viejo).",
        "Pulsa tu dispositivo en la lista y toca 'Confiar' en el (codigo).",
        "Pulsa 'Manage Pairing File'.",
        "Junto a 'SideStore' (y LiveContainer si sale) pulsa 'Place'. Debe salir en verde 'Pairing file placed successfully!'."
    )
    Write-Host "`nAbre SideStore en el dispositivo (con LocalDevVPN conectada) y prueba un refresco." -ForegroundColor Green
}

# ---------------------------------------------------------------- limpieza
function Remove-Programa($patron, $nombre) {
    $apps = Get-ItemProperty $script:Claves -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $patron }
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
            Aviso '  sin desinstalador; quitalo a mano desde Configuracion > Aplicaciones.'
        }
    }
}

function Invoke-Limpieza {
    Paso 'Limpieza'
    Write-Host "Si guardaste tu Apple ID en iloader, abre iloader y pulsa 'Sign Out' antes de seguir."
    if (-not (Confirmar 'Desinstalar ahora?' $true)) { return }

    $quitarApple = $true
    if (-not (Get-Estado 'apple') -and (Test-AppleServicio)) {
        Aviso 'Los componentes de Apple ya estaban en el PC antes de este script (no los instale yo).'
        $quitarApple = Confirmar 'Quitarlos tambien (iTunes, driver USB...)?' $false
    }

    Get-Process iloader -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Programa '^iloader' 'iloader'
    foreach ($d in "$env:LOCALAPPDATA\iloader", "$env:APPDATA\me.nabdev.iloader", "$env:LOCALAPPDATA\me.nabdev.iloader", "$env:APPDATA\iloader") {
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($quitarApple) {
        # Orden importante: iTunes primero, luego los componentes de los que depende.
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            [void](Invoke-Winget @('uninstall', '--id', 'Apple.iTunes', '-e', '--silent'))
        }
        Get-AppxPackage -Name '*AppleDevices*' -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue
        Remove-Programa '^iTunes$' 'iTunes'
        Remove-Programa '^Apple Mobile Device Support' 'Apple Mobile Device Support (driver)'
        Remove-Programa '^Apple Application Support' 'Apple Application Support'
        Remove-Programa '^Apple Software Update' 'Apple Software Update'
        Remove-Programa '^Bonjour' 'Bonjour'
    }

    Remove-Item (Join-Path $env:TEMP 'iloader-windows-x64.msi') -Force -ErrorAction SilentlyContinue
    Remove-Item $script:Estado -Force -ErrorAction SilentlyContinue
    Ok "`nHecho. El script se queda para relanzarlo cuando lo necesites (p.ej. -Modo Pairing)."
    Aviso 'Si algun driver sigue apareciendo, reinicia el PC.'
}

# ---------------------------------------------------------------- flujos
function Invoke-Instalar {
    Paso '1/6 Comprobaciones'
    Test-Sistema
    Test-Red

    Paso '2/6 Preparar el iPhone/iPad'
    Show-GuiaPrevia
    $ios = Get-VersionIos

    Paso '3/6 Driver USB de Apple'
    Install-DriverApple

    Paso '4/6 iloader'
    $exe = Install-Iloader

    Paso '5/6 Conectar el dispositivo'
    Wait-Dispositivo

    Paso '6/6 Instalar SideStore'
    Start-Iloader $exe
    Show-GuiaInstalacion $ios

    Write-Host "`nSideStore queda instalado y con el pairing file colocado (iloader lo hace solo)." -ForegroundColor Green
    Write-Host "Si SideStore pide el pairing file mas adelante, relanza el script con: -Modo Pairing"
    if (Confirmar "`nFunciona todo? (s = si, limpiar PC: desinstalar iloader y drivers de Apple / n = dejarlo instalado)" $false) {
        Invoke-Limpieza
    } else {
        Aviso 'Se deja todo instalado. Si algo falla: reinicia dispositivo y PC y revisa la seccion "Si sigue fallando" del README.'
    }
}

function Invoke-Pairing {
    Paso '1/4 Driver USB de Apple'
    Install-DriverApple
    Paso '2/4 iloader'
    $exe = Install-Iloader
    Paso '3/4 Conectar el dispositivo'
    Wait-Dispositivo
    Paso '4/4 Regenerar pairing file'
    Start-Iloader $exe
    Show-GuiaPairing
    if (Confirmar "`nFunciona todo? (s = limpiar PC / n = dejarlo instalado)" $false) { Invoke-Limpieza }
}

function Select-Modo {
    Write-Host @'

  SideStore Installer
  -------------------
  1) Instalar SideStore (completo)        [recomendado]
  2) Solo regenerar el pairing file       (SideStore ya instalado)
  3) Limpiar: desinstalar iloader y drivers de Apple
  4) Salir
'@
    do { $r = Read-Host 'Elige 1-4' } until ($r -match '^[1-4]$')
    switch ($r) { '1' { 'Instalar' } '2' { 'Pairing' } '3' { 'Limpiar' } '4' { 'Salir' } }
}

function Invoke-Main {
    # Necesita administrador (instala drivers/MSI) y PowerShell de 64 bits (lee bien el registro).
    $esAdmin = Test-Admin
    $es32en64 = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
    if (-not $esAdmin -or $es32en64) {
        if (-not $PSCommandPath) {
            throw 'Abre PowerShell como administrador (64 bits) y vuelve a pegar el script, o guardalo como .ps1 y ejecutalo.'
        }
        $host64 = if ($es32en64) { "$env:windir\sysnative\WindowsPowerShell\v1.0\powershell.exe" } else { (Get-Process -Id $PID).Path }
        $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        if ($Modo) { $args2 += @('-Modo', $Modo) }
        Write-Host 'Reabriendo como administrador (acepta el aviso de Windows)...' -ForegroundColor Yellow
        if ($esAdmin) { Start-Process $host64 -ArgumentList $args2 } else { Start-Process $host64 -ArgumentList $args2 -Verb RunAs }
        return
    }

    $logDir = Join-Path $script:Dir 'logs'
    New-Item -ItemType Directory -Force $logDir | Out-Null
    $log = Join-Path $logDir ("instalador-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    $transcribiendo = $false
    try { Start-Transcript -Path $log -Force | Out-Null; $transcribiendo = $true } catch { }

    try {
        $m = if ($Modo) { $Modo } else { Select-Modo }
        switch ($m) {
            'Instalar' { Invoke-Instalar }
            'Pairing'  { Invoke-Pairing }
            'Limpiar'  { Invoke-Limpieza }
            'Salir'    { return }
        }
        Ok "`nTerminado. Log: $log"
    } catch {
        Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  (linea $($_.InvocationInfo.ScriptLineNumber)) Log completo: $log" -ForegroundColor DarkGray
        Aviso 'Puedes relanzar el script: los pasos ya hechos se detectan y se saltan.'
    } finally {
        if ($transcribiendo) { try { Stop-Transcript | Out-Null } catch { } }
        [void](Read-Host "`nEnter para cerrar")
    }
}

# Al hacer dot-source (. .\script.ps1) solo se cargan las funciones.
if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }
