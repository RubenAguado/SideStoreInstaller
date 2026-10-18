<#
.SYNOPSIS
    Instalador todo-en-uno de SideStore para Windows 10/11 (x64) usando iloader.

.DESCRIPTION
    Modo Instalar : prepara el PC (driver USB de Apple + iloader), espera al iPhone/iPad y te guia
                    hasta tener SideStore funcionando. Es el modo por defecto.
    Modo Pairing  : solo regenera el pairing file (iOS actualizado, SideStore lo pide otra vez).
    Modo Limpiar  : desinstala iloader y los componentes de Apple.
    Modo Diagnostico : revisa el PC, pregunta que te pasa y explica como arreglarlo (guarda un informe).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\sidestore-installer.ps1
    powershell -ExecutionPolicy Bypass -File .\sidestore-installer.ps1 -Modo Pairing
#>
[CmdletBinding()]
param(
    [ValidateSet('Instalar', 'Pairing', 'Limpiar', 'Diagnostico')]
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
        'https://raw.githubusercontent.com/SideStore/anisette-servers/main/servers.json',
        'https://www.apple.com/itunes/download/win64'
    )
    $res = foreach ($u in $urls) { Test-Url $u }
    Write-Host (($res | Format-Table Url, IP, DNS, TCP443, HTTP -AutoSize | Out-String -Width 200).TrimEnd())
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

# Lista oficial: https://github.com/SideStore/anisette-servers/blob/main/servers.json
function Get-ServidoresAnisette {
    try {
        $r = Invoke-WebRequest 'https://raw.githubusercontent.com/SideStore/anisette-servers/main/servers.json' -UseBasicParsing -TimeoutSec 20
        $lista = @(($r.Content | ConvertFrom-Json).servers | Where-Object { $_.address })
        if ($lista.Count -gt 0) { return $lista }
    } catch { Aviso "No pude leer la lista oficial de servidores anisette ($($_.Exception.Message)); uso una lista minima." }
    return @(
        [pscustomobject]@{ name = 'SideStore';                address = 'https://ani.sidestore.io' },
        [pscustomobject]@{ name = 'SideStore (Windows ADI)';  address = 'https://win.ani.sidestore.io' },
        [pscustomobject]@{ name = 'jkcoxson (Windows ADI)';   address = 'https://ani.jkcoxson.com' },
        [pscustomobject]@{ name = 'StikStore';                address = 'https://ani2.stikstore.app' }
    )
}

# Consulta /v3/client_info de cada servidor; devuelve una fila por servidor (sin imprimir nada).
function Get-EstadoAnisette {
    $servidores = @(Get-ServidoresAnisette)
    Add-Type -AssemblyName System.Net.Http
    $hc = New-Object System.Net.Http.HttpClient
    $hc.Timeout = [TimeSpan]::FromSeconds(10)
    $items = foreach ($s in $servidores) {
        $url = ([string]$s.address).TrimEnd('/') + '/v3/client_info'
        [pscustomobject]@{ Nombre = [string]$s.name; Servidor = [string]$s.address; Estado = 'FALLA'; Tipo = ''; Info = $null; Tarea = $hc.GetAsync($url) }
    }
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($items | ForEach-Object { $_.Tarea }), 15000) } catch { }
    foreach ($i in $items) {
        $t = $i.Tarea
        if ($t.Status -eq 'RanToCompletion') {
            $codigo = [int]$t.Result.StatusCode
            if ($codigo -eq 200) {
                $i.Estado = 'respuesta rara'
                try {
                    $o = $t.Result.Content.ReadAsStringAsync().Result | ConvertFrom-Json
                    if ($o.client_info) {
                        $i.Estado = 'OK'
                        $i.Info = $o
                        $i.Tipo = if ($o.client_info -match 'Windows') { 'Windows' } elseif ($o.client_info -match 'Mac') { 'Mac' } else { 'otro' }
                    }
                } catch { }
            } else { $i.Estado = "HTTP $codigo" }
        } elseif ($t.Status -eq 'Faulted') { $i.Estado = 'FALLA (DNS/conexion)' }
        else { $i.Estado = 'TIMEOUT' }
    }
    $hc.Dispose()
    $win = @($items | Where-Object { $_.Estado -eq 'OK' -and $_.Tipo -eq 'Windows' }) | Select-Object -First 1
    if ($win) {
        $script:ClientInfoWin = [string]$win.Info.client_info
        $script:UserAgentWin = [string]$win.Info.user_agent
    }
    return @($items)
}

function Test-Anisette {
    Write-Host "`nServidores anisette (lista oficial de SideStore), prueba de /v3/client_info:" -ForegroundColor Cyan
    $items = @(Get-EstadoAnisette)
    Write-Host (($items | Format-Table Nombre, Servidor, Estado, Tipo -AutoSize | Out-String -Width 200).TrimEnd())

    $vivos = @($items | Where-Object { $_.Estado -eq 'OK' })
    $win = $vivos | Where-Object { $_.Tipo -eq 'Windows' } | Select-Object -First 1
    if ($vivos.Count -eq 0) {
        Aviso 'Ningun servidor anisette responde: revisa tu conexion, DNS o VPN. Sin ellos no se puede iniciar sesion con el Apple ID.'
    } else {
        Ok "$($vivos.Count) de $($items.Count) servidores anisette responden."
        if (-not $win) { Aviso 'Ninguno de tipo Windows responde ahora mismo; son los que Apple acepta tras sus cambios de octubre.' }
        Write-Host 'iloader (2.3.8 o superior) elige el servidor solo desde su propia lista; los servidores personalizados ya no funcionan.'
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
        # El servicio tarda unos segundos en registrarse tras instalar: esperar antes de dar el metodo por fallido.
        for ($i = 0; $i -lt 15 -and -not (Test-AppleServicio); $i++) { Start-Sleep 2 }
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

function ConvertTo-Version([string]$s) {
    if ($s -match '(\d+(\.\d+){1,3})') { try { return [version]$Matches[1] } catch { } }
    return $null
}

# Etiqueta de la ultima release (p.ej. v2.3.10) o $null si no se pudo consultar.
function Get-IloaderUltima(
    [string]$Api = 'https://api.github.com/repos/nab138/iloader/releases/latest',
    [string]$Web = 'https://github.com/nab138/iloader/releases/latest') {
    try {
        $rel = Invoke-RestMethod $Api -Headers @{ 'User-Agent' = 'ps' } -TimeoutSec 20
        if ($rel.tag_name) { return [string]$rel.tag_name }
    } catch { }
    # Sin API (limite de peticiones): la pagina /releases/latest redirige a /releases/tag/<version>.
    try {
        [void](Invoke-WebRequest $Web -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop)
    } catch {
        try {
            $h = $_.Exception.Response.Headers
            $loc = [string]$h.Location              # PowerShell 7 (HttpResponseHeaders)
            if (-not $loc) { $loc = [string]$h['Location'] }   # Windows PowerShell 5.1 (WebHeaderCollection)
            if ($loc -match '/tag/(v?[\d.]+)') { return $Matches[1] }
        } catch { }
    }
    return $null
}

function Get-IloaderVersion {
    $a = Get-ItemProperty $script:Claves -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^iloader' } | Select-Object -First 1
    if ($a) { return ConvertTo-Version ([string]$a.DisplayVersion) }
    return $null
}

function Install-Iloader {
    $exe = Find-Iloader
    $ultima = ConvertTo-Version (Get-IloaderUltima)
    if ($exe) {
        $inst = Get-IloaderVersion
        if (-not $ultima) { Ok "iloader ya instalado: $($exe.FullName) (no pude comprobar si hay version nueva)"; return $exe }
        if ($inst -and $inst -ge $ultima) { Ok "iloader $inst ya esta al dia."; return $exe }
        $txt = if ($inst) { "$inst" } else { 'desconocida' }
        Aviso "El iloader instalado (version $txt) esta desactualizado (ultima: $ultima). Las versiones antiguas fallan al iniciar sesion (-80045 / 503). Actualizando..."
        Get-Process iloader -ErrorAction SilentlyContinue | Stop-Process -Force
    }

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
    if ($p.ExitCode -eq 1638) {
        Aviso 'Hay otra version instalada que no se actualiza en caliente; la desinstalo y reinstalo.'
        Remove-Programa '^iloader' 'iloader'
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart /l*v `"$log`"" -Wait -PassThru
    }
    if ($p.ExitCode -notin 0, 3010) { throw "msiexec devolvio el codigo $($p.ExitCode). Revisa el log: $log" }

    $exe = Find-Iloader
    if (-not $exe) { throw "iloader se instalo pero no encuentro iloader.exe. Abrelo desde el menu Inicio." }
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    Set-Estado 'iloader' $true
    $v = Get-IloaderVersion
    Ok "iloader $v instalado: $($exe.FullName)"
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
function Show-AyudaErrores {
    Write-Host @'

--- AYUDA CON ERRORES ---
Error -80045 "This action cannot be completed at this time":
  Es Apple rechazando el inicio de sesion (desde el 12-13 oct 2026). No lo arregla el PC ni este
  script: depende de la cuenta y de la red. Con iloader 2.3.10 ya esta lo que se puede hacer.
  IMPORTANTE: NO reintentes en bucle. Apple esta bloqueando cuentas por reintentos (error -20209).
  Si sale -20209 la cuenta esta bloqueada: se desbloquea en https://iforgot.apple.com
  Haz como mucho 1 o 2 intentos por configuracion, en este orden:
  1. iloader > 'Restablecer estado de Anisette' (Reset Anisette State), elige un servidor de la
     lista (prueba UNA vez uno Windows y UNA vez uno Mac) e inicia sesion.
  2. Con 2FA, usa el codigo de un dispositivo de confianza (segun iloader, el SMS falla de momento).
  3. Cambia de red (datos del movil compartidos) y/o usa un Apple ID secundario: es lo que mas
     funciona cuando una cuenta o IP concreta sigue rechazada.
  4. Si falla en SideStore (iPhone) pero no en iloader:
     a) Instala la version Nightly (iloader > Installers > 'SideStore (Nightly)'); la Stable no trae
        la correccion del 2FA (SideStore issues 1647 y 1658).
     b) Ajustes > User Customizations > desactiva 'On-Device Anisette'.
     c) Anisette Client Configuration (pestana Interactive) > pon el client info y el user agent de
        abajo > 'Save Overrides' > cierra SideStore del todo y reabrelo > inicia sesion (una vez).
        Fuente: SideStore issue 1665. Si da HTTP 404, alternativa: en 'Anisette Servers' elige
        'Jkcoxson' (mac-ani.jkcoxson.com) con el client info por defecto (Windows con Windows, Mac
        con Mac). El codigo de 6 digitos sale en el iPhone una sola vez: anotalo.
'@
    if ($script:ClientInfoWin) {
        Write-Host "     Client info : $($script:ClientInfoWin)"
        Write-Host "     User agent  : $($script:UserAgentWin)"
    }
    Write-Host @'
Otros errores:
  - 'usbmuxd' / no ve el dispositivo: otro cable o puerto USB; si sigue, modo Limpiar y volver a Instalar.
  - 'UDID' en SideStore: relanza el script con -Modo Pairing.
'@
}

function Show-Pasos($lista) {
    for ($n = 0; $n -lt $lista.Count; $n++) {
        Write-Host "`nPaso $($n + 1)/$($lista.Count): $($lista[$n])" -ForegroundColor Yellow
        do {
            $r = Read-Host 'Pulsa Enter cuando lo hayas hecho (escribe e si te sale un error)'
            $fallo = ($r -match '^[eE]')
            if ($fallo) { Show-AyudaErrores }
        } while ($fallo)
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

# ---------------------------------------------------------------- diagnostico
# Hallazgos de la revision automatica: Estado = OK | AVISO | ERROR | INFO
function Add-Hallazgo([string]$Estado, [string]$Titulo, [string]$Detalle = '', [string]$Accion = '') {
    [void]$script:Hallazgos.Add([pscustomobject]@{ Estado = $Estado; Titulo = $Titulo; Detalle = $Detalle; Accion = $Accion })
    $marca = switch ($Estado) { 'OK' { '[ OK ]' } 'AVISO' { '[ !! ]' } 'ERROR' { '[ XX ]' } default { '[ -- ]' } }
    $color = switch ($Estado) { 'OK' { 'Green' } 'AVISO' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    Write-Host "$marca $Titulo" -ForegroundColor $color
    if ($Detalle) { Write-Host "       $Detalle" }
}

function Invoke-Comprobacion([string]$Nombre, [scriptblock]$Bloque) {
    try { & $Bloque } catch { Add-Hallazgo 'INFO' "No he podido comprobar: $Nombre" $_.Exception.Message }
}

# Minutos de diferencia entre el reloj del PC y la hora que dicen servidores de Internet ($null si no se pudo medir).
function Get-DesfaseHora([string[]]$Fuentes = @('https://www.apple.com', 'https://www.microsoft.com', 'https://github.com')) {
    foreach ($u in $Fuentes) {
        try {
            $r = Invoke-WebRequest $u -UseBasicParsing -Method Head -TimeoutSec 15
            $txt = [string]$r.Headers['Date']
            if (-not $txt) { continue }
            $remota = [DateTimeOffset]::Parse($txt, [Globalization.CultureInfo]::InvariantCulture)
            return [math]::Abs(([DateTimeOffset]::UtcNow - $remota).TotalMinutes)
        } catch { }
    }
    return $null
}

function Sync-HoraPc {
    $antes = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Start-Service w32time -ErrorAction SilentlyContinue
        $o = (& w32tm /resync /force 2>&1 | Out-String).Trim()
        if ($o) { Write-Host $o }
    } catch { Aviso "No pude sincronizar la hora: $($_.Exception.Message)" }
    finally { $ErrorActionPreference = $antes }
}

# Errores conocidos que iloader deja escritos en su registro (solo se cuentan, nunca se copia el texto).
function Get-PatronesIloader {
    @(
        @{ Id = '80045';    Texto = 'error -80045 (Apple rechaza el inicio de sesion)';    Regex = '-80045|cannot be completed at this time' },
        @{ Id = '20209';    Texto = 'error -20209 (cuenta de Apple bloqueada)';             Regex = '-20209|locked for security' },
        @{ Id = '503';      Texto = 'errores 503/429 (servidor saturado o limitando)';      Regex = 'Temporarily Unavailable|HTTP[^\r\n]{0,12}503|503 Service|Too Many Requests|HTTP[^\r\n]{0,12}429' },
        @{ Id = 'password'; Texto = 'usuario o contrasena rechazados';                      Regex = '-20101|Incorrect Apple ID' },
        @{ Id = '2fa';      Texto = 'error -22411 (verificacion en dos pasos)';             Regex = '-22411' },
        @{ Id = 'udid';     Texto = 'problemas con el pairing file / UDID';                 Regex = 'InvalidPairing|rppairing UDID|determine this device' },
        @{ Id = 'usb';      Texto = 'iloader no pudo hablar con el servicio USB (usbmuxd)'; Regex = 'usbmuxd' },
        @{ Id = 'limite';   Texto = 'limite de apps / App IDs / certificados';              Regex = 'Maximum certificates|not enough app ?ids|cannot register more than 10' }
    )
}

function Get-PistasIloader([string]$Dir = (Join-Path $env:APPDATA 'me.nabdev.iloader\logs'), [int]$Dias = 7) {
    $res = @()
    if (-not (Test-Path $Dir)) { return $res }
    $texto = ''
    $archivos = Get-ChildItem $Dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-$Dias) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 3
    foreach ($f in $archivos) {
        try { $texto += ((Get-Content $f.FullName -Tail 3000 -ErrorAction Stop) -join "`n") + "`n" } catch { }
    }
    if (-not $texto) { return $res }
    foreach ($p in (Get-PatronesIloader)) {
        $n = ([regex]::Matches($texto, $p.Regex, 'IgnoreCase')).Count
        if ($n -gt 0) { $res += [pscustomobject]@{ Id = $p.Id; Texto = $p.Texto; Veces = $n } }
    }
    return $res
}

# ---- comprobaciones automaticas
function Test-DiagSistema {
    $v = [Environment]::OSVersion.Version
    $arm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64')
    if (-not [Environment]::Is64BitOperatingSystem) {
        Add-Hallazgo 'ERROR' 'Tu Windows es de 32 bits' 'iloader solo funciona en Windows de 64 bits.'
    } elseif ($arm -and $v.Build -lt 22000) {
        Add-Hallazgo 'ERROR' 'Windows 10 en ARM no esta soportado' 'Usa otro PC o Windows 11.'
    } else {
        Add-Hallazgo 'OK' "Windows compatible (version $v, 64 bits)"
    }
}

function Test-DiagHora {
    $min = Get-DesfaseHora
    if ($null -eq $min) {
        Add-Hallazgo 'INFO' 'No he podido comprobar la hora del PC' 'Sin conexion a los servidores de hora.'
    } elseif ($min -gt 3) {
        Add-Hallazgo 'AVISO' ("La hora de tu PC esta desfasada unos {0:N0} minutos" -f $min) 'Apple rechaza los inicios de sesion si la hora no es correcta.' 'Sincroniza la hora de Windows.'
        $script:Arreglos += 'hora'
    } else {
        Add-Hallazgo 'OK' 'La hora de tu PC es correcta'
    }
}

function Test-DiagRed {
    $destinos = @(
        @{ Nombre = 'GitHub (descarga de iloader)'; Url = 'https://github.com/nab138/iloader' },
        @{ Nombre = 'Servidor de login de Apple';   Url = 'https://gsa.apple.com' },
        @{ Nombre = 'Descarga de Apple (iTunes)';   Url = 'https://www.apple.com/itunes/download/win64' },
        @{ Nombre = 'Lista de servidores anisette'; Url = 'https://raw.githubusercontent.com/SideStore/anisette-servers/main/servers.json' },
        @{ Nombre = 'Web de SideStore';             Url = 'https://sidestore.io' }
    )
    foreach ($d in $destinos) {
        $r = Test-Url $d.Url
        if ($r.DNS -eq 'ok' -and $r.TCP443 -eq 'ok') {
            Add-Hallazgo 'OK' "Conexion con: $($d.Nombre)"
        } else {
            $why = if ($r.DNS -ne 'ok') { 'El nombre no se resuelve: DNS mal o bloqueado (Pi-hole, DNS del ISP).' }
                   else { 'Resuelve pero no conecta: bloqueo del ISP/firewall o servidor caido.' }
            Add-Hallazgo 'ERROR' "Sin conexion con: $($d.Nombre)" $why 'Prueba otro DNS (1.1.1.1 u 8.8.8.8), otra red o una VPN.'
        }
    }
}

function Test-DiagDriver {
    $s = Get-Service -Name $script:Servicio -ErrorAction SilentlyContinue
    if (-not $s) {
        Add-Hallazgo 'ERROR' 'Falta el driver USB de Apple' 'Sin el, el PC no puede ver el iPhone/iPad.' 'Ejecuta el modo Instalar (lo instala).'
        $script:Arreglos += 'driver'
        return
    }
    if ($s.Status -ne 'Running') {
        Add-Hallazgo 'AVISO' 'El servicio USB de Apple esta parado' 'iloader no vera el dispositivo.' 'Arrancar el servicio.'
        $script:Arreglos += 'servicio'
    } else {
        Add-Hallazgo 'OK' 'Driver USB de Apple instalado y en marcha'
    }
    if (Test-Dispositivo) { Add-Hallazgo 'OK' 'iPhone/iPad detectado por USB' }
    else { Add-Hallazgo 'INFO' 'No veo ningun iPhone/iPad por USB ahora mismo' 'Si tu problema es en el PC: cable de datos, desbloqueado y toca Confiar.' }
}

function Test-DiagIloader {
    $exe = Find-Iloader
    if (-not $exe) {
        Add-Hallazgo 'INFO' 'iloader no esta instalado en este PC' 'Solo hace falta para instalar SideStore o regenerar el pairing file.'
        return
    }
    $inst = Get-IloaderVersion
    $ult = ConvertTo-Version (Get-IloaderUltima)
    $script:IloaderVersion = $inst
    if (-not $inst) {
        Add-Hallazgo 'INFO' 'iloader instalado (no pude leer su version)'
    } elseif ($inst -lt [version]'2.3.8') {
        Add-Hallazgo 'ERROR' "iloader $inst es demasiado antiguo" 'Las versiones anteriores a la 2.3.8 no pueden iniciar sesion con Apple (-80045 / 503).' 'Actualizar iloader.'
        $script:Arreglos += 'iloader'
    } elseif ($ult -and $inst -lt $ult) {
        Add-Hallazgo 'AVISO' "iloader $inst no es la ultima version ($ult)" 'Apple cambia cosas cada pocos dias y las versiones nuevas lo siguen.' 'Actualizar iloader.'
        $script:Arreglos += 'iloader'
    } else {
        Add-Hallazgo 'OK' "iloader $inst al dia"
    }
}

function Test-DiagAnisette {
    $items = @(Get-EstadoAnisette)
    $script:EstadoAnisette = $items
    $vivos = @($items | Where-Object { $_.Estado -eq 'OK' })
    $win = @($vivos | Where-Object { $_.Tipo -eq 'Windows' })
    if ($vivos.Count -eq 0) {
        Add-Hallazgo 'ERROR' 'Ningun servidor anisette responde' 'Sin ellos no se puede iniciar sesion con el Apple ID.' 'Revisa tu conexion, DNS o VPN.'
    } elseif ($win.Count -eq 0) {
        Add-Hallazgo 'AVISO' "Responden $($vivos.Count) de $($items.Count) servidores anisette, pero ninguno de tipo Windows" 'Los de tipo Windows son los que Apple acepta ahora.'
    } else {
        Add-Hallazgo 'OK' "Responden $($vivos.Count) de $($items.Count) servidores anisette" ("Windows operativos: " + (($win | ForEach-Object { $_.Nombre }) -join ', '))
    }
}

function Test-DiagRegistro {
    $script:Pistas = @(Get-PistasIloader)
    if ($script:Pistas.Count -eq 0) {
        Add-Hallazgo 'INFO' 'El registro de iloader no muestra errores conocidos recientes' 'Normal si nunca lo has usado o no hay registro.'
        return
    }
    foreach ($p in $script:Pistas) {
        Add-Hallazgo 'AVISO' "iloader registro recientemente: $($p.Texto)" "Aparece $($p.Veces) vez/veces en sus ultimos registros."
    }
}

function Invoke-Arreglos {
    foreach ($a in @($script:Arreglos | Select-Object -Unique)) {
        try {
            switch ($a) {
                'hora'     { if (Confirmar 'Sincronizo ahora la hora del PC?' $true) { Sync-HoraPc } }
                'servicio' { if (Confirmar 'Arranco ahora el servicio USB de Apple?' $true) { Start-AppleServicio } }
                'driver'   { if (Confirmar 'Instalo ahora el driver USB de Apple (tarda unos minutos)?' $true) { Install-DriverApple } }
                'iloader'  { if (Confirmar 'Actualizo ahora iloader a la ultima version?' $true) { [void](Install-Iloader) } }
            }
        } catch { Aviso "No pude completar el arreglo '$a': $($_.Exception.Message)" }
    }
}

# ---- preguntas
function Read-Opcion([string]$Texto, [int]$Max) {
    do { $r = Read-Host $Texto } until ($r -match '^\d+$' -and [int]$r -le $Max)
    return [int]$r
}

function Get-Sintomas {
    @(
        @{ Id = '80045';    Txt = "Al iniciar sesion con mi Apple ID sale -80045 ('This action cannot be completed at this time')" },
        @{ Id = '20209';    Txt = "Sale -20209 o 'cuenta bloqueada por seguridad'" },
        @{ Id = '503';      Txt = "Sale 503, 429, 'Service Temporarily Unavailable' o 'Too many requests'" },
        @{ Id = 'password'; Txt = "Dice que el usuario o la contrasena son incorrectos (-20101, 3002, 1102)" },
        @{ Id = '2fa';      Txt = "Pide el codigo de verificacion pero no me deja ponerlo, sale -22411, o el SMS falla" },
        @{ Id = 'udid';     Txt = "'Could not determine this device's UDID', 'InvalidPairing' o pide el pairing file" },
        @{ Id = 'vpn';      Txt = "'You do not appear to be connected to VPN/Wi-Fi', error 27 o LocalDevVPN" },
        @{ Id = 'usb';      Txt = "iloader no ve mi iPhone/iPad o sale un error de usbmuxd" },
        @{ Id = 'limite';   Txt = "Limite de apps o App IDs, o 'Maximum certificates reached'" },
        @{ Id = 'noabre';   Txt = "La app no abre, 'desarrollador no confiable' o hay que activar el Modo desarrollador" }
    )
}

function Select-Sintoma {
    $lista = @(Get-Sintomas)
    Write-Host "`nQue es lo que te pasa? Elige el numero que mas se parezca:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $lista.Count; $i++) {
        $pista = if ($script:Pistas -and (@($script:Pistas | Where-Object { $_.Id -eq $lista[$i].Id }).Count -gt 0)) { '   <-- lo he visto en el registro de iloader' } else { '' }
        Write-Host ("  {0,2}) {1}{2}" -f ($i + 1), $lista[$i].Txt, $pista)
    }
    Write-Host ("  {0,2}) Otra cosa / no se (solo quiero la revision automatica)" -f ($lista.Count + 1))
    Write-Host "   0) Salir"
    $n = Read-Opcion "Elige 0-$($lista.Count + 1)" ($lista.Count + 1)
    if ($n -eq 0 -or $n -gt $lista.Count) { return '' }
    return $lista[$n - 1].Id
}

function Select-Donde {
    Write-Host "`nDonde te sale el error?"
    Write-Host '  1) En iloader, en el PC'
    Write-Host '  2) En SideStore, en el iPhone/iPad'
    if ((Read-Opcion 'Elige 1-2' 2) -eq 2) { return 'iphone' } else { return 'pc' }
}

# ---- soluciones (texto en lenguaje llano)
function Show-Bloque([string]$Que, [string[]]$Pasos, [string[]]$No) {
    Write-Host ''
    Write-Host 'QUE PASA' -ForegroundColor Cyan
    Write-Host "  $Que"
    Write-Host 'QUE HACER (en este orden)' -ForegroundColor Green
    for ($i = 0; $i -lt $Pasos.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $Pasos[$i]) }
    if ($No) {
        Write-Host 'QUE NO HACER' -ForegroundColor Red
        foreach ($n in $No) { Write-Host "  - $n" }
    }
}

function Show-RecetaIphone {
    $pasos = @(
        "Instala SideStore NIGHTLY: abre iloader, inicia sesion y en 'Installers' pulsa 'SideStore (Nightly)'. La version Stable no trae la correccion del 2FA.",
        "En el iPhone: confia en el perfil (Ajustes > General > VPN y gestion de dispositivos) y conecta LocalDevVPN.",
        "En SideStore: Ajustes > User Customizations > desactiva 'On-Device Anisette'.",
        "En 'Anisette Client Configuration' (pestana Interactive) escribe:"
    )
    Show-Bloque "Apple rechaza el login que hace SideStore dentro del iPhone, aunque iloader en el PC funcione. SideStore Nightly lo corrige, pero hay que decirle que se identifique como el servidor Windows." $pasos $null
    $ci = if ($script:ClientInfoWin) { $script:ClientInfoWin } else { '<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>' }
    $ua = if ($script:UserAgentWin) { $script:UserAgentWin } else { 'akd/1.0 CFNetwork/808.1.4' }
    Write-Host "       Client Info : $ci" -ForegroundColor White
    Write-Host "       User Agent  : $ua" -ForegroundColor White
    Write-Host "  5. Pulsa 'Save Overrides' y cierra SideStore del todo (desde el selector de apps)."
    Write-Host "  6. Abre SideStore e inicia sesion UNA vez. El codigo de 6 digitos sale en el iPhone una sola vez: anotalo antes de cerrarlo, y elige el codigo de dispositivo de confianza (no SMS)."
    Write-Host "  7. Si da error HTTP 404: en 'Anisette Servers' elige 'Jkcoxson' (mac-ani.jkcoxson.com) con el client info por defecto. Windows con Windows, Mac con Mac."
    Write-Host 'QUE NO HACER' -ForegroundColor Red
    Write-Host '  - No pruebes mas de 1 o 2 veces seguidas: Apple puede bloquear tu cuenta (error -20209).'
}

# Devuelve 'pairing' si conviene ofrecer el modo Pairing del script.
function Show-Solucion([string]$Id, [string]$Donde) {
    $oferta = ''
    switch ($Id) {
        '80045' {
            if ($Donde -eq 'iphone') { Show-RecetaIphone }
            else {
                Show-Bloque "Apple ha rechazado el inicio de sesion de iloader. Desde el 12-13 de octubre de 2026 Apple cambio su sistema de login y algunas cuentas o redes siguen rechazadas aunque todo este bien configurado. Depende de tu cuenta y de tu red, no de tu PC." @(
                    "Comprueba que iloader es la 2.3.8 o superior (arriba te digo cual tienes; si esta viejo, actualizalo).",
                    "En iloader pulsa 'Restablecer estado de Anisette', elige un servidor 'Windows' de la lista e inicia sesion UNA vez. Si falla, repite UNA vez con uno 'Mac'.",
                    "Cuando pida verificacion en dos pasos, usa el codigo de un dispositivo de confianza (el SMS falla de momento).",
                    "Cambia de red (por ejemplo, comparte datos del movil con el PC) e intentalo una vez.",
                    "Prueba con otro Apple ID (uno secundario): es lo que mas suele funcionar.",
                    "Si nada funciona, espera unas horas o dias: es un problema del lado de Apple."
                ) @("No reintentes muchas veces seguidas: Apple puede bloquear tu cuenta (error -20209).")
            }
        }
        '20209' {
            Show-Bloque "Apple ha bloqueado tu cuenta por seguridad, normalmente tras varios intentos fallidos de inicio de sesion. Es inofensivo y se resuelve." @(
                "Entra en https://iforgot.apple.com y sigue los pasos para desbloquearla (necesitaras un dispositivo de confianza o tu telefono).",
                "Cuando la desbloquees, espera un rato antes de volver a probar.",
                "Intenta iniciar sesion UNA sola vez, con iloader actualizado y codigo de dispositivo de confianza.",
                "Si vuelve a bloquearse, usa un Apple ID secundario solo para SideStore."
            ) @("No insistas con la cuenta bloqueada: solo empeora.")
        }
        '503' {
            Show-Bloque "El servidor de Apple o el servidor anisette esta saturado, o Apple te esta limitando por haber hecho muchos intentos (errores 503/429)." @(
                "Actualiza iloader a la ultima version (la 2.3.8 ya corrige el 503).",
                "En iloader cambia de servidor anisette (lista desplegable en Ajustes) y pulsa 'Restablecer estado de Anisette'.",
                "Espera un buen rato antes de volver a probar.",
                "Cambia de red (datos del movil compartidos) y prueba una vez.",
                $(if ($Donde -eq 'iphone') { "En SideStore usa la version Nightly y la configuracion de anisette del apartado -80045 (iPhone)." } else { "Si pasa solo con tu Apple ID, prueba con otro." })
            ) @("No reintentes seguido: Apple te limita mas.")
        }
        'password' {
            Show-Bloque "Apple dice que el correo o la contrasena no son correctos, o que la cuenta no puede usarse para desarrollo." @(
                "Escribe el correo y la contrasena con cuidado (distingue mayusculas y minusculas).",
                "Comprueba que puedes entrar en https://account.apple.com con esos mismos datos.",
                "Si la cuenta es nueva, inicia sesion en https://developer.apple.com y acepta los terminos (errores 1102 o -1011).",
                "Revisa que la fecha y hora del PC y del iPhone son correctas (el diagnostico de arriba mira la del PC).",
                "Si sigue, crea un Apple ID nuevo solo para SideStore."
            ) @("No uses llaves de seguridad como 2FA: no estan soportadas. Usa codigo de dispositivo de confianza.")
        }
        '2fa' {
            Show-Bloque "Apple pide el codigo de verificacion, pero SideStore/iloader no lo procesa bien (error -22411, o el SMS falla)." @(
                "Usa el codigo de un dispositivo de confianza, no el SMS.",
                "En SideStore usa la version Nightly (la Stable tiene este fallo).",
                "El codigo de 6 digitos aparece una sola vez en tu otro dispositivo Apple: anotalo antes de cerrarlo.",
                "Cierra SideStore del todo y reabrelo antes de reintentar.",
                "Si antes del codigo sale -80045, mira la opcion de -80045 de este menu."
            ) @("No pidas varios codigos seguidos.")
        }
        'udid' {
            Show-Bloque "SideStore no encuentra el 'pairing file' de este dispositivo (caduca o se invalida al actualizar iOS)." @(
                "En SideStore: Ajustes > Reset Pairing File.",
                "En iloader: 'Delete Stored Pairing', luego 'Actualizar dispositivos', elige tu dispositivo y toca 'Confiar' en el.",
                "En iloader: 'Manage Pairing File' y pulsa 'Place' junto a SideStore (o 'Place In All Apps'). Debe salir en verde.",
                "Abre SideStore y refresca.",
                "Si no: en SideStore, Ajustes > VPN Configuration, pon Device IP 10.7.0.1 (o la IP que hayas puesto en LocalDevVPN).",
                "Si no: reinicia el iPhone/iPad y el PC y repite."
            ) $null
            $oferta = 'pairing'
        }
        'vpn' {
            Show-Bloque "SideStore no puede hablar con el dispositivo: falta Wi-Fi o LocalDevVPN, o el pairing file no es valido." @(
                "Conecta el iPhone a una red Wi-Fi (los datos moviles no sirven).",
                "Abre LocalDevVPN y pulsa 'Connect'. Debe estar conectada siempre que instales o refresques apps.",
                "Si sigue: reemplaza el pairing file (opcion 'UDID/pairing' de este menu).",
                "Si tienes iOS 26.4 o superior: usa SideStore Nightly.",
                "En SideStore: Ajustes > VPN Configuration > Device IP = 10.7.0.1."
            ) $null
            $oferta = 'pairing'
        }
        'usb' {
            Show-Bloque "El PC no ve tu iPhone/iPad por USB, asi que iloader no puede trabajar." @(
                "Usa un cable USB de datos (algunos solo cargan), otro puerto del PC y sin hubs.",
                "Desbloquea el dispositivo, ve a la pantalla de inicio y toca 'Confiar' + tu codigo.",
                "Mira arriba si el driver USB de Apple esta instalado y en marcha; si falta, ejecuta el modo Instalar.",
                "Abre iTunes (o 'Apple Devices') y comprueba que ve el dispositivo.",
                "Si sigue: desinstala iTunes y Apple Mobile Device Support e instala solo 'Apple Devices' de la Microsoft Store (o al reves: iTunes de apple.com).",
                "Reinicia el PC."
            ) $null
        }
        'limite' {
            Show-Bloque "Las cuentas Apple gratuitas tienen limites: 3 apps instaladas a la vez y 10 App IDs cada 7 dias." @(
                "Borra las apps sideloaded que no uses (las caducadas tambien cuentan).",
                "Los App IDs no se pueden borrar: se liberan a los 7 dias. En iloader > App IDs ves cuantos te quedan.",
                "Instalar apps desde dentro de SideStore a veces gasta menos App IDs.",
                "Si iloader dice 'Maximum certificates reached', deja que revoque el certificado antiguo."
            ) $null
        }
        'noabre' {
            Show-Bloque "El iPhone no deja abrir la app: falta confiar en tu perfil de desarrollador o activar el Modo desarrollador." @(
                "Ajustes > General > VPN y gestion de dispositivos > 'App de desarrollador' > tu Apple ID > Confiar.",
                "iOS 16 o superior: Ajustes > Privacidad y seguridad > Modo desarrollador > activar (el dispositivo se reinicia).",
                "Abre LocalDevVPN y pulsa 'Connect'.",
                "Abre SideStore, inicia sesion y toca el contador '7 DAYS' junto a SideStore para refrescarlo."
            ) $null
        }
    }
    return $oferta
}

# ---- resumen e informe
function Show-Resumen {
    $err = @($script:Hallazgos | Where-Object { $_.Estado -eq 'ERROR' })
    $avi = @($script:Hallazgos | Where-Object { $_.Estado -eq 'AVISO' })
    $ok = @($script:Hallazgos | Where-Object { $_.Estado -eq 'OK' })
    Write-Host "`nRESUMEN: $($ok.Count) cosas bien, $($avi.Count) avisos, $($err.Count) problemas." -ForegroundColor Cyan
    $pend = @($err + $avi | Where-Object { $_.Accion })
    if ($pend.Count -gt 0) {
        Write-Host 'Lo que conviene hacer en tu PC:' -ForegroundColor Yellow
        foreach ($h in $pend) { Write-Host "  - $($h.Titulo): $($h.Accion)" }
    } elseif ($err.Count -eq 0) {
        Ok 'Tu PC esta bien. Si algo falla, el problema esta en la cuenta de Apple, la red o el iPhone: sigue los pasos de arriba.'
    }
}

function Save-Informe([string]$Sintoma, [string]$Donde) {
    try {
        $dir = [Environment]::GetFolderPath('Desktop')
        if (-not $dir -or -not (Test-Path $dir)) { $dir = $script:Dir; New-Item -ItemType Directory -Force $dir | Out-Null }
        $ruta = Join-Path $dir 'SideStore-Diagnostico.txt'
        $l = New-Object System.Collections.Generic.List[string]
        $l.Add('SideStore Installer - informe de diagnostico')
        $l.Add(('Fecha: {0:yyyy-MM-dd HH:mm}' -f (Get-Date)))
        $l.Add("Windows: $([Environment]::OSVersion.Version) | PowerShell: $($PSVersionTable.PSVersion)")
        $txt = if ($Sintoma) { (@(Get-Sintomas) | Where-Object { $_.Id -eq $Sintoma } | Select-Object -First 1).Txt } else { '(sin sintoma concreto)' }
        $l.Add("Problema indicado: $txt")
        if ($Donde) { $l.Add("Donde falla: $Donde") }
        $l.Add('')
        $l.Add('Revision automatica:')
        foreach ($h in $script:Hallazgos) {
            $linea = "  [$($h.Estado)] $($h.Titulo)"
            if ($h.Detalle) { $linea += " - $($h.Detalle)" }
            $l.Add($linea)
        }
        if ($script:EstadoAnisette) {
            $l.Add('')
            $l.Add('Servidores anisette:')
            foreach ($a in $script:EstadoAnisette) { $l.Add(("  {0} ({1}): {2} {3}" -f $a.Nombre, $a.Servidor, $a.Estado, $a.Tipo)) }
        }
        $l.Add('')
        $l.Add('Este informe no contiene tu Apple ID, contrasenas ni rutas personales.')
        [IO.File]::WriteAllLines($ruta, $l.ToArray(), (New-Object Text.UTF8Encoding $true))
        Write-Host "`nHe guardado un informe en: $ruta" -ForegroundColor Green
        Write-Host 'Si pides ayuda (Discord de idevice o GitHub de iloader/SideStore), adjunta ese archivo: no lleva datos personales.'
    } catch { Aviso "No pude guardar el informe: $($_.Exception.Message)" }
}

function Invoke-Diagnostico {
    $script:Hallazgos = New-Object System.Collections.ArrayList
    $script:Arreglos = @()
    $script:Pistas = @()
    $script:EstadoAnisette = $null

    Paso 'Diagnostico de SideStore'
    Write-Host 'Voy a revisar tu PC (1-2 minutos), te preguntare que te pasa y te dire como arreglarlo.'
    Write-Host 'No te pedire contrasenas ni tu Apple ID. No cambio nada sin preguntarte antes.'

    Paso '1/3 Revision automatica del PC'
    Invoke-Comprobacion 'sistema'    { Test-DiagSistema }
    Invoke-Comprobacion 'hora'       { Test-DiagHora }
    Invoke-Comprobacion 'conexion'   { Test-DiagRed }
    Invoke-Comprobacion 'driver USB' { Test-DiagDriver }
    Invoke-Comprobacion 'iloader'    { Test-DiagIloader }
    Invoke-Comprobacion 'anisette'   { Test-DiagAnisette }
    Invoke-Comprobacion 'registro'   { Test-DiagRegistro }

    if (@($script:Arreglos).Count -gt 0) {
        Paso 'Arreglos automaticos'
        Invoke-Arreglos
    }

    Paso '2/3 Cuentame que te pasa'
    $sintoma = Select-Sintoma
    $donde = ''
    if ($sintoma -in '80045', '503', '2fa') { $donde = Select-Donde }

    Paso '3/3 Diagnostico y que hacer'
    $oferta = ''
    if ($sintoma) { $oferta = Show-Solucion $sintoma $donde }
    Show-Resumen
    Save-Informe $sintoma $donde

    if ($oferta -eq 'pairing' -and (Confirmar "`nQuieres que te guie ahora para regenerar el pairing file con este script?" $true)) {
        Invoke-Pairing
    }
}

# ---------------------------------------------------------------- flujos
function Invoke-Instalar {
    Paso '1/6 Comprobaciones'
    Test-Sistema
    Test-Red
    Test-Anisette

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
  4) Diagnostico: algo falla, ayudame a encontrar la causa
  5) Salir
'@
    do { $r = Read-Host 'Elige 1-5' } until ($r -match '^[1-5]$')
    switch ($r) { '1' { 'Instalar' } '2' { 'Pairing' } '3' { 'Limpiar' } '4' { 'Diagnostico' } '5' { 'Salir' } }
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

    # winget escribe UTF-8; sin esto la consola (OEM) muestra las tildes rotas (Versi + simbolos raros).
    $codifAntes = $null
    try {
        $codifAntes = [Console]::OutputEncoding
        $utf8 = New-Object Text.UTF8Encoding $false
        [Console]::OutputEncoding = $utf8
        $OutputEncoding = $utf8
    } catch { }

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
            'Diagnostico' { Invoke-Diagnostico }
            'Salir'    { return }
        }
        Ok "`nTerminado. Log: $log"
    } catch {
        Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  (linea $($_.InvocationInfo.ScriptLineNumber)) Log completo: $log" -ForegroundColor DarkGray
        Aviso 'Puedes relanzar el script: los pasos ya hechos se detectan y se saltan.'
    } finally {
        if ($transcribiendo) { try { Stop-Transcript | Out-Null } catch { } }
        if ($codifAntes) { try { [Console]::OutputEncoding = $codifAntes } catch { } }
        [void](Read-Host "`nEnter para cerrar")
    }
}

# Al hacer dot-source (. .\script.ps1) solo se cargan las funciones.
if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }
