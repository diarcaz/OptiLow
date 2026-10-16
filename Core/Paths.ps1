# Core/Paths.ps1
# Rutas base del programa y estado global compartido ($global:OptiLow).
# No depende de ningún otro archivo (se carga primero).

function Test-DirectorioEscribible {
    <#
    .SYNOPSIS
        Crea la carpeta si no existe y comprueba que se pueda escribir en ella.
    #>
    param(
        [Parameter(Mandatory)][string]$Ruta
    )

    try {
        if (-not (Test-Path -LiteralPath $Ruta)) {
            New-Item -ItemType Directory -Path $Ruta -Force -ErrorAction Stop | Out-Null
        }
        $sonda = Join-Path $Ruta ('.sonda_' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($sonda, 'x')
        Remove-Item -LiteralPath $sonda -Force -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Initialize-OptiLowRutas {
    <#
    .SYNOPSIS
        Calcula las rutas del programa y crea el estado global $global:OptiLow.
    .DESCRIPTION
        Datos en tiempo de ejecución (logs y respaldos) van en %ProgramData%\OptiLow\,
        nunca dentro de la carpeta del programa.
        Si no se puede escribir en la carpeta de logs, se usa %TEMP%\OptiLow\logs como
        respaldo; el aviso se guarda en Avisos y lo emite Initialize-OptiLowLog.
        La carpeta de respaldos NO se crea aquí (ver Initialize-CarpetaRespaldos): DirRespaldos queda
        en $null y RutaRespaldos con la ruta prevista. No se usa %TEMP% para respaldos porque es volátil.
    #>
    param(
        [Parameter(Mandatory)][string]$Raiz
    )

    if ($global:OptiLow -isnot [hashtable]) {
        $global:OptiLow = @{}
    }
    $e = $global:OptiLow

    $e.Raiz         = $Raiz
    # Path.Combine y no Join-Path: este último falla si la unidad no existe.
    $e.DirDatos     = [System.IO.Path]::Combine($env:ProgramData, 'OptiLow')
    $e.Avisos       = New-Object System.Collections.ArrayList
    if (-not $e.ContainsKey('ColaLog'))    { $e.ColaLog    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]' }
    if (-not $e.ContainsKey('LogDestino')) { $e.LogDestino = 'Consola' }
    if (-not $e.ContainsKey('Depurar'))    { $e.Depurar    = $false }

    # Logs: ProgramData, con respaldo en %TEMP%
    $dirLogs = [System.IO.Path]::Combine($e.DirDatos, 'logs')
    if (-not (Test-DirectorioEscribible -Ruta $dirLogs)) {
        $dirLogsTemp = [System.IO.Path]::Combine($env:TEMP, 'OptiLow', 'logs')
        if (Test-DirectorioEscribible -Ruta $dirLogsTemp) {
            [void]$e.Avisos.Add(@('WARN', "No se puede escribir en '$dirLogs'. Los logs se guardarán en '$dirLogsTemp'."))
            $dirLogs = $dirLogsTemp
        }
        else {
            [void]$e.Avisos.Add(@('ERROR', "No se puede escribir en '$dirLogs' ni en '$dirLogsTemp'. No se guardará log en archivo."))
            $dirLogs = $null
        }
    }
    $e.DirLogs = $dirLogs

    # Respaldos (journal): aquí solo se calcula la ruta. La carpeta la crea y protege
    # Initialize-CarpetaRespaldos (Core/Seguridad.ps1), únicamente con permisos de administrador.
    # DirRespaldos queda en $null hasta que esa función termine bien; sin él no se aplica ningún cambio.
    $e.RutaRespaldos = [System.IO.Path]::Combine($e.DirDatos, 'backups')
    $e.DirRespaldos  = $null
}
