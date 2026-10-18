# SideStoreInstaller

Script de PowerShell todo-en-uno para **Windows 10/11 (x64)** que **instala [SideStore](https://sidestore.io)** en un iPhone/iPad usando [iloader](https://github.com/nab138/iloader). Prepara el PC, te guía por cada paso y, opcionalmente, lo deja limpio al terminar.

También sirve para **regenerar el pairing file** cuando SideStore lo pide otra vez (`-Modo Pairing`).

## Uso

**Doble clic en [`Instalar-SideStore.cmd`](Instalar-SideStore.cmd).** Pide permisos de administrador (acepta el aviso de Windows), salta la política de ejecución de PowerShell y lanza el instalador. Si el `.cmd` está solo (sin el `.ps1` al lado), descarga el script de GitHub automáticamente, así que basta con bajar ese único archivo.

**¿Algo falla? Doble clic en [`Diagnosticar-SideStore.cmd`](Diagnosticar-SideStore.cmd)** (ver [Diagnóstico guiado](#diagnóstico-guiado)).

Alternativas:

```powershell
powershell -ExecutionPolicy Bypass -File .\sidestore-installer.ps1
```

o clic derecho sobre el `.ps1` → *Ejecutar con PowerShell* (también se reabre como administrador). Sin parámetros muestra un menú.

| Modo | Qué hace |
|---|---|
| `-Modo Instalar` *(menú opción 1)* | Instalación completa de SideStore. |
| `-Modo Pairing` | Solo regenera el pairing file. |
| `-Modo Limpiar` | Desinstala iloader y los componentes de Apple. |
| `-Modo Diagnostico` | **¿Algo falla?** Revisa el PC, te pregunta qué te pasa y te explica cómo arreglarlo. |

## Qué hace el modo Instalar

| Paso | Acción |
|---|---|
| **1/6** | Comprueba Windows (64 bits, no Win10 ARM), las URLs de SideStore/iloader/GitHub/Apple (DNS, TCP 443, HTTP) y **todos los servidores anisette** de la [lista oficial](https://github.com/SideStore/anisette-servers/blob/main/servers.json) (`/v3/client_info`, indicando si son Windows o Mac). |
| **2/6** | Checklist del iPhone/iPad: código de acceso, Wi-Fi, **LocalDevVPN** instalada y conectada, Apple ID. Pregunta tu versión de iOS para adaptar los pasos finales. |
| **3/6** | Instala el driver USB de Apple (servicio *Apple Mobile Device Service*). Prueba en orden: `winget` iTunes → `winget` Apple Mobile Device Support → iTunes directo de apple.com → Apple Devices (Store). Si falta `winget`, lo instala. |
| **4/6** | Instala la última release oficial de iloader (valida que sea un MSI real). **Si ya hay una versión vieja instalada, la actualiza**: las anteriores a la 2.3.8 fallan al iniciar sesión con Apple (`-80045`, 503). |
| **5/6** | Espera al dispositivo por USB. |
| **6/6** | Abre iloader y te guía: iniciar sesión → elegir dispositivo → **SideStore (Stable)**. iloader coloca el pairing file solo. Después, pasos en el iPhone/iPad: confiar en el perfil, Modo desarrollador (iOS 16+), conectar LocalDevVPN, abrir SideStore, refrescar. |
| **Final** | Pregunta si funciona; con `s` desinstala iloader y los drivers. |

En cualquier paso puedes escribir `e` en lugar de Enter para ver la **ayuda de errores** (incluido `-80045`) y reintentar ese paso.

Cada ejecución guarda un log en `%LOCALAPPDATA%\SideStoreInstaller\logs`. Si falla, el script no se cierra: muestra el error y se puede relanzar (los pasos hechos se saltan).

## Diagnóstico guiado

Pensado para cualquier usuario: no hace falta saber qué significa cada código. Tres pasos:

1. **Revisión automática del PC** (marca ✔/⚠/✖ cada punto): versión de Windows, **hora del PC** (Apple rechaza el login si está desfasada), conexión con GitHub/Apple/anisette, driver USB de Apple, versión de **iloader** (¿antigua?), servidores anisette de la lista oficial y los **errores recientes del registro de iloader** (solo cuenta cuáles, no copia su contenido).
2. **Arreglos con un clic** (siempre preguntando): sincronizar la hora, arrancar el servicio de Apple, instalar el driver, actualizar iloader.
3. **Te pregunta qué te pasa** con frases normales (no con códigos) y, según tu respuesta y lo que encontró, te da **qué pasa → qué hacer → qué no hacer**. Cubre: `-80045` (en iloader o en SideStore/iPhone), `-20209` cuenta bloqueada, `503/429`, usuario o contraseña, verificación en dos pasos (`-22411`), UDID/pairing, VPN/Wi-Fi, iPhone no detectado, límites de apps/App IDs y app que no abre. Si el problema es el pairing file, te ofrece lanzar el modo Pairing.

Al final guarda **`SideStore-Diagnostico.txt` en el Escritorio**: un informe para adjuntar si pides ayuda (no incluye tu Apple ID, contraseñas ni rutas personales).

## Limpieza

Quita iloader (y su carpeta de datos) y, solo si **los instaló este script** (o si lo confirmas), iTunes, Apple Mobile Device Support, Apple Application Support, Apple Software Update y Bonjour. No toca iCloud. El script no se borra.

## Si sigue fallando

- **`Auth error -80045: This action cannot be completed at this time`** (falla al iniciar sesión con el Apple ID). Es Apple rechazando el login desde el 12-13 de octubre de 2026; no depende del PC ni del script, sino de la cuenta y de la red. Algunas cuentas lo reciben con cualquier configuración ([iloader#928](https://github.com/nab138/iloader/issues/928)).
  - ⚠️ **No reintentes en bucle.** Apple está bloqueando cuentas por reintentos (`-20209`). Si pasa, se desbloquea en [iforgot.apple.com](https://iforgot.apple.com). Haz como mucho 1-2 intentos por configuración.
  1. Usa **iloader 2.3.8 o superior** (el script lo actualiza solo). En iloader: *Restablecer estado de Anisette* y prueba **una vez** un servidor Windows y **una vez** uno Mac de su lista (los personalizados ya no funcionan).
  2. Con 2FA, usa el código de un **dispositivo de confianza** (el SMS falla de momento).
  3. Cambia de red (datos del móvil compartidos) y/o usa un **Apple ID secundario**: es lo que más suele funcionar cuando una cuenta o IP sigue rechazada.
  4. Si falla **dentro de SideStore** (iPhone) pero no en iloader — receta que ha funcionado en pruebas reales **con la versión Stable** (no hace falta la Nightly): en SideStore, *Ajustes → User Customizations* → desactiva **On-Device Anisette**; *Ajustes → Anisette Servers* → elige **SideStore (Windows ADI)**; cierra SideStore del todo, reábrelo e inicia sesión **una sola vez** (el código de 6 dígitos sale en el iPhone una sola vez: anótalo). Si aún falla: *Anisette Client Configuration* (pestaña *Interactive*) → Client Info `<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>` y User Agent `akd/1.0 CFNetwork/808.1.4` → *Save Overrides* ([SideStore#1665](https://github.com/SideStore/SideStore/issues/1665)); como último recurso, la versión Nightly. El script muestra el valor vigente en el paso 1.
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
