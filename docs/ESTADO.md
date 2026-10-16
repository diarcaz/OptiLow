# Estado del proyecto OptiLow

Última actualización: tras cerrar la fase 4 y aprobar el plan de la fase 5 (todavía **sin código** de la fase 5).
Repositorio: https://github.com/diarcaz/OptiLow (privado), rama `main`. Carpeta local: `C:\Users\artur\Desktop\Proyecto_Patata`.

Para retomar el trabajo en una sesión nueva: leer `CLAUDE.md` (reglas, contrato, datos verificados y trampas de PowerShell 5.1),
este archivo y `docs/PLAN-FASE5.md`; comprobar `git status` y `git log --oneline`; **esperar la orden del usuario** antes de empezar la fase 5.

## Resumen de fases

| Fase | Contenido | Estado | Resultado en la VM / pruebas |
|---|---|---|---|
| 1 | Estructura, cargador, administrador (UAC), logging | Terminada | Probada en el equipo del usuario: UAC aceptado y cancelado (aviso WARN), ruta con espacios y acentos |
| 2 | Journal, registro (6 tipos), JSON, archivos, servicios, tareas, energía, punto de restauración | Terminada | VM Windows 11 24H2: 61 bien / 1 fallo (punto de restauración) -> corregido -> **74 bien, 0 fallos** |
| 3 | Motor de tweaks, consola (`-Listar`, `-Aplicar`, `-Deshacer`, `-ListarSesiones`) y 3 tweaks | Terminada | VM: 41 bien / 4 fallos (DelayedAutostart al deshacer) -> corregido -> **45 bien, 0 fallos** |
| 4 | Diagnóstico de hardware, recomendaciones, `-Diagnostico`, `-PerfilSimulado`, `-Aplicar recomendados` | Terminada (pendiente repetir en la VM tras 48b49e7) | VM (VirtualBox, Windows 11 IoT Enterprise LTSC 24H2): **250 bien, 0 fallos**; VM detectada sin alertas falsas; `dsregcmd` se lee; diagnóstico en 1,8 s; programas de inicio 3 = 3 del Administrador de tareas. Luego se corrigieron 3 detalles (ver abajo); en el equipo del usuario la suite da 255/255 |
| 5 | Interfaz WPF/XAML | **Plan aprobado, sin implementar** (`docs/PLAN-FASE5.md`) | - |
| 6 | Resto de tweaks, pestaña Programas de inicio, pestaña Respaldo y restauración completa, bloatware, Discord, navegadores | Pendiente | - |
| 7 | `README.md` y `docs/ARQUITECTURA.md` | Pendiente | - |

### Correcciones posteriores a la prueba en la VM (ya hechas y subidas)
- Fase 2: punto de restauración con `Checkpoint-Computer` en 5.1 y CIM solo como respaldo en PowerShell 7; motivo `YaExisteReciente` con fecha y descripción; un cambio que falla sin tocar nada se quita del journal; el deshacer explica las entradas ya revertidas; `ConvertTo-Json -Depth 100`.
- Fase 3: `sc.exe` dejaba `DelayedAutostart = 0` donde antes no existía el valor; el deshacer lo elimina. La prueba imprime las diferencias (ANTES/DESPUÉS) y vuelca todas las claves del servicio.
- Fase 4: `0 -eq ''` hacía que "0 días encendido" saliera como "desconocido"; los datos que faltan aunque la consulta termine bien quedan como consulta `Desconocido` (sin duplicar); RAM sin detalle de módulos dice "detalle de módulos no disponible"; título "Poco espacio libre en C: (solo queda el 11.8 %)".

### Commits relevantes
`bb7f525` fase 1 · `430003d` fase 2 · `01cc2c0` correcciones fase 2 · `a7299a2` fase 3 · `47fb3dd` correcciones fase 3 · `5f3c9cb` fase 4 · `48b49e7` correcciones fase 4 · (siguiente) documentación del traspaso a la fase 5.

## Cómo se prueba cada cosa

Todos los scripts están en `Pruebas/` y se ejecutan con `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pruebas\<script>` (Windows PowerShell 5.1). **Nunca en el equipo principal las que cambian cosas.**

| Script | Dónde / cómo | Qué comprueba |
|---|---|---|
| `Probar-Fase2.ps1` | VM, consola **de administrador**, pide `SI` | Carpeta `backups\` protegida, 6 tipos de registro (HKLM y HKCU), vista de 64 bits (incluida una consulta desde PowerShell de 32 bits), JSON, archivos, servicio y tarea ficticios, restauración parcial, plan de energía, punto de restauración real (opcional) y cuarentena de `backups\`. Esperado: 74 bien, 0 fallos |
| `Probar-Fase3.ps1` | VM, administrador, pide `SI` | Aplica y deshace de verdad `efectos-transparencia-off`, `telemetria-servicios-off` y `telemetria-tareas-off`; una sola sesión; aviso de reinicio; parámetros y códigos de salida de `OptiLow.ps1`. Esperado: 45 bien, 0 fallos |
| `Probar-Fase4.ps1` | Cualquier equipo, **solo lectura**, sin administrador, sin confirmación | Patrones de GPU con nombres reales (que sí y que no), perfiles, detección de VM, tipo de disco, recomendaciones Bajo/Medio/Alto simulados, tolerancia a fallos y a tiempos agotados, que el diagnóstico no escribe, bloqueo de `-PerfilSimulado`, flujo de `-Aplicar recomendados` con funciones de prueba, diagnóstico real. Esperado: 255 bien, 0 fallos (en la VM salieron 250 antes de añadir la sección 13) |
| `Probar-Core-SinAdmin.ps1` | VM, consola **no elevada**, pide `SI` | Lógica de `Core/` sin administrador (journal en carpeta temporal): registro, JSON de 5 niveles, archivos, tareas, servicios, energía. Esperado: 78 bien, 0 fallos |
| `Probar-Motor-SinAdmin.ps1` | VM, consola no elevada, pide `SI` | Motor de tweaks y consola con funciones de prueba. Esperado: 56 bien, 0 fallos |
| `Diagnostico-PuntoRestauracion.ps1` | VM, administrador (crea puntos reales) | Comparó CIM, WMI clásico y `Checkpoint-Computer` (tema cerrado) |

Comprobaciones antes de dar algo por terminado: todos los `.ps1` parsean sin errores y tienen BOM (ver el fragmento en `CLAUDE.md`), no hay funciones duplicadas en `Core/` y `Modules/`, `git status` limpio.

Uso manual de la consola (útil en la VM): `.\OptiLow.ps1 -Diagnostico`, `-Diagnostico -PerfilSimulado Bajo`, `-Listar`, `-Aplicar efectos-transparencia-off`, `-Aplicar recomendados`, `-ListarSesiones`, `-Deshacer`.

## Pendientes conocidos
- **Repetir `Probar-Fase4.ps1` en la VM** tras las correcciones `48b49e7` (debe dar 255/255; ahora también prueba "0 días", RAM sin módulos y datos que faltan).
- **Programas de inicio deshabilitados:** en la VM no hay ninguno, así que el descuento con `StartupApproved` (primer byte 03 = deshabilitado) solo está probado para el caso "ninguno deshabilitado" (3 = 3). En el equipo principal salen 9 habilitados y 22 deshabilitados sin comparar con el Administrador de tareas. Hay que probarlo en la fase 6, cuando se pueda deshabilitar y habilitar.
- **Bloatware (fase 6):** la VM actual es Windows 11 IoT Enterprise LTSC, que casi no trae apps de la Store. Para probarlo hace falta una VM con **Windows 11 Home o Pro**.
- **Tareas de telemetría:** en Windows 11 24H2 no existen "Microsoft Compatibility Appraiser" ni "ProgramDataUpdater"; sí existen Consolidator, UsbCeip y DiskDiagnosticDataCollector. Las rutas vienen de fuentes de la comunidad. "Microsoft Compatibility Appraiser Exp" no se pudo verificar y no se toca (ver `docs/IDEAS.md`).
- **Windows 10 y equipos reales lentos (HDD, 4 GB):** todo se ha probado en Windows 11 24H2 (VM y equipo principal). Falta probar en Windows 10 y medir el diagnóstico y, en la fase 5, el arranque de la interfaz en un equipo lento.
- **Causa del fallo inconsistente de `CreateRestorePoint` por CIM:** sin determinar (hipótesis en `CLAUDE.md`); tema cerrado de todos modos.
- Ideas fuera de fase: `docs/IDEAS.md`.

## Decisiones del usuario que conviene recordar
- Todo en español (interfaz, log, comentarios, documentación). Windows PowerShell 5.1 manda sobre PowerShell 7.
- Se trabaja por fases y se espera su confirmación; plan antes del código en cambios grandes; no se añade nada fuera de la fase (se anota en `IDEAS.md`).
- Subir a GitHub solo cuando lo pide (lo ha pedido al cerrar cada fase y tras las correcciones).
- El journal es obligatorio; `-SinPreguntar` elige siempre la opción segura; `-PerfilSimulado` es solo para ver.
- Datos técnicos no seguros: verificar en Microsoft Learn e informar **antes** de usarlos.

## Siguiente: fase 5 (interfaz XAML)
Plan completo, aprobado y con todas las respuestas y ajustes del usuario en `docs/PLAN-FASE5.md`.
Primer paso al retomar: confirmar con el usuario que se empieza, verificar los datos técnicos que el plan lista (renderizado por software, `RenderCapability.Tier`, alternativas a `WScript.Shell.Popup`) y reportarlos antes de usarlos.
