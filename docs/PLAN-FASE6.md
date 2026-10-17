# Fase 6 — apuntes acordados (todavía SIN plan completo)

Este archivo recoge lo ya decidido con el usuario; el plan de la fase se propondrá y aprobará antes de escribir código.

## Alcance previsto (CLAUDE.md)
Resto de tweaks, pestaña de Programas de inicio (listar, deshabilitar y habilitar con `StartupApproved`, validando el conteo contra el Administrador de tareas) y pestaña de Respaldo y restauración completa.

## Apuntes de la prueba de la fase 5 en la VM
- **Deshacer una optimización individual desde su fila.** Hoy solo hay «Deshacer última sesión» (todo lo de una ejecución) y la gente no lo descubre: tras aplicar, la fila queda «Aplicado» con la casilla gris. Para la fase 6: botón «Deshacer» en la fila de cada optimización aplicada, usando el `TweakId` que ya guarda cada entrada del journal (hay que añadir `Undo-JournalSesion -TweakId`, ver `docs/IDEAS.md`). Mientras tanto la interfaz explica dónde se deshace (texto en Optimizaciones, tooltip de la fila y resumen tras aplicar).
- **Probar el bloatware** en la VM con **Windows 11 Home** (VirtualBox, español, PowerShell 5.1), que sí trae apps de la Store.
- Medir el arranque en frío: en esa VM, script en marcha 4289 ms y primer dibujo 6147 ms (la ventana se ve a los ~6 s desde el doble clic; por eso `Iniciar.cmd` muestra «Abriendo OptiLow…» hasta entonces) y ~5 s más de análisis en segundo plano.

## Requisitos de claridad (pedidos al cerrar la fase 5)
- **Pestaña de Respaldo y restauración completa, comprensible para un usuario normal:** fecha y hora en formato local (p. ej. «17/10/2026, 2:44»), el **nombre** de las optimizaciones en lugar de su Id, el número de cambios y un estado claro («Se puede deshacer» en lugar de «Activo»; igualmente claros «Deshecha» y «Deshecha parcialmente»). El Id de la sesión solo en un detalle o tooltip. (Hoy la lista muestra `20260101-000000000-1 · iniciada 2026-01-01T00:00:00 · Restaurado · 1 entrada(s)` y los Id de los tweaks.)
- **Optimizaciones:** una fila ya aplicada no debe seguir diciendo «Recomendada para este equipo» como si faltara algo: debe decir algo como «Aplicada (recomendada para este equipo)». (Hoy `Update-FilaUI` en `UI/Interfaz.ps1` pone la marca de recomendada sin mirar el estado.)

---

# Plan aprobado de la fase 6 (subfases)

Orden: **6a, 6b, 6c1, 6c2, 6d, 6e**. Cada subfase tiene su prueba, su commit y su actualización de `docs/ESTADO.md`; no se empieza la siguiente sin la confirmación del usuario tras probar la anterior en la VM.

- **6a. Respaldo y restauración completa + deshacer por optimización.** `Undo-JournalTweak` (orden inverso). Antes de deshacer UNA optimización se comprueba si una sesión posterior sin deshacer (u otra optimización posterior de la misma sesión) modificó las mismas claves, servicios, tareas o archivos, y si el valor actual ya no es el que dejamos nosotros: en ese caso **no se deshace sin confirmación explícita** (`-Forzar`). Interfaz: botón «Deshacer» por fila, tarjetas de sesión comprensibles (fecha local, nombres, número de cambios, «Se puede deshacer» / «Deshecha» / «Deshecha parcialmente»), «Aplicada (recomendada para este equipo)».
- **6b. Programas de inicio.** Listar, deshabilitar y habilitar con `StartupApproved` (nunca borrar). Verificar el formato binario, la asociación Run/Run32/StartupFolder y los valores de primer byte. Las apps de la Store que arrancan solas y no están en `Run` se muestran aparte («se gestionan desde Configuración > Aplicaciones > Inicio») o se cuentan aparte, para poder comparar el conteo con el Administrador de tareas.
- **6c1. Telemetría por registro, apps en segundo plano y efectos visuales.** `AllowTelemetry`, ID de publicidad, `ContentDeliveryManager`, `GlobalUserDisabled`, `VisualFXSetting = 3` (verificar qué bits apaga y que conserve el suavizado de fuentes). Los criterios de `Recomendar` se proponen al usuario ANTES de escribirlos.
- **6c2. Discord y navegadores Chromium.** Incluye una función de `Core/` para cerrar procesos **con confirmación**: avisar de que cerrar Discord corta una llamada de voz en curso, y tener en cuenta que Discord corre en varios procesos y en la bandeja del sistema. Criterios de `Recomendar` propuestos antes.
- **6d. Servicios y plan de energía.** SysMain (solo recomendado en HDD), WSearch (nunca automático), plan «Alto rendimiento» (solo sin batería; verificar el GUID y el caso de Modern Standby).
- **6e. Bloatware (al final).** Punto de restauración **obligatorio**: si no se puede crear, no se aplica (sin opción de continuar sin punto). Lista de paquetes que **nunca** se quitan escrita en el código (no solo en `Config/bloatware.txt`): Microsoft Store, Instalador de aplicaciones (winget), Seguridad de Windows, Calculadora, Bloc de notas, Fotos, Terminal, Recortes, Paint y cualquier componente del sistema que se verifique. El usuario elige app por app. Verificar y proponer el alcance (solo usuario actual o también el paquete aprovisionado para usuarios nuevos) y avisar de que una actualización grande de Windows puede reinstalar algunas apps.
