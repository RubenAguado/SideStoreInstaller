# SideStoreInstaller

Script de PowerShell todo-en-uno para **Windows 10/11** que regenera el *pairing file* de [SideStore](https://sidestore.io) en un iPhone/iPad usando [iloader](https://github.com/nab138/iloader), y que después **deja el PC limpio** (desinstala iloader y los componentes de Apple).

> Pensado para el caso típico: actualizas iOS/iPadOS, SideStore pide de nuevo el pairing file y no lo tienes.

## Qué hace

| Paso | Acción |
|---|---|
| **0/4** | Comprueba las URLs que usa SideStore (`sidestore.io`, `sidestore.xyz`, `docs`, `apps`, servidores *anisette*, `cdn.altstore.io`, `iloader.app`, GitHub...) y para cada una distingue **DNS / conexión TCP 443 / HTTP**, para saber si un dominio está muerto, bloqueado por tu ISP/DNS o simplemente caído. |
| **1/4** | Instala el driver *Apple Mobile Device Support* con `winget` (sin él Windows no ve el iPad por USB). |
| **2/4** | Descarga la última release de iloader desde GitHub (`iloader-windows-x64.msi`) y la instala. |
| **3/4** | Espera a que el iPad aparezca por USB. |
| **4/4** | Abre iloader y te guía, con una pausa por paso, en los 4 clics que no se pueden automatizar. |
| **Final** | Pregunta si ya funciona. Si contestas `s`, desinstala todo (ver abajo) y **deja solo el script** para relanzarlo cuando haga falta. |

## Uso

1. Descarga [`sidestore-repair-pairing.ps1`](sidestore-repair-pairing.ps1).
2. Abre PowerShell en la carpeta y ejecuta:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\sidestore-repair-pairing.ps1
   ```

   (o clic derecho sobre el archivo → *Ejecutar con PowerShell*; también puedes pegar su contenido entero en una consola).
3. Conecta el iPad por USB, **desbloqueado**, y toca *Confiar* si lo pide.
4. Sigue las instrucciones. En iloader:
   1. **Delete Stored Pairing** (descarta el pairing viejo).
   2. Pulsa tu iPad en la lista y toca **Confiar** en el iPad.
   3. **Manage Pairing File**.
   4. Junto a **SideStore** (y LiveContainer si aparece) pulsa **Place**. Debe salir en verde *Pairing file placed successfully!*.
5. Abre SideStore en el iPad y prueba un refresco.
6. Vuelve al script y contesta `s` a *¿Funciona todo?* para limpiar, o `n` para dejarlo instalado y repetir.

## Limpieza automática

Con `s` se desinstala, esté o no instalado antes por el script:

- iloader (y su carpeta de datos)
- iTunes
- Apple Mobile Device Support (incluye el driver USB)
- Apple Application Support
- Apple Software Update
- Bonjour

No toca iCloud ni otros programas de Apple. El script **no se borra**. Si algún driver sigue apareciendo tras terminar, reinicia el PC.

## Si sigue fallando

- **"Could not determine this device's UDID"**: en SideStore, *Ajustes → Advanced → Reset pairing file*, reinicia el iPad y repite *Place*.
- **`InvalidPairing (rppairing UDID not found)`**: repite *Delete Stored Pairing → Trust → Place* con el iPad por USB. En iOS 17+ el pairing es RemoteXPC (RPPairing) y se invalida solo cada cierto tiempo.
- **"You do not appear to be connected to VPN"**: comprueba que LocalDevVPN está conectada, o que el *Connection Config* de SideStore sigue bien tras actualizar. Con iPadOS 26.x puede hacer falta el SideStore *nightly*.
- **Un dominio de SideStore no responde**: mira el resultado del paso 0. Si `sidestore.io` falla pero otro dominio (p. ej. `.xyz`) responde, usa ese: a veces el problema es un bloqueo de IP de tu ISP (rangos de Cloudflare) y no un dominio caído.

## Requisitos

- Windows 10/11 con PowerShell 5.1 o superior.
- [`winget`](https://learn.microsoft.com/windows/package-manager/) (App Installer).
- Cable USB y un iPhone/iPad con código de acceso.
- Conexión a Internet.

## Aviso

Script no oficial, sin relación con SideStore ni con Apple. Se ejecuta con tus permisos e instala/desinstala software: léelo antes de lanzarlo.
