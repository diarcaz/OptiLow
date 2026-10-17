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
