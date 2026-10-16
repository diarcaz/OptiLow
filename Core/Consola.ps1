# Core/Consola.ps1
# Presentación y preguntas del modo consola (sin interfaz gráfica). Aquí sí se usa Write-Host y Read-Host:
# esta capa solo muestra y pregunta; la lógica está en Core/Tweaks.ps1, Journal.ps1 y PuntoRestauracion.ps1,
# que la interfaz usará directamente sin pasar por este archivo.
#
# Códigos de salida de las acciones de consola: 0 = bien, 1 = hubo fallos o un error, 2 = cancelado.

function Read-ConfirmacionConsola {
    <#
    .SYNOPSIS
        Pregunta y devuelve $true solo si el usuario escribe SI. Sin consola interactiva devuelve $false.
    #>
    param(
        [Parameter(Mandatory)][string]$Pregunta
    )

    try {
        $respuesta = Read-Host "$Pregunta (escribe SI para aceptar, otra cosa para cancelar)"
    }
    catch {
        return $false
    }
    $r = ([string]$respuesta).Trim().ToUpperInvariant()
    return (($r -eq 'SI') -or ($r -eq 'SÍ'))
}

function Show-TweaksConsola {
    <#
    .SYNOPSIS
        Lista los tweaks registrados agrupados por categoría, con riesgo, requisito y estado actual (solo lee).
    .EXAMPLE
        Show-TweaksConsola
    #>
    $todos = @(Get-Tweak)
    if ($todos.Count -eq 0) {
        Write-Host 'No hay ninguna optimización registrada (carpeta Tweaks/).' -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host ('{0,-11} {1,-6} {2,-14} {3}' -f 'ESTADO', 'RIESGO', 'REQUIERE', 'ID  -  NOMBRE') -ForegroundColor Cyan
    foreach ($grupo in ($todos | Group-Object Categoria)) {
        Write-Host ''
        Write-Host "[$($grupo.Name)]" -ForegroundColor Cyan
        foreach ($t in $grupo.Group) {
            $estado = Get-TweakEstado -Id $t.Id
            $color = switch ($estado.Estado) {
                'Aplicado'   { 'Green' }
                'Pendiente'  { 'White' }
                'NoAplica'   { 'DarkGray' }
                'Error'      { 'Red' }
                default      { 'Gray' }
            }
            $marca = ''
            if (-not $t.Reversible) { $marca = '  (NO reversible)' }
            Write-Host ('{0,-11} {1,-6} {2,-14} {3}  -  {4}{5}' -f $estado.Estado, $t.Riesgo, $t.Requiere, $t.Id, $t.Nombre, $marca) -ForegroundColor $color
        }
    }
    Write-Host ''
}

function Show-SesionesConsola {
    <#
    .SYNOPSIS
        Lista las sesiones del journal (la más reciente primero). Requiere administrador.
    #>
    try { Assert-JournalListo -Completo }
    catch {
        Write-Log -Nivel ERROR -Mensaje $_.Exception.Message
        return 1
    }

    $sesiones = @(Get-JournalSesiones)
    if ($sesiones.Count -eq 0) {
        Write-Host 'No hay sesiones en el journal.'
        return 0
    }
    Write-Host ''
    Write-Host ('{0,-26} {1,-19} {2,-18} {3,8}  {4}' -f 'ID DE SESIÓN', 'INICIO', 'ESTADO', 'ENTRADAS', 'TWEAKS') -ForegroundColor Cyan
    foreach ($s in $sesiones) {
        $color = 'White'
        if ($s.Estado -eq 'Restaurado') { $color = 'DarkGray' }
        elseif ($s.Estado -eq 'RestauradoParcial') { $color = 'Yellow' }
        Write-Host ('{0,-26} {1,-19} {2,-18} {3,8}  {4}' -f $s.Id, $s.Inicio, $s.Estado, $s.Entradas, (@($s.Tweaks) -join ', ')) -ForegroundColor $color
    }
    Write-Host ''
    return 0
}

function Format-ValorHw {
    # Auxiliar interna: texto de un dato del diagnóstico ("desconocido" si no se pudo leer).
    param($Valor, [string]$Sufijo = '')
    # OJO: en PowerShell 0 -eq '' es VERDADERO; un 0 es un dato válido (p. ej. 0 días encendido o 0 ranuras libres)
    if (($null -eq $Valor) -or (($Valor -is [string]) -and ($Valor.Length -eq 0))) { return 'desconocido' }
    return ([string]$Valor + $Sufijo)
}

function Format-RamHw {
    <#
    .SYNOPSIS
        Texto legible de la RAM: cuando falta el detalle dice "detalle de módulos no disponible", no "desconocido
        módulo(s); ranuras libres: desconocido de desconocido".
    #>
    param($Ram)

    if ((-not $Ram) -or ($null -eq $Ram.InstaladaGB)) { return 'desconocido' }
    $partes = New-Object System.Collections.ArrayList
    if ($null -ne $Ram.Modulos) { [void]$partes.Add("$($Ram.Modulos) módulo(s)") } else { [void]$partes.Add('detalle de módulos no disponible') }
    if (($null -ne $Ram.RanurasTotales) -and ($null -ne $Ram.RanurasLibres)) { [void]$partes.Add("ranuras libres: $($Ram.RanurasLibres) de $($Ram.RanurasTotales)") }
    elseif ($null -ne $Ram.RanurasTotales) { [void]$partes.Add("$($Ram.RanurasTotales) ranuras (libres: no disponible)") }
    else { [void]$partes.Add('ranuras: no disponible') }
    if ($Ram.VelocidadMHz) { [void]$partes.Add("$($Ram.VelocidadMHz) MHz") }
    elseif ($null -ne $Ram.Modulos) { [void]$partes.Add('velocidad no disponible') }
    return ("{0} GB instalada  [{1}]" -f $Ram.InstaladaGB, ($partes -join '; '))
}

function Show-DiagnosticoConsola {
    <#
    .SYNOPSIS
        Muestra el diagnóstico de hardware en consola: datos, perfil, recomendaciones, optimizaciones recomendadas y
        cuánto tardó. Solo muestra (no escribe nada en el sistema).
    .EXAMPLE
        Show-DiagnosticoConsola -Hardware (Get-Diagnostico)
    #>
    param(
        [Parameter(Mandatory)]$Hardware
    )

    $hw = $Hardware
    Write-Host ''
    if ($hw.Simulado) {
        Write-Host '=== DIAGNÓSTICO SIMULADO (datos de prueba, solo para ver: no se puede aplicar nada) ===' -ForegroundColor Magenta
    }
    else {
        Write-Host '=== Diagnóstico de hardware ===' -ForegroundColor Cyan
    }

    $e = $hw.Equipo
    Write-Host ('Equipo:    {0} {1}' -f (Format-ValorHw $e.Fabricante), (Format-ValorHw $e.Modelo))
    if ($hw.EsMaquinaVirtual -eq $true) { Write-Host ("           Máquina virtual (hipervisor: {0}). Motivo: {1}" -f (Format-ValorHw $hw.Hipervisor), $hw.MotivoVM) -ForegroundColor Cyan }
    $w = $hw.Windows
    if ($w) { Write-Host ('Windows:   {0} (compilación {1}, {2})' -f (Format-ValorHw $w.Nombre), (Format-ValorHw $w.Compilacion), (Format-ValorHw $w.Arquitectura)) }
    $c = $hw.CPU
    if ($c) { Write-Host ('CPU:       {0}  [{1} núcleos / {2} hilos]' -f (Format-ValorHw $c.Nombre), (Format-ValorHw $c.Nucleos), (Format-ValorHw $c.Hilos)) }
    else { Write-Host 'CPU:       desconocido' }
    $r = $hw.RAM
    Write-Host ('RAM:       ' + (Format-RamHw -Ram $r))

    if (@($hw.GPUs).Count -eq 0) { Write-Host 'GPU:       desconocido' }
    foreach ($g in @($hw.GPUs)) {
        $marcas = @()
        if ($hw.GPUPrincipal -and ($g.Nombre -eq $hw.GPUPrincipal.Nombre)) { $marcas += 'principal' }
        if ($g.EsVirtual) { $marcas += 'virtual/remota' }
        if ($g.SinDriver) { $marcas += 'SIN DRIVER' }
        if ($g.EsAntigua) { $marcas += 'antigua' }
        if ($g.SinSoporteFabricante) { $marcas += 'sin soporte activo del fabricante' }
        $fecha = 'sin fecha'; if ($g.FechaDriver) { $fecha = ('{0:yyyy-MM-dd}' -f $g.FechaDriver) }
        Write-Host ('GPU:       {0}  [driver {1}, {2}]{3}' -f $g.Nombre, (Format-ValorHw $g.DriverVersion), $fecha, $(if ($marcas.Count -gt 0) { '  <' + ($marcas -join ', ') + '>' } else { '' }))
    }

    $d = $hw.Disco
    if ($d) {
        $tipoTxt = $d.Tipo; if ($d.EsNVMe) { $tipoTxt = 'SSD NVMe' }
        Write-Host ('Disco:     {0} {1}  [{2} ({3}); {4} GB, libre {5} GB = {6} %; salud {7}]' -f $d.Unidad, (Format-ValorHw $d.Modelo), $tipoTxt, (Format-ValorHw $d.TipoOrigen), (Format-ValorHw $d.TamanoGB), (Format-ValorHw $d.LibreGB), (Format-ValorHw $d.LibrePct), (Format-ValorHw $d.Salud))
        if ($d.EsVirtual) { Write-Host '           (disco virtual: el tipo y la salud no son fiables)' -ForegroundColor DarkGray }
    }
    else { Write-Host 'Disco:     desconocido' }

    $port = 'desconocido'; if ($hw.EsPortatil -eq $true) { $port = 'sí' } elseif ($hw.EsPortatil -eq $false) { $port = 'no' }
    Write-Host ('Portátil:  {0}' -f $port)
    $ini = 'desconocido'; if ($null -ne $hw.InicioRapido) { $ini = $(if ($hw.InicioRapido) { 'activado' } else { 'desactivado' }) }
    $txtArranque = 'tiempo encendido desconocido'
    if ($null -ne $hw.ArranqueDias) { $txtArranque = ('{0} días encendido' -f $hw.ArranqueDias) }
    Write-Host ('Arranque:  {0} (inicio rápido: {1})' -f $txtArranque, $ini)
    if ($hw.ProgramasInicio) { Write-Host ('Inicio:    {0} programas habilitados ({1} deshabilitados)' -f $hw.ProgramasInicio.Habilitados, $hw.ProgramasInicio.Deshabilitados) }
    else { Write-Host 'Inicio:    desconocido' }
    $a = $hw.Administracion
    if ($a) {
        $txtAdm = 'no se pudo comprobar'
        if ($a.Administrado -eq $true) { $txtAdm = 'SÍ: ' + ($a.Bloqueantes -join '; ') } elseif ($a.Administrado -eq $false) { $txtAdm = 'no (sin dominio ni Entra ID)' }
        Write-Host ('Administrado: {0}' -f $txtAdm)
    }

    $colorPerfil = 'White'
    if ($hw.Perfil -eq 'Bajo') { $colorPerfil = 'Yellow' } elseif ($hw.Perfil -eq 'Alto') { $colorPerfil = 'Green' }
    Write-Host ''
    Write-Host ('PERFIL: {0}  ({1})' -f $hw.Perfil, $hw.PerfilMotivo) -ForegroundColor $colorPerfil

    Write-Host ''
    Write-Host '--- Recomendaciones ---' -ForegroundColor Cyan
    foreach ($rec in @($hw.Recomendaciones)) {
        $color = switch ($rec.Nivel) { 'Crítico' { 'Red' } 'Aviso' { 'Yellow' } 'Info' { 'Cyan' } default { 'Gray' } }
        Write-Host ('[{0}] {1}' -f $rec.Nivel, $rec.Titulo) -ForegroundColor $color
        Write-Host ('        {0}' -f $rec.Detalle) -ForegroundColor DarkGray
    }

    if (@(Get-Tweak).Count -gt 0) {
        Write-Host ''
        Write-Host '--- Optimizaciones recomendadas para este equipo ---' -ForegroundColor Cyan
        foreach ($t in @(Get-TweaksRecomendados -Hardware $hw)) {
            $marca = 'no recomendada'; $color = 'DarkGray'
            if ($t.Recomendado) { $marca = 'RECOMENDADA'; $color = 'Green' }
            Write-Host ('{0,-15} {1,-11} {2}' -f $marca, $t.Estado, $t.Id) -ForegroundColor $color
            if ($t.Motivo) { Write-Host ('        {0}' -f $t.Motivo) -ForegroundColor DarkGray }
        }
    }

    Write-Host ''
    if ($hw.Simulado) {
        Write-Host 'Diagnóstico simulado: no se consultó el hardware real.' -ForegroundColor Magenta
    }
    else {
        Write-Host ('Diagnóstico completado en {0:N1} s.' -f ($hw.DuracionMs / 1000)) -ForegroundColor Gray
        $consultas = @($hw.Consultas)
        $lentas = @($consultas | Sort-Object Ms -Descending | Select-Object -First 3)
        if ($lentas.Count -gt 0) { Write-Host ('Consultas más lentas: ' + (($lentas | ForEach-Object { '{0} ({1} ms)' -f $_.Nombre, $_.Ms }) -join ', ')) -ForegroundColor Gray }
        $malas = @($consultas | Where-Object { $_.Estado -ne 'Ok' })
        if ($malas.Count -gt 0) { Write-Host ('Sin datos (marcadas como desconocidas): ' + (($malas | ForEach-Object { '{0} [{1}]' -f $_.Nombre, $_.Estado }) -join ', ')) -ForegroundColor Yellow }
        if ($hw.DuracionMs -gt 10000) { Write-Host 'Aviso: el diagnóstico tardó más de 10 s (equipo lento o alguna consulta con problemas).' -ForegroundColor Yellow }
    }
    Write-Host ''
}

function Show-ResumenConsola {
    # Auxiliar interna: resumen final de una aplicación de tweaks.
    param(
        [Parameter(Mandatory)]$Lote
    )

    Write-Host ''
    Write-Host '=== Resumen ===' -ForegroundColor Cyan
    foreach ($r in $Lote.Resultados) {
        $color = switch ($r.Estado) {
            'Aplicado'   { 'Green' }
            'SinCambios' { 'Green' }
            'NoAplica'   { 'DarkGray' }
            'Parcial'    { 'Yellow' }
            default      { 'Red' }
        }
        Write-Host ('{0,-11} {1}  -  {2}' -f $r.Estado, $r.Id, $r.Detalle) -ForegroundColor $color
    }

    if ($Lote.Requiere -eq 'Reiniciar') {
        Write-Host ''
        Write-Host 'REINICIA el equipo para completar los cambios de: ' -ForegroundColor Yellow -NoNewline
        Write-Host ((@($Lote.TweaksQueRequieren | Where-Object { $_.Requiere -eq 'Reiniciar' } | ForEach-Object { $_.Id })) -join ', ') -ForegroundColor Yellow
        Write-Host '(Los servicios cambiados a Disabled siguen en ejecución hasta que reinicies.)' -ForegroundColor Yellow
    }
    elseif ($Lote.Requiere -eq 'Cerrar sesión') {
        Write-Host ''
        Write-Host 'CIERRA SESIÓN y vuelve a entrar para completar los cambios de: ' -ForegroundColor Yellow -NoNewline
        Write-Host ((@($Lote.TweaksQueRequieren | ForEach-Object { $_.Id })) -join ', ') -ForegroundColor Yellow
    }

    $s = $global:OptiLow.Journal
    if ($s -and ($s.Datos.Entradas.Count -gt 0)) {
        Write-Host ''
        Write-Host "Sesión del journal: $($s.Id). Para deshacerlo todo: OptiLow.ps1 -Deshacer" -ForegroundColor Gray
    }
    Write-Host ''
}

function Resolve-PuntoRestauracionConsola {
    # Auxiliar interna: crea el punto de restauración y, si no se puede, decide con el usuario.
    # Devuelve $true si se puede continuar. Con -SinPreguntar elige siempre la opción segura:
    # nunca activa la Protección del sistema y, si el punto falla, cancela.
    param(
        [switch]$SinPreguntar
    )

    $r = New-PuntoRestauracion -Descripcion 'OptiLow - antes de aplicar cambios'
    if ($r.Creado) { return $true }

    Write-Host ''
    Write-Host "No se creó el punto de restauración: $($r.Detalle)" -ForegroundColor Yellow

    if (@('Desactivada', 'SinEspacioAsignado') -contains $r.Motivo) {
        if ($SinPreguntar) {
            Write-Log -Nivel ERROR -Mensaje 'Con -SinPreguntar no se activa la Protección del sistema por su cuenta: se cancela. Usa -SinPuntoRestauracion para continuar sin punto.'
            return $false
        }
        Write-Host 'Puedo activar la Protección del sistema en la unidad del sistema. Ten en cuenta que USA ESPACIO EN DISCO (Windows reserva una parte de la unidad para los puntos de restauración).' -ForegroundColor Yellow
        if (Read-ConfirmacionConsola -Pregunta '¿Activar la Protección del sistema?') {
            $a = Enable-ProteccionSistema
            if ($a.Activada) {
                $r2 = New-PuntoRestauracion -Descripcion 'OptiLow - antes de aplicar cambios'
                if ($r2.Creado) { return $true }
                $r = $r2
                Write-Host "Tampoco se pudo crear el punto tras activar la protección: $($r.Detalle)" -ForegroundColor Yellow
            }
            else {
                Write-Host "No quedó activa: $($a.Detalle) (puede que haga falta asignar espacio en Propiedades del sistema > Protección del sistema > Configurar)." -ForegroundColor Yellow
            }
        }
    }

    if ($r.Motivo -eq 'YaExisteReciente') {
        $p = $r.PuntoReciente
        if ($SinPreguntar) {
            Write-Log -Nivel ERROR -Mensaje 'Con -SinPreguntar, si el punto de restauración falla se cancela. Ya existe uno reciente; usa -SinPuntoRestauracion para continuar con él.'
            return $false
        }
        Write-Host ("Ya existe un punto de restauración de las últimas 24 h: '{0}', creado el {1:yyyy-MM-dd HH:mm:ss} (número {2})." -f $p.Descripcion, $p.Fecha, $p.Secuencia) -ForegroundColor Yellow
        return (Read-ConfirmacionConsola -Pregunta '¿Continuar usando ese punto reciente como respaldo?')
    }

    if ($SinPreguntar) {
        Write-Log -Nivel ERROR -Mensaje 'Con -SinPreguntar, si el punto de restauración falla se cancela. Usa -SinPuntoRestauracion para continuar sin punto.'
        return $false
    }
    Write-Host 'Si continúas, el journal seguirá permitiendo deshacer los cambios, pero no tendrás un punto de restauración de Windows.' -ForegroundColor Yellow
    return (Read-ConfirmacionConsola -Pregunta '¿Continuar sin punto de restauración nuevo?')
}

function Invoke-AplicarConsola {
    <#
    .SYNOPSIS
        Aplica una lista de tweaks por Id desde la consola: confirmación, punto de restauración, aplicación
        (todo en UNA sesión del journal) y resumen.
    .PARAMETER SinPreguntar
        No pide confirmaciones. Usa siempre la opción segura: no activa la Protección del sistema y, si el
        punto de restauración falla, cancela (salvo que también se pase -SinPuntoRestauracion).
    .OUTPUTS
        Código de salida: 0 bien, 1 fallos o error, 2 cancelado.
    .EXAMPLE
        Invoke-AplicarConsola -Ids 'efectos-transparencia-off'
    #>
    param(
        [string[]]$Ids = @(),
        [switch]$Recomendados,
        [switch]$SinPuntoRestauracion,
        [switch]$SinPreguntar
    )

    $ids = @($Ids | Where-Object { $_ } | Select-Object -Unique)

    if ($Recomendados) {
        # Diagnóstico REAL (nunca simulado) y bloque Recomendar de cada tweak con ese objeto, mostrando el motivo
        if (-not (Get-Command -Name 'Get-Diagnostico' -ErrorAction SilentlyContinue)) {
            Write-Log -Nivel ERROR -Mensaje 'El módulo de diagnóstico (Modules/Hardware.ps1) no está cargado; no se puede usar "recomendados".'
            return 1
        }
        if ($global:OptiLow.ContainsKey('SimulacionActiva') -and $global:OptiLow.SimulacionActiva) {
            Write-Log -Nivel ERROR -Mensaje 'Con un perfil simulado no se puede aplicar nada.'
            return 1
        }
        Write-Host 'Analizando el equipo para decidir qué optimizaciones recomendar...' -ForegroundColor Cyan
        $hw = Get-Diagnostico
        $rec = @(Get-TweaksRecomendados -Hardware $hw)
        Write-Host ('Perfil del equipo: {0} ({1}). Diagnóstico en {2:N1} s.' -f $hw.Perfil, $hw.PerfilMotivo, ($hw.DuracionMs / 1000)) -ForegroundColor Gray
        Write-Host ''
        foreach ($t in $rec) {
            if ($t.Seleccionable) { $marca = 'SE APLICA'; $color = 'Green' }
            elseif ($t.Recomendado) { $marca = 'ya aplicada'; $color = 'DarkGray' }
            else { $marca = 'no recomendada'; $color = 'DarkGray' }
            Write-Host ('  {0,-15} {1,-11} {2}' -f $marca, $t.Estado, $t.Id) -ForegroundColor $color
            if ($t.Motivo) { Write-Host ('      Por qué: {0}' -f $t.Motivo) -ForegroundColor Gray }
        }
        $ids = @($ids + @($rec | Where-Object { $_.Seleccionable } | ForEach-Object { $_.Id }) | Select-Object -Unique)
        if ($ids.Count -eq 0) {
            Write-Host ''
            Write-Host 'No hay optimizaciones recomendadas pendientes para este equipo.'
            return 0
        }
        Write-Host ''
    }

    $desconocidos = @($ids | Where-Object { -not (Get-Tweak -Id $_) })
    if ($desconocidos.Count -gt 0) {
        Write-Log -Nivel ERROR -Mensaje "No existen estas optimizaciones: $($desconocidos -join ', '). Usa -Listar para ver las disponibles. No se aplicó nada."
        return 1
    }

    try { Assert-JournalListo -Completo }
    catch {
        Write-Log -Nivel ERROR -Mensaje $_.Exception.Message
        return 1
    }

    # Estado actual de cada una
    $pendientes = New-Object System.Collections.ArrayList
    foreach ($id in $ids) {
        $estado = Get-TweakEstado -Id $id
        if (@('Aplicado', 'NoAplica') -contains $estado.Estado) {
            Write-Host ("  {0,-10} {1}" -f $estado.Estado, $id) -ForegroundColor DarkGray
        }
        else {
            [void]$pendientes.Add((Get-Tweak -Id $id))
        }
    }
    if ($pendientes.Count -eq 0) {
        Write-Host 'No hay nada que aplicar: todo está ya aplicado o no aplica en este equipo.'
        return 0
    }

    # Confirmación con la lista de cambios y advertencias
    Write-Host ''
    Write-Host 'Se van a aplicar estas optimizaciones:' -ForegroundColor Cyan
    foreach ($t in $pendientes) {
        Write-Host ("  - {0} [{1}]  Riesgo: {2}  Requiere: {3}" -f $t.Nombre, $t.Id, $t.Riesgo, $t.Requiere)
        Write-Host ("      {0}" -f $t.Descripcion) -ForegroundColor Gray
    }
    $graves = @($pendientes | Where-Object { ($_.Riesgo -eq 'Alto') -or (-not $_.Reversible) })
    if ($graves.Count -gt 0) {
        Write-Host ''
        Write-Host 'ATENCIÓN: estas optimizaciones son de riesgo ALTO o NO se pueden deshacer desde el journal:' -ForegroundColor Red
        foreach ($t in $graves) {
            $motivos = @()
            if ($t.Riesgo -eq 'Alto') { $motivos += 'riesgo Alto' }
            if (-not $t.Reversible) { $motivos += 'no reversible' }
            Write-Host ("  ! {0} [{1}]: {2}" -f $t.Nombre, $t.Id, ($motivos -join ', ')) -ForegroundColor Red
        }
    }
    Write-Host ''
    if (-not $SinPreguntar) {
        if (-not (Read-ConfirmacionConsola -Pregunta '¿Aplicar estos cambios?')) {
            Write-Host 'Cancelado. No se aplicó nada.'
            return 2
        }
    }

    # Una ejecución = una sesión del journal (incluido el ajuste temporal del punto de restauración)
    [void](Start-JournalSesion -Nueva)

    if ($SinPuntoRestauracion) {
        Write-Log -Nivel WARN -Mensaje 'Se omite el punto de restauración (-SinPuntoRestauracion): solo el journal permitirá deshacer.'
    }
    else {
        if (-not (Resolve-PuntoRestauracionConsola -SinPreguntar:$SinPreguntar)) {
            Write-Host 'Cancelado. No se aplicó nada.'
            return 2
        }
    }

    $lote = Invoke-TweaksLote -Ids @($pendientes | ForEach-Object { $_.Id })
    Show-ResumenConsola -Lote $lote

    $malos = @($lote.Resultados | Where-Object { @('Fallido', 'Parcial') -contains $_.Estado })
    if ($malos.Count -gt 0) { return 1 }
    return 0
}

function Invoke-DeshacerConsola {
    <#
    .SYNOPSIS
        Deshace una sesión del journal desde la consola (por defecto, la última que no esté restaurada).
    .OUTPUTS
        Código de salida: 0 bien (o nada que deshacer), 1 restauración parcial o error, 2 cancelado.
    .EXAMPLE
        Invoke-DeshacerConsola
    #>
    param(
        [string]$Sesion,
        [switch]$SinPreguntar
    )

    try { Assert-JournalListo -Completo }
    catch {
        Write-Log -Nivel ERROR -Mensaje $_.Exception.Message
        return 1
    }

    if ($Sesion) {
        $objetivo = Get-JournalSesiones | Where-Object { $_.Id -eq $Sesion } | Select-Object -First 1
        if (-not $objetivo) {
            Write-Log -Nivel ERROR -Mensaje "No existe la sesión '$Sesion'. Usa -ListarSesiones para ver las disponibles."
            return 1
        }
    }
    else {
        $objetivo = Get-JournalSesiones | Where-Object { ($_.Estado -ne 'Restaurado') -and ($_.Entradas -gt 0) } | Select-Object -First 1
        if (-not $objetivo) {
            Write-Host 'No hay ninguna sesión pendiente de deshacer.'
            return 0
        }
    }
    if ($objetivo.Estado -eq 'Restaurado') {
        Write-Host "La sesión $($objetivo.Id) ya estaba restaurada."
        return 0
    }

    Write-Host ''
    Write-Host "Se va a deshacer la sesión $($objetivo.Id) (iniciada $($objetivo.Inicio), estado $($objetivo.Estado), $($objetivo.Entradas) entradas)." -ForegroundColor Cyan
    if (@($objetivo.Tweaks).Count -gt 0) { Write-Host "Optimizaciones de esa sesión: $(@($objetivo.Tweaks) -join ', ')" }
    if (-not $SinPreguntar) {
        if (-not (Read-ConfirmacionConsola -Pregunta '¿Deshacer esa sesión?')) {
            Write-Host 'Cancelado. No se deshizo nada.'
            return 2
        }
    }

    try {
        $r = Undo-JournalSesion -Id $objetivo.Id
    }
    catch {
        Write-Log -Nivel ERROR -Mensaje $_.Exception.Message
        return 1
    }
    if ($r -and ($r.Estado -eq 'RestauradoParcial')) {
        Write-Host ''
        Write-Host 'Restauración PARCIAL. Entradas que fallaron:' -ForegroundColor Yellow
        foreach ($f in $r.Fallidas) { Write-Host ("  {0} ({1}): {2}" -f $f.Descripcion, $f.Tipo, $f.Error) -ForegroundColor Yellow }
        return 1
    }
    return 0
}
