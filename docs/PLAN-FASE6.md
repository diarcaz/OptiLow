# Fase 6 — apuntes acordados (todavía SIN plan completo)

Este archivo recoge lo ya decidido con el usuario; el plan de la fase se propondrá y aprobará antes de escribir código.

## Alcance previsto (CLAUDE.md)
Resto de tweaks, pestaña de Programas de inicio (listar, deshabilitar y habilitar con `StartupApproved`, validando el conteo contra el Administrador de tareas) y pestaña de Respaldo y restauración completa.

## Apuntes de la prueba de la fase 5 en la VM
- **Deshacer una optimización individual desde su fila.** Hoy solo hay «Deshacer última sesión» (todo lo de una ejecución) y la gente no lo descubre: tras aplicar, la fila queda «Aplicado» con la casilla gris. Para la fase 6: botón «Deshacer» en la fila de cada optimización aplicada, usando el `TweakId` que ya guarda cada entrada del journal (hay que añadir `Undo-JournalSesion -TweakId`, ver `docs/IDEAS.md`). Mientras tanto la interfaz explica dónde se deshace (texto en Optimizaciones, tooltip de la fila y resumen tras aplicar).
- **Probar el bloatware** en la VM con **Windows 11 Home** (VirtualBox, español, PowerShell 5.1), que sí trae apps de la Store.
- Medir el arranque en frío: en esa VM, script en marcha 4289 ms y primer dibujo 6147 ms (la ventana se ve a los ~6 s desde el doble clic; por eso `Iniciar.cmd` muestra «Abriendo OptiLow…» hasta entonces) y ~5 s más de análisis en segundo plano.
