# Core/Servicios.ps1
# Cambio del tipo de inicio de servicios con respaldo automático (journal).
#
# - Usa sc.exe config (no 'sc', que en PowerShell es un alias de Set-Content) y comprueba el código de salida.
#   No se redirige stderr de programas nativos con 2>&1 (problemas en Windows PowerShell 5.1).
# - El estado original (Start y DelayedAutostart) se lee de HKLM\SYSTEM\CurrentControlSet\Services\<nombre>,
#   así se restaura incluso el inicio automático retrasado.
# - Solo cambia el tipo de inicio: no detiene ni inicia el servicio.
# - Si sc.exe devuelve acceso denegado (servicio protegido), se registra un fallo claro con el nombre del
#   servicio y se devuelve 'Fallido' sin detener lo demás.
#
# Devuelve: Cambiado, SinCambios, NoAplica (el servicio no existe) o Fallido.

function Get-ServicioEstado {
    <#
    .SYNOPSIS
        Lee el tipo de inicio de un servicio desde el registro, sin modificar nada.
    .OUTPUTS
        Existe, Inicio (Automatic, AutomaticDelayed, Manual, Disabled, Boot, System), Start,
        Delayed (valor de DelayedAutostart, o $null si no existe) y Tipo (valor Type).
    .EXAMPLE
        Get-ServicioEstado -Nombre 'DiagTrack'
    #>
    param(
        [Parameter(Mandatory)][string]$Nombre
    )

    if ($Nombre -match '[\\/]') {
        throw "Nombre de servicio no válido: '$Nombre'."
    }

    $base = Open-RegistroBase -Hive ([Microsoft.Win32.RegistryHive]::LocalMachine)
    try {
        $k = $base.OpenSubKey("SYSTEM\CurrentControlSet\Services\$Nombre", $false)
        if (-not $k) {
            return [pscustomobject]@{ Existe = $false; Inicio = $null; Start = $null; Delayed = $null; Tipo = $null }
        }
        try {
            $start = $k.GetValue('Start', $null)
            $tipo = $k.GetValue('Type', $null)
            $delayed = $null
            if (@($k.GetValueNames()) -contains 'DelayedAutostart') { $delayed = [int]$k.GetValue('DelayedAutostart') }

            $inicio = switch ([int]$start) {
                0 { 'Boot' }
                1 { 'System' }
                2 { if ($delayed -eq 1) { 'AutomaticDelayed' } else { 'Automatic' } }
                3 { 'Manual' }
                4 { 'Disabled' }
                default { 'Desconocido' }
            }
            return [pscustomobject]@{ Existe = $true; Inicio = $inicio; Start = [int]$start; Delayed = $delayed; Tipo = $tipo }
        }
        finally { $k.Dispose() }
    }
    finally { $base.Dispose() }
}

function ConvertTo-ServicioArgSc {
    # Auxiliar interna: tipo de inicio -> valor de start= de sc.exe.
    param(
        [Parameter(Mandatory)][string]$Inicio
    )
    switch ($Inicio) {
        'Automatic'        { return 'auto' }
        'AutomaticDelayed' { return 'delayed-auto' }
        'Manual'           { return 'demand' }
        'Disabled'         { return 'disabled' }
        default            { throw "Tipo de inicio no soportado: '$Inicio'." }
    }
}

function Invoke-ScConfigInicio {
    # Auxiliar interna: ejecuta 'sc.exe config <nombre> start= <valor>'. Devuelve código y salida.
    param(
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)][string]$ValorSc
    )
    $salida = & sc.exe config $Nombre start= $ValorSc
    return [pscustomobject]@{ Codigo = $LASTEXITCODE; Salida = (@($salida) -join ' ').Trim() }
}

function Set-ServicioInicio {
    <#
    .SYNOPSIS
        Cambia el tipo de inicio de un servicio, con respaldo del estado original en el journal.
    .PARAMETER Inicio
        Automatic, AutomaticDelayed, Manual o Disabled.
    .OUTPUTS
        'Cambiado', 'SinCambios', 'NoAplica' (no existe) o 'Fallido' (p. ej. acceso denegado).
    .EXAMPLE
        Set-ServicioInicio -Nombre 'DiagTrack' -Inicio Disabled
    .EXAMPLE
        Set-ServicioInicio -Nombre 'SysMain' -Inicio Manual
    #>
    param(
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)][ValidateSet('Automatic', 'AutomaticDelayed', 'Manual', 'Disabled')][string]$Inicio
    )

    Assert-JournalListo

    try { $actual = Get-ServicioEstado -Nombre $Nombre }
    catch {
        Write-Log -Nivel ERROR -Mensaje "Servicio '$Nombre': $($_.Exception.Message)"
        return 'Fallido'
    }
    if (-not $actual.Existe) {
        Write-Log -Nivel INFO -Mensaje "Servicio '$Nombre': no existe en este equipo; no aplica."
        return 'NoAplica'
    }
    # Tipos 1 y 2 = controladores de núcleo / sistema de archivos; 8 = adaptador. Solo servicios de usuario.
    if (($actual.Tipo -band 0x0B) -ne 0) {
        Write-Log -Nivel ERROR -Mensaje "Servicio '$Nombre': es un controlador (Type=$($actual.Tipo)), no un servicio; no se modifica."
        return 'Fallido'
    }
    if ($actual.Inicio -eq $Inicio) {
        Write-Log -Nivel DEBUG -Mensaje "Servicio '$Nombre': ya está en $Inicio."
        return 'SinCambios'
    }

    $entrada = [ordered]@{
        Tipo             = 'Servicio'
        Descripcion      = "Servicio $Nombre"
        Nombre           = $Nombre
        StartOriginal    = $actual.Start
        DelayedOriginal  = $actual.Delayed
        InicioOriginal   = $actual.Inicio
        InicioNuevo      = $Inicio
    }
    $registro = Add-JournalEntrada -Entrada $entrada

    $resultado = Invoke-ScConfigInicio -Nombre $Nombre -ValorSc (ConvertTo-ServicioArgSc -Inicio $Inicio)
    if ($resultado.Codigo -ne 0) {
        $motivo = "sc.exe devolvió el código $($resultado.Codigo). $($resultado.Salida)"
        if ($resultado.Codigo -eq 5) {
            $motivo = "Acceso denegado (el servicio está protegido por Windows). $($resultado.Salida)"
        }
        Set-JournalEntradaEstado -Entrada $registro -Estado Fallida -Detalle $motivo
        Write-Log -Nivel ERROR -Mensaje "Servicio '$Nombre': no se pudo cambiar a $Inicio. $motivo"
        return 'Fallido'
    }

    # Verificar el resultado leyendo el registro
    $despues = Get-ServicioEstado -Nombre $Nombre
    if ($despues.Inicio -ne $Inicio) {
        $motivo = "sc.exe terminó bien pero el servicio quedó en '$($despues.Inicio)' (Start=$($despues.Start), DelayedAutostart=$($despues.Delayed)) en vez de '$Inicio'."
        Set-JournalEntradaEstado -Entrada $registro -Estado Fallida -Detalle $motivo
        Write-Log -Nivel ERROR -Mensaje "Servicio '$Nombre': $motivo"
        return 'Fallido'
    }

    Set-JournalEntradaEstado -Entrada $registro -Estado Aplicada
    Write-Log -Nivel OK -Mensaje "Servicio '$Nombre': inicio $($actual.Inicio) -> $Inicio (el servicio en ejecución no se detiene)."
    return 'Cambiado'
}

function Restore-ServicioEntrada {
    # Restaura una entrada de tipo Servicio. Lanza una excepción si falla. No escribe en el journal.
    param(
        [Parameter(Mandatory)]$Entrada
    )

    $nombre = [string]$Entrada.Nombre
    $actual = Get-ServicioEstado -Nombre $nombre
    if (-not $actual.Existe) {
        throw "El servicio '$nombre' ya no existe."
    }

    $inicio = switch ([int]$Entrada.StartOriginal) {
        2 { if ($Entrada.DelayedOriginal -eq 1) { 'AutomaticDelayed' } else { 'Automatic' } }
        3 { 'Manual' }
        4 { 'Disabled' }
        default { throw "El servicio '$nombre' tenía un tipo de inicio original no restaurable (Start=$($Entrada.StartOriginal))." }
    }

    if ($actual.Inicio -eq $inicio) {
        Write-Log -Nivel OK -Mensaje "Restaurado: servicio '$nombre' ya estaba en $inicio."
        return
    }

    $resultado = Invoke-ScConfigInicio -Nombre $nombre -ValorSc (ConvertTo-ServicioArgSc -Inicio $inicio)
    if ($resultado.Codigo -ne 0) {
        if ($resultado.Codigo -eq 5) { throw "Acceso denegado al restaurar el servicio '$nombre'. $($resultado.Salida)" }
        throw "sc.exe devolvió el código $($resultado.Codigo) al restaurar el servicio '$nombre'. $($resultado.Salida)"
    }
    $despues = Get-ServicioEstado -Nombre $nombre
    if ($despues.Inicio -ne $inicio) {
        throw "El servicio '$nombre' quedó en '$($despues.Inicio)' en vez de '$inicio' (Start=$($despues.Start), DelayedAutostart=$($despues.Delayed))."
    }
    Write-Log -Nivel OK -Mensaje "Restaurado: servicio '$nombre' -> $inicio"
}
