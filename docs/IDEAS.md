# Ideas fuera de fase

Mejoras que se ocurren durante el desarrollo pero no pertenecen a la fase actual.
No se implementan hasta que se aprueben.

- (Fase 2) Opción para configurar el espacio de la Protección del sistema (vssadmin resize shadowstorage) cuando el motivo sea "sin espacio asignado".
- (Fase 2) Parámetro para detener el servicio además de cambiar su tipo de inicio (hoy solo cambia el inicio).
- (Fase 2) Alias de planes de energía conocidos (Equilibrado, Alto rendimiento, Economizador) en `Set-PlanEnergia`, tras verificar sus GUID en la documentación.
- (Fase 2) Edición quirúrgica de texto en `Set-JsonValor` para no reformatear el archivo JSON completo.
- (Fase 3) `Undo-JournalSesion -TweakId` para deshacer un solo tweak de una sesión (el TweakId ya se guarda en cada entrada); lo usará la interfaz.
- (Fase 3) Verificar en la VM las rutas de las tareas de telemetría (vienen de fuentes de la comunidad, no de Microsoft); `Pruebas/Probar-Fase3.ps1` lista cuáles existen.
- (Fase 3) Que la interfaz y la consola muestren la `Descripcion` completa de cada tweak con su efecto secundario antes de confirmar (la consola ya lo hace).
- (Fase 3) Tarea "Microsoft Compatibility Appraiser Exp" (Application Experience, vista en Windows 11 24H2): parece el reemplazo de "Microsoft Compatibility Appraiser", pero NO se pudo verificar en ninguna fuente fiable (la búsqueda solo encontró información de la tarea clásica), así que no se incluye en `telemetria-tareas-off`. En esa carpeta también hay MareBackup, PcaPatchDbTask, SdbinstMergeDbTask y StartupAppTask: no se tocan. Revisar si Microsoft documenta "Exp".
- (Fase 3) En 24H2 no existen "Microsoft Compatibility Appraiser" ni "ProgramDataUpdater": se omiten como NoAplica (siguen en la lista para Windows 10 y 11 anteriores).
