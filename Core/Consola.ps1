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
        [Parameter(Mandatory)][string[]]$Ids,
        [switch]$SinPuntoRestauracion,
        [switch]$SinPreguntar
    )

    $ids = @($Ids | Where-Object { $_ } | Select-Object -Unique)
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
