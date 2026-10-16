# Core/Energia.ps1
# Plan de energía con respaldo automático (journal), usando powercfg.exe.
# Si el plan no existe (común en portátiles con Modern Standby), avisa y devuelve 'NoAplica':
# no falla en silencio y no crea planes.
# Devuelve: Cambiado, SinCambios, NoAplica o Fallido.

function Get-PlanesEnergia {
    <#
    .SYNOPSIS
        Lista los planes de energía del equipo (Guid, Nombre, Activo).
    .EXAMPLE
        Get-PlanesEnergia | Format-Table
    #>
    $patron = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*\((.*?)\)\s*(\*)?'
    $salida = & powercfg.exe /list
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /list devolvió el código $LASTEXITCODE."
    }
    $planes = New-Object System.Collections.ArrayList
    foreach ($linea in @($salida)) {
        if ($linea -match $patron) {
            [void]$planes.Add([pscustomobject]@{
                    Guid   = $Matches[1].ToLowerInvariant()
                    Nombre = $Matches[2]
                    Activo = [bool]$Matches[3]
                })
        }
    }
    return @($planes)
}

function Get-PlanEnergiaActivo {
    <#
    .SYNOPSIS
        Devuelve el plan de energía activo (Guid, Nombre).
    .EXAMPLE
        Get-PlanEnergiaActivo
    #>
    $activo = Get-PlanesEnergia | Where-Object { $_.Activo } | Select-Object -First 1
    if (-not $activo) { throw 'No se pudo determinar el plan de energía activo.' }
    return $activo
}

function Set-PlanEnergia {
    <#
    .SYNOPSIS
        Activa un plan de energía existente, guardando el activo anterior en el journal.
    .PARAMETER Guid
        GUID del plan (ver Get-PlanesEnergia).
    .OUTPUTS
        'Cambiado', 'SinCambios' (ya estaba activo), 'NoAplica' (el plan no existe) o 'Fallido'.
    .EXAMPLE
        Set-PlanEnergia -Guid '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    #>
    param(
        [Parameter(Mandatory)][string]$Guid
    )

    Assert-JournalListo

    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Guid, [ref]$parsed)) {
        Write-Log -Nivel ERROR -Mensaje "Plan de energía: '$Guid' no es un GUID válido."
        return 'Fallido'
    }
    $guidTexto = $parsed.ToString().ToLowerInvariant()

    try {
        $planes = @(Get-PlanesEnergia)
    }
    catch {
        Write-Log -Nivel ERROR -Mensaje "Plan de energía: no se pudo leer la lista de planes: $($_.Exception.Message)"
        return 'Fallido'
    }

    $destino = $planes | Where-Object { $_.Guid -eq $guidTexto } | Select-Object -First 1
    if (-not $destino) {
        Write-Log -Nivel WARN -Mensaje "Plan de energía ${guidTexto}: no existe en este equipo (común en portátiles con Modern Standby); no se cambia."
        return 'NoAplica'
    }
    $original = $planes | Where-Object { $_.Activo } | Select-Object -First 1
    if ($original -and ($original.Guid -eq $guidTexto)) {
        Write-Log -Nivel DEBUG -Mensaje "Plan de energía: '$($destino.Nombre)' ya está activo."
        return 'SinCambios'
    }
    if (-not $original) {
        Write-Log -Nivel ERROR -Mensaje 'Plan de energía: no se pudo determinar el plan activo actual; no se cambia (no se podría deshacer).'
        return 'Fallido'
    }

    $entrada = [ordered]@{
        Tipo           = 'PlanEnergia'
        Descripcion    = "Plan de energía $($original.Nombre) -> $($destino.Nombre)"
        GuidOriginal   = $original.Guid
        NombreOriginal = $original.Nombre
        GuidNuevo      = $guidTexto
    }
    $registro = Add-JournalEntrada -Entrada $entrada

    [void](& powercfg.exe /setactive $guidTexto)
    if ($LASTEXITCODE -ne 0) {
        Write-Log -Nivel ERROR -Mensaje "Plan de energía: powercfg /setactive devolvió el código $LASTEXITCODE al activar '$($destino.Nombre)'."
        # powercfg falló sin cambiar el plan: el cambio no debe quedar en el journal
        Remove-JournalEntrada -Entrada $registro
        return 'Fallido'
    }
    Set-JournalEntradaEstado -Entrada $registro -Estado Aplicada
    Write-Log -Nivel OK -Mensaje "Plan de energía: '$($original.Nombre)' -> '$($destino.Nombre)'"
    return 'Cambiado'
}

function Restore-PlanEnergiaEntrada {
    # Restaura una entrada de tipo PlanEnergia. Lanza una excepción si falla. No escribe en el journal.
    param(
        [Parameter(Mandatory)]$Entrada
    )

    $planes = @(Get-PlanesEnergia)
    $original = $planes | Where-Object { $_.Guid -eq $Entrada.GuidOriginal } | Select-Object -First 1
    if (-not $original) {
        throw "El plan de energía original '$($Entrada.NombreOriginal)' ($($Entrada.GuidOriginal)) ya no existe."
    }
    if ($original.Activo) {
        Write-Log -Nivel OK -Mensaje "Restaurado: el plan '$($original.Nombre)' ya estaba activo."
        return
    }
    [void](& powercfg.exe /setactive $Entrada.GuidOriginal)
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /setactive devolvió el código $LASTEXITCODE al restaurar '$($original.Nombre)'."
    }
    Write-Log -Nivel OK -Mensaje "Restaurado: plan de energía -> '$($original.Nombre)'"
}
