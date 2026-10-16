# Core/Logging.ps1
# Registro de mensajes. Formato: [HH:mm:ss] [NIVEL] mensaje
# Niveles: INFO, OK, WARN, ERROR, DEBUG.
# Destino en pantalla: consola (con colores) o cola compartida (modo interfaz).
# Siempre se escribe también en un archivo diario, con bloqueo (mutex) porque
# escriben dos hilos (interfaz y runspace de trabajo).

function Initialize-OptiLowLog {
    <#
    .SYNOPSIS
        Fija el destino del log y emite los avisos acumulados por Initialize-OptiLowRutas.
    .PARAMETER Destino
        Consola: pantalla con colores. Cola: cola compartida ($global:OptiLow.ColaLog) para la interfaz.
    #>
    param(
        [ValidateSet('Consola', 'Cola')][string]$Destino = 'Consola'
    )

    $e = $global:OptiLow
    $e.LogDestino = $Destino

    if ($e.Avisos -and $e.Avisos.Count -gt 0) {
        foreach ($aviso in @($e.Avisos)) {
            Write-Log -Nivel $aviso[0] -Mensaje $aviso[1]
        }
        $e.Avisos.Clear()
    }
}

function Write-LogArchivo {
    # Auxiliar interna: agrega una línea al archivo de log del día, con bloqueo.
    param(
        [Parameter(Mandatory)][string]$Linea
    )

    $e = $global:OptiLow
    if (-not $e -or -not $e.DirLogs) { return }

    $mutex = $null
    $tomado = $false
    try {
        $ruta = Join-Path $e.DirLogs ('OptiLow_{0:yyyy-MM-dd}.log' -f (Get-Date))
        $mutex = New-Object System.Threading.Mutex($false, 'OptiLow_LogMutex')
        try {
            $tomado = $mutex.WaitOne(3000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $tomado = $true
        }
        # UTF-8 con BOM: solo se escribe al crear el archivo; así el Bloc de notas lo lee bien.
        $codificacion = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::AppendAllText($ruta, $Linea + "`r`n", $codificacion)
    }
    catch {
        if (-not $e.ErrorLogAvisado) {
            $e.ErrorLogAvisado = $true
            Write-Host "[AVISO] No se pudo escribir en el archivo de log: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    finally {
        if ($mutex) {
            if ($tomado) { try { $mutex.ReleaseMutex() } catch { } }
            $mutex.Dispose()
        }
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Registra un mensaje en el archivo de log y en la pantalla (o la cola de la interfaz).
    #>
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Mensaje,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DEBUG')][string]$Nivel = 'INFO'
    )

    $e = $global:OptiLow
    if ($Nivel -eq 'DEBUG' -and -not ($e -and $e.Depurar)) { return }

    $linea = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Nivel, $Mensaje

    Write-LogArchivo -Linea $linea

    if ($e -and $e.LogDestino -eq 'Cola' -and $e.ColaLog) {
        $e.ColaLog.Enqueue($linea)
    }
    else {
        $color = switch ($Nivel) {
            'OK'    { 'Green' }
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
            'DEBUG' { 'DarkGray' }
            default { 'Gray' }
        }
        Write-Host $linea -ForegroundColor $color
    }
}
