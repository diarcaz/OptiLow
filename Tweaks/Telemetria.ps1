# Tweaks/Telemetria.ps1
# Categoría: Telemetría y privacidad.

[void](Register-Tweak `
    -Id 'telemetria-servicios-off' `
    -Nombre 'Desactivar servicios de telemetría (DiagTrack y dmwappushservice)' `
    -Categoria 'Telemetría y privacidad' `
    -Descripcion 'Cambia a Deshabilitado el inicio de "Experiencias del usuario conectado y telemetría" (DiagTrack) y del servicio de enrutamiento de mensajes WAP Push (dmwappushservice), que consumen CPU y disco en segundo plano. Solo cambia el tipo de inicio: los servicios siguen en ejecución hasta reiniciar. Efecto secundario: no usar en equipos administrados por una empresa (Intune/MDM), porque dmwappushservice se usa en la sincronización con la administración de dispositivos; puede limitar el envío de comentarios a Microsoft.' `
    -Riesgo Medio `
    -Requiere Reiniciar `
    -Aplicar {
        Set-ServicioInicio -Nombre 'DiagTrack' -Inicio Disabled
        Set-ServicioInicio -Nombre 'dmwappushservice' -Inicio Disabled
    } `
    -Comprobar {
        # Verifica la CONFIGURACIÓN (tipo de inicio), no si el servicio sigue en ejecución
        $estados = foreach ($nombre in @('DiagTrack', 'dmwappushservice')) {
            $s = Get-ServicioEstado -Nombre $nombre
            if ($s.Existe) { $s.Inicio -eq 'Disabled' } else { $null }
        }
        Join-EstadosTweak -Estados @($estados)
    })

# Tareas programadas de telemetría que más cargan un HDD. Si alguna no existe en esa versión de Windows, se omite.
# Los nombres y rutas salen de fuentes de la comunidad (no de la documentación de Microsoft): por eso el motor
# trata "no existe" como NoAplica y no como error.
[void](Register-Tweak `
    -Id 'telemetria-tareas-off' `
    -Nombre 'Desactivar tareas programadas de telemetría' `
    -Categoria 'Telemetría y privacidad' `
    -Descripcion 'Desactiva las tareas programadas de recopilación de datos: Microsoft Compatibility Appraiser, ProgramDataUpdater, CEIP Consolidator, UsbCeip y DiskDiagnosticDataCollector. Provocan lecturas y escrituras de disco que se notan en un HDD. Las que no existan en esta versión de Windows se omiten. Efecto secundario: Windows deja de enviar esos datos de compatibilidad y diagnóstico a Microsoft; no afecta al funcionamiento normal.' `
    -Riesgo Bajo `
    -Requiere Nada `
    -Aplicar {
        Disable-TareaProgramada -Ruta '\Microsoft\Windows\Application Experience\' -Nombre 'Microsoft Compatibility Appraiser'
        Disable-TareaProgramada -Ruta '\Microsoft\Windows\Application Experience\' -Nombre 'ProgramDataUpdater'
        Disable-TareaProgramada -Ruta '\Microsoft\Windows\Customer Experience Improvement Program\' -Nombre 'Consolidator'
        Disable-TareaProgramada -Ruta '\Microsoft\Windows\Customer Experience Improvement Program\' -Nombre 'UsbCeip'
        Disable-TareaProgramada -Ruta '\Microsoft\Windows\DiskDiagnostic\' -Nombre 'Microsoft-Windows-DiskDiagnosticDataCollector'
    } `
    -Comprobar {
        $tareas = @(
            @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
            @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
            @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
            @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
            @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector')
        )
        $estados = foreach ($t in $tareas) {
            $e = Get-TareaEstado -Ruta $t[0] -Nombre $t[1]
            if ($e.Existe) { -not $e.Habilitada } else { $null }
        }
        Join-EstadosTweak -Estados @($estados)
    })
