# Core/Tareas.ps1
# Desactivar tareas programadas con respaldo automático (journal).
# Si la tarea no existe en esta versión de Windows, se omite sin error ('NoAplica').
# Devuelve: Cambiado, SinCambios, NoAplica o Fallido.

function Format-TareaRuta {
    # Auxiliar interna: asegura barra inicial y final en la ruta de la tarea (\Microsoft\Windows\X\).
    param(
        [Parameter(Mandatory)][string]$Ruta
    )
    $r = $Ruta.Trim()
    if (-not $r.StartsWith('\')) { $r = '\' + $r }
    if (-not $r.EndsWith('\')) { $r = $r + '\' }
    return $r
}

function Get-TareaEstado {
    <#
    .SYNOPSIS
        Lee si una tarea programada existe y está habilitada, sin modificar nada.
    .EXAMPLE
        Get-TareaEstado -Ruta '\Microsoft\Windows\Application Experience\' -Nombre 'Microsoft Compatibility Appraiser'
    #>
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [Parameter(Mandatory)][string]$Nombre
    )

    $rutaTarea = Format-TareaRuta -Ruta $Ruta
    $tarea = Get-ScheduledTask -TaskPath $rutaTarea -TaskName $Nombre -ErrorAction SilentlyContinue
    if (-not $tarea) {
        return [pscustomobject]@{ Existe = $false; Habilitada = $null; Ruta = $rutaTarea }
    }
    return [pscustomobject]@{ Existe = $true; Habilitada = [bool]$tarea.Settings.Enabled; Ruta = $rutaTarea }
}

function Disable-TareaProgramada {
    <#
    .SYNOPSIS
        Desactiva una tarea programada, guardando en el journal si estaba habilitada.
    .OUTPUTS
        'Cambiado', 'SinCambios' (ya estaba desactivada), 'NoAplica' (no existe) o 'Fallido'.
    .EXAMPLE
        Disable-TareaProgramada -Ruta '\Microsoft\Windows\Application Experience\' -Nombre 'ProgramDataUpdater'
    #>
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [Parameter(Mandatory)][string]$Nombre
    )

    Assert-JournalListo

    $estado = Get-TareaEstado -Ruta $Ruta -Nombre $Nombre
    $etiqueta = '{0}{1}' -f $estado.Ruta, $Nombre
    if (-not $estado.Existe) {
        Write-Log -Nivel INFO -Mensaje "Tarea '$etiqueta': no existe en este equipo; no aplica."
        return 'NoAplica'
    }
    if (-not $estado.Habilitada) {
        Write-Log -Nivel DEBUG -Mensaje "Tarea '$etiqueta': ya estaba desactivada."
        return 'SinCambios'
    }

    $entrada = [ordered]@{
        Tipo                = 'Tarea'
        Descripcion         = "Tarea $etiqueta"
        Ruta                = $estado.Ruta
        Nombre              = $Nombre
        HabilitadaOriginal  = $true
    }
    $registro = Add-JournalEntrada -Entrada $entrada

    try {
        [void](Disable-ScheduledTask -TaskPath $estado.Ruta -TaskName $Nombre -ErrorAction Stop)
        $despues = Get-TareaEstado -Ruta $estado.Ruta -Nombre $Nombre
        if ($despues.Habilitada) { throw 'La tarea sigue habilitada después de desactivarla.' }
        Set-JournalEntradaEstado -Entrada $registro -Estado Aplicada
        Write-Log -Nivel OK -Mensaje "Tarea '$etiqueta': habilitada -> desactivada"
        return 'Cambiado'
    }
    catch {
        $mensajeError = $_.Exception.Message
        Write-Log -Nivel ERROR -Mensaje "Tarea '$etiqueta': no se pudo desactivar: $mensajeError"
        # Si la tarea sigue habilitada, no se tocó nada y el cambio no debe quedar en el journal
        $sigueHabilitada = $false
        try { $sigueHabilitada = (Get-TareaEstado -Ruta $estado.Ruta -Nombre $Nombre).Habilitada } catch { }
        if ($sigueHabilitada) {
            Remove-JournalEntrada -Entrada $registro
        }
        else {
            Set-JournalEntradaEstado -Entrada $registro -Estado Fallida -Detalle $mensajeError
        }
        return 'Fallido'
    }
}

function Restore-TareaEntrada {
    # Restaura una entrada de tipo Tarea. Lanza una excepción si falla. No escribe en el journal.
    param(
        [Parameter(Mandatory)]$Entrada
    )

    $estado = Get-TareaEstado -Ruta $Entrada.Ruta -Nombre $Entrada.Nombre
    if (-not $estado.Existe) {
        throw "La tarea '$($Entrada.Ruta)$($Entrada.Nombre)' ya no existe."
    }
    if ($Entrada.HabilitadaOriginal -eq $true) {
        if (-not $estado.Habilitada) {
            [void](Enable-ScheduledTask -TaskPath $estado.Ruta -TaskName $Entrada.Nombre -ErrorAction Stop)
        }
        Write-Log -Nivel OK -Mensaje "Restaurado: tarea '$($Entrada.Ruta)$($Entrada.Nombre)' -> habilitada"
    }
}
