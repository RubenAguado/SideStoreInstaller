# SideStoreInstaller

Script de PowerShell todo-en-uno para **Windows 10/11 (x64)** que **instala [SideStore](https://sidestore.io)** en un iPhone/iPad usando [iloader](https://github.com/nab138/iloader). Prepara el PC, te guía por cada paso y, opcionalmente, lo deja limpio al terminar.

También sirve para **regenerar el pairing file** cuando SideStore lo pide otra vez (`-Modo Pairing`).

## Uso

1. Descarga [`sidestore-installer.ps1`](sidestore-installer.ps1).
2. Ejecútalo (se reabre solo como administrador):

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\sidestore-installer.ps1
   ```

   O clic derecho → *Ejecutar con PowerShell*. Sin parámetros muestra un menú.

| Modo | Qué hace |
|---|---|
| `-Modo Instalar` *(menú opción 1)* | Instalación completa de SideStore. |
| `-Modo Pairing` | Solo regenera el pairing file. |
| `-Modo Limpiar` | Desinstala iloader y los componentes de Apple. |

## Qué hace el modo Instalar

| Paso | Acción |
|---|---|
| **1/6** | Comprueba Windows (64 bits, no Win10 ARM) y las URLs de SideStore/iloader/GitHub/Apple (DNS, TCP 443, HTTP) para distinguir dominio muerto, bloqueo de ISP o caída. |
| **2/6** | Checklist del iPhone/iPad: código de acceso, Wi-Fi, **LocalDevVPN** instalada y conectada, Apple ID. Pregunta tu versión de iOS para adaptar los pasos finales. |
| **3/6** | Instala el driver USB de Apple (servicio *Apple Mobile Device Service*). Prueba en orden: `winget` iTunes → `winget` Apple Mobile Device Support → iTunes directo de apple.com → Apple Devices (Store). Si falta `winget`, lo instala. |
| **4/6** | Descarga e instala la última release oficial de iloader (valida que sea un MSI real). |
| **5/6** | Espera al dispositivo por USB. |
| **6/6** | Abre iloader y te guía: iniciar sesión → elegir dispositivo → **SideStore (Stable)**. iloader coloca el pairing file solo. Después, pasos en el iPhone/iPad: confiar en el perfil, Modo desarrollador (iOS 16+), conectar LocalDevVPN, abrir SideStore, refrescar. |
| **Final** | Pregunta si funciona; con `s` desinstala iloader y los drivers. |

Cada ejecución guarda un log en `%LOCALAPPDATA%\SideStoreInstaller\logs`. Si falla, el script no se cierra: muestra el error y se puede relanzar (los pasos hechos se saltan).

## Limpieza

Quita iloader (y su carpeta de datos) y, solo si **los instaló este script** (o si lo confirmas), iTunes, Apple Mobile Device Support, Apple Application Support, Apple Software Update y Bonjour. No toca iCloud. El script no se borra.

## Si sigue fallando

- **iloader no ve el dispositivo / error `usbmuxd`**: desinstala iTunes y Apple Mobile Device Support y prueba solo con *Apple Devices* de la Microsoft Store (o al revés: iTunes de apple.com). Cambia de cable/puerto y desbloquea el dispositivo.
- **`Could not determine this device's UDID`**: en SideStore, *Ajustes → Advanced → Reset pairing file*, reinicia y repite con `-Modo Pairing`.
- **`InvalidPairing (rppairing UDID not found)`**: `-Modo Pairing` con el dispositivo por USB. En iOS 17+ el pairing caduca solo cada cierto tiempo.
- **"You do not appear to be connected to VPN"**: conecta LocalDevVPN (debe estar activa para instalar/refrescar). Con iPadOS 26.x puede hacer falta SideStore *nightly*.
- **Error de login/2FA en iloader**: revisa credenciales, prueba otro Apple ID o cambia el servidor *anisette* en los ajustes de iloader.
- **Límites de cuenta gratuita**: 3 apps sideloaded y 10 App IDs por semana.
- **Un dominio no responde**: mira el paso 1. Si `sidestore.io` falla y otro responde, puede ser bloqueo de IP de tu ISP (rangos de Cloudflare).
- Logs de iloader: `%APPDATA%\me.nabdev.iloader\logs`. Soporte: [Discord de idevice](https://discord.gg/EA6yVgydBz).

## Requisitos

- Windows 10/11 de 64 bits (no Windows 10 ARM), PowerShell 5.1+, permisos de administrador.
- iPhone/iPad con iOS/iPadOS 15+ y código de acceso, cable USB, Wi-Fi.
- Apple ID (con verificación en dos pasos).
- Internet.

## Aviso

Script no oficial, sin relación con SideStore, iloader ni Apple. Se ejecuta como administrador e instala/desinstala software: léelo antes de lanzarlo.
