# Modules/Recomendaciones.ps1
# Reglas de recomendaciones del diagnóstico. SOLO LEE el objeto de hardware: no toca el sistema.
# Niveles: Crítico, Aviso, Info, Consejo.
#
# Umbrales fijados con el usuario (el CLAUDE.md no los define): más de 10 programas de inicio habilitados y más
# de 7 días sin reiniciar. Poco espacio libre: menos del 15 %. Driver de video viejo: más de 3 años.

$global:OptiLowUmbralProgramasInicio = 10
$global:OptiLowUmbralDiasSinReiniciar = 7
$global:OptiLowUmbralEspacioLibrePct = 15
$global:OptiLowUmbralDriverAnios = 3

function New-RecomendacionHw {
    # Auxiliar interna.
    param(
        [Parameter(Mandatory)][ValidateSet('Crítico', 'Aviso', 'Info', 'Consejo')][string]$Nivel,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Titulo,
        [Parameter(Mandatory)][string]$Detalle
    )
    return [pscustomobject]@{ Nivel = $Nivel; Id = $Id; Titulo = $Titulo; Detalle = $Detalle }
}

function Get-Recomendaciones {
    <#
    .SYNOPSIS
        Genera las recomendaciones (Crítico, Aviso, Info, Consejo) a partir del objeto de hardware.
    .DESCRIPTION
        En una máquina virtual se omiten las alertas de GPU, tipo de disco y ranuras de RAM (los valores virtuales
        no son fiables) y se muestra un Info. Las partes desconocidas no generan alertas: se resumen en un Info.
        La "GPU antigua" (solo la lista de legacy-gpu-patterns.txt) recomienda desactivar la aceleración por
        hardware; "sin soporte del fabricante" es solo informativo.
    .EXAMPLE
        Get-Recomendaciones -Hardware (New-HardwareSimulado -Perfil Bajo)
    #>
    param(
        [Parameter(Mandatory)]$Hardware
    )

    $r = New-Object System.Collections.ArrayList
    $vm = ($Hardware.EsMaquinaVirtual -eq $true)

    if ($vm) {
        $hip = $Hardware.Hipervisor; if (-not $hip) { $hip = 'desconocido' }
        [void]$r.Add((New-RecomendacionHw -Nivel Info -Id 'maquina-virtual' -Titulo "Máquina virtual detectada (hipervisor: $hip)" `
                    -Detalle "Motivo: $($Hardware.MotivoVM). Se omiten las alertas de GPU, tipo de disco y ranuras de RAM porque los valores de una máquina virtual no son fiables."))
    }

    # --- GPU ---
    $g = $Hardware.GPUPrincipal
    if ((-not $vm) -and $g) {
        if ($g.SinDriver) {
            [void]$r.Add((New-RecomendacionHw -Nivel Crítico -Id 'gpu-sin-driver' -Titulo "Sin driver de video ($($g.Nombre))" `
                        -Detalle 'Windows está usando el adaptador básico de Microsoft: sin aceleración gráfica, el sistema y el navegador van mucho más lentos. Instala el driver desde la página oficial del fabricante del equipo o de la GPU (o desde Windows Update > Actualizaciones opcionales). No uses programas de "actualizar drivers".'))
        }
        elseif ($g.EsAntigua) {
            [void]$r.Add((New-RecomendacionHw -Nivel Aviso -Id 'gpu-antigua' -Titulo "GPU antigua: $($g.Nombre)" `
                        -Detalle "Coincide con el patrón '$($g.PatronCoincidente)' de gráficos muy viejos. Con una GPU así suele convenir desactivar la aceleración por hardware del navegador y de Discord (se ofrecerá como optimización). En una GPU moderna con un CPU de 2 núcleos NO conviene."))
        }
        elseif ($g.SinSoporteFabricante) {
            [void]$r.Add((New-RecomendacionHw -Nivel Info -Id 'gpu-sin-soporte' -Titulo "Drivers sin soporte activo del fabricante: $($g.Nombre)" `
                        -Detalle 'Es solo informativo: esta GPU sigue acelerando bien el navegador y el video, así que NO es motivo para desactivar la aceleración por hardware (en un CPU débil, desactivarla empeora el rendimiento).'))
        }
        if ((-not $g.SinDriver) -and ($null -ne $g.EdadDriverDias) -and ($g.EdadDriverDias -gt (365 * $global:OptiLowUmbralDriverAnios))) {
            [void]$r.Add((New-RecomendacionHw -Nivel Aviso -Id 'gpu-driver-viejo' -Titulo "El driver de video tiene más de $($global:OptiLowUmbralDriverAnios) años" `
                        -Detalle ("Fecha del driver: {0:yyyy-MM-dd} (versión {1}). En equipos antiguos a veces no existe uno más nuevo. Revisa si el fabricante tiene una versión más reciente: la página oficial del fabricante del equipo o de la GPU, o Windows Update (Configuración > Windows Update > Opciones avanzadas > Actualizaciones opcionales). No uses programas de ""actualizar drivers"": suelen instalar versiones incorrectas o software no deseado." -f $g.FechaDriver, $g.DriverVersion)))
        }
    }

    # --- RAM ---
    $ram = $Hardware.RAM
    if ((-not $vm) -and $ram -and ($null -ne $ram.InstaladaGB) -and ($ram.InstaladaGB -le 4)) {
        if ($null -eq $ram.RanurasLibres) { $ranuras = 'No se pudo saber si quedan ranuras libres.' }
        elseif ($ram.RanurasLibres -gt 0) { $ranuras = "Hay $($ram.RanurasLibres) ranura(s) libre(s) de $($ram.RanurasTotales): ampliar la RAM es la mejora más barata." }
        else { $ranuras = 'No quedan ranuras libres: habría que cambiar los módulos por otros de más capacidad.' }
        [void]$r.Add((New-RecomendacionHw -Nivel Aviso -Id 'ram-4gb' -Titulo "Poca RAM: $($ram.InstaladaGB) GB" -Detalle "Con 4 GB o menos Windows se queda corto con el navegador y varias aplicaciones. $ranuras"))
    }

    # --- Disco ---
    $d = $Hardware.Disco
    if ($d) {
        if ((-not $vm) -and $d.Fiable -and ($d.Tipo -eq 'HDD')) {
            [void]$r.Add((New-RecomendacionHw -Nivel Aviso -Id 'disco-hdd' -Titulo "El disco del sistema es un HDD ($($d.Modelo))" `
                        -Detalle 'Cambiar a un SSD es la mayor mejora de rendimiento posible en un equipo de este tipo: el arranque, las aplicaciones y todo el sistema responden mucho más rápido.'))
        }
        if (($null -ne $d.LibrePct) -and ($d.LibrePct -lt $global:OptiLowUmbralEspacioLibrePct)) {
            [void]$r.Add((New-RecomendacionHw -Nivel Aviso -Id 'poco-espacio' -Titulo "Poco espacio libre en $($d.Unidad) (solo queda el $($d.LibrePct) %)" `
                        -Detalle "Quedan $($d.LibreGB) GB de $($d.TamanoGB) GB. Con menos del $($global:OptiLowUmbralEspacioLibrePct) % libre, Windows y las actualizaciones van más lentos. Libera espacio o mueve archivos a otra unidad."))
        }
        if (-not $vm) {
            if (@('Warning', 'Unhealthy') -contains $d.Salud) {
                [void]$r.Add((New-RecomendacionHw -Nivel Crítico -Id 'disco-salud' -Titulo "El disco del sistema reporta salud: $($d.Salud)" `
                            -Detalle 'Windows indica que el disco puede estar fallando. Haz una copia de seguridad de tus archivos importantes cuanto antes y planea sustituirlo.'))
            }
            elseif ($d.Salud -eq 'Unknown') {
                [void]$r.Add((New-RecomendacionHw -Nivel Info -Id 'disco-salud-desconocida' -Titulo 'No se pudo determinar la salud del disco' `
                            -Detalle 'Windows no informa de la salud de este disco; no significa que falle.'))
            }
        }
    }

    # --- Uso del sistema ---
    $prog = $Hardware.ProgramasInicio
    if ($prog -and ($prog.Habilitados -gt $global:OptiLowUmbralProgramasInicio)) {
        [void]$r.Add((New-RecomendacionHw -Nivel Aviso -Id 'inicio-muchos' -Titulo "Muchos programas de inicio: $($prog.Habilitados)" `
                    -Detalle "Hay más de $($global:OptiLowUmbralProgramasInicio) programas que arrancan con Windows. Cada uno alarga el arranque y consume RAM. Revisa cuáles necesitas (pestaña de programas de inicio)."))
    }
    if (($null -ne $Hardware.ArranqueDias) -and ($Hardware.ArranqueDias -gt $global:OptiLowUmbralDiasSinReiniciar)) {
        $nota = ''
        if ($Hardware.InicioRapido -eq $true) { $nota = ' Con el inicio rápido de Windows, "Apagar" no reinicia el sistema: usa "Reiniciar".' }
        [void]$r.Add((New-RecomendacionHw -Nivel Aviso -Id 'sin-reiniciar' -Titulo "Llevas $($Hardware.ArranqueDias) días sin reiniciar" `
                    -Detalle "Reiniciar libera memoria y aplica actualizaciones pendientes.$nota"))
    }

    # --- Administración ---
    $a = $Hardware.Administracion
    if ($a) {
        if ($a.Administrado -eq $true) {
            [void]$r.Add((New-RecomendacionHw -Nivel Info -Id 'equipo-administrado' -Titulo 'Equipo administrado por una organización' `
                        -Detalle "Detectado: $($a.Bloqueantes -join '; '). No se recomienda desactivar los servicios de telemetría (DiagTrack, dmwappushservice): dmwappushservice participa en la administración de dispositivos (Intune/MDM)."))
        }
        elseif ($null -eq $a.Administrado) {
            [void]$r.Add((New-RecomendacionHw -Nivel Info -Id 'administracion-desconocida' -Titulo 'No se pudo comprobar si el equipo está administrado' `
                        -Detalle "No se pudo leer la unión a dominio o a Entra ID ($($a.Error)); por precaución no se recomienda desactivar los servicios de telemetría."))
        }
        if ($a.AvisoWorkplace) {
            [void]$r.Add((New-RecomendacionHw -Nivel Info -Id 'cuenta-trabajo' -Titulo 'Cuenta del trabajo o la escuela en este equipo' -Detalle $a.AvisoWorkplace))
        }
    }

    # --- Datos que no se pudieron leer ---
    $fallidas = @($Hardware.Consultas | Where-Object { $_.Estado -ne 'Ok' })
    if ($fallidas.Count -gt 0) {
        $lista = ($fallidas | ForEach-Object { "$($_.Nombre) ($($_.Estado))" }) -join ', '
        [void]$r.Add((New-RecomendacionHw -Nivel Info -Id 'datos-incompletos' -Titulo 'Algunos datos no se pudieron leer' `
                    -Detalle "Consultas con problemas: $lista. Esas partes se muestran como desconocidas y no generan alertas."))
    }

    # --- Consejos manuales (no se automatizan) ---
    [void]$r.Add((New-RecomendacionHw -Nivel Consejo -Id 'consejo-antivirus' -Titulo 'Usa un solo antivirus' `
                -Detalle 'Dos antivirus a la vez se estorban y ralentizan el equipo. Windows Defender es suficiente para la mayoría; si instalas otro, desactiva el anterior desde su propio programa.'))
    if (($Hardware.Perfil -eq 'Bajo') -or (($null -ne $ram) -and ($null -ne $ram.InstaladaGB) -and ($ram.InstaladaGB -le 8))) {
        [void]$r.Add((New-RecomendacionHw -Nivel Consejo -Id 'consejo-navegador' -Titulo 'Activa el ahorro de memoria del navegador' `
                    -Detalle 'En Edge (Configuración > Sistema y rendimiento) y en Chrome (Configuración > Rendimiento) activa el ahorro de memoria, y cierra las pestañas que no uses.'))
    }
    if ((-not $vm) -and ($Hardware.Perfil -eq 'Bajo')) {
        [void]$r.Add((New-RecomendacionHw -Nivel Consejo -Id 'consejo-limpieza' -Titulo 'Limpieza de polvo y pasta térmica' `
                    -Detalle 'En equipos viejos, limpiar el polvo del ventilador y renovar la pasta térmica del procesador baja la temperatura y evita que se frene por calor.'))
    }
    if (($null -ne $ram) -and ($null -ne $ram.InstaladaGB) -and ($ram.InstaladaGB -le 4)) {
        [void]$r.Add((New-RecomendacionHw -Nivel Consejo -Id 'consejo-paginacion' -Titulo 'No desactives el archivo de paginación' `
                    -Detalle 'Con 4 GB de RAM el archivo de paginación es imprescindible; desactivarlo provoca cierres de programas y errores por falta de memoria.'))
    }

    # Por nivel y, dentro de cada nivel, en el orden en que se generaron (Sort-Object no es estable en 5.1)
    $orden = @{ 'Crítico' = 0; 'Aviso' = 1; 'Info' = 2; 'Consejo' = 3 }
    $n = 0
    $conIndice = foreach ($x in $r) { [pscustomobject]@{ Nivel = $orden[$x.Nivel]; Indice = $n; Rec = $x }; $n++ }
    return @($conIndice | Sort-Object Nivel, Indice | ForEach-Object { $_.Rec })
}
