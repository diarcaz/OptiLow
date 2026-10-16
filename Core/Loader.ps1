# Core/Loader.ps1
# Cargador único del proyecto. Se carga con dot-source:   . .\Core\Loader.ps1
# y define las funciones Import-OptiLow* (en ámbito global).
#
# Reglas:
#   - Core/ se carga en el orden fijo de $global:OptiLowOrdenCore (no alfabético).
#     Un fallo en Core/ es FATAL (lanza una excepción con un mensaje claro).
#   - Modules/ y Tweaks/ toleran fallos: se registran en el log y se sigue.
#   - Los archivos de Modules/ y Tweaks/ que empiezan con "_" (plantillas) no se cargan.
#   - Las funciones de cada archivo se promueven al ámbito global, para que no
#     desaparezcan aunque la carga ocurra dentro de una función (p. ej. en el runspace
#     de la interfaz, que usa este mismo cargador).
#
# Para agregar un archivo nuevo a Core/: añadirlo a $global:OptiLowOrdenCore en el lugar
# que corresponda, y sus funciones públicas a $global:OptiLowFuncionesCore.

# Orden fijo de carga de Core/ (Paths antes que Logging).
$global:OptiLowOrdenCore = @(
    'Paths.ps1'
    'Logging.ps1'
    'Admin.ps1'
)

# Funciones que deben existir tras cargar Core/ (verificación).
$global:OptiLowFuncionesCore = @(
    'Test-DirectorioEscribible', 'Initialize-OptiLowRutas'
    'Initialize-OptiLowLog', 'Write-Log'
    'Test-EsAdministrador', 'Invoke-RelanzarComoAdministrador', 'Test-EsCancelacionUAC', 'Test-EscritorioDeOtroUsuario'
)

function global:Import-OptiLowArchivo {
    <#
    .SYNOPSIS
        Carga un .ps1 con dot-source y promueve al ámbito global las funciones que defina.
    #>
    param(
        [Parameter(Mandatory)][string]$Ruta
    )

    $ErrorActionPreference = 'Stop'

    $olAntes = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($olF in (Get-ChildItem -Path 'Function:\')) { [void]$olAntes.Add($olF.Name) }

    . $Ruta

    foreach ($olF in (Get-ChildItem -Path 'Function:\')) {
        if (-not $olAntes.Contains($olF.Name)) {
            Set-Item -Path ('Function:\global:' + $olF.Name) -Value $olF.ScriptBlock
        }
    }
}

function global:Import-OptiLowCore {
    <#
    .SYNOPSIS
        Carga Core/ en el orden fijo. Lanza una excepción si algo falla (fatal).
    #>
    param(
        [Parameter(Mandatory)][string]$Raiz
    )

    $dirCore = Join-Path $Raiz 'Core'
    foreach ($nombre in $global:OptiLowOrdenCore) {
        $ruta = Join-Path $dirCore $nombre
        if (-not (Test-Path -LiteralPath $ruta)) {
            throw "Falta el archivo obligatorio 'Core\$nombre'. El programa no puede continuar."
        }
        try {
            Import-OptiLowArchivo -Ruta $ruta
        }
        catch {
            throw "Error fatal al cargar 'Core\$nombre': $($_.Exception.Message)"
        }
    }

    foreach ($funcion in $global:OptiLowFuncionesCore) {
        if (-not (Test-Path -LiteralPath ('Function:\global:' + $funcion))) {
            throw "Tras cargar Core/ no existe la función '$funcion'. El programa no puede continuar."
        }
    }
}

function global:Import-OptiLowExtras {
    <#
    .SYNOPSIS
        Carga Modules/ y Tweaks/ tolerando fallos (requiere el log ya inicializado).
    .OUTPUTS
        Objeto con la cantidad de archivos cargados y fallidos.
    #>
    param(
        [Parameter(Mandatory)][string]$Raiz
    )

    # Aviso si hay archivos en Core/ que no están en el orden declarado
    $dirCore = Join-Path $Raiz 'Core'
    foreach ($archivo in (Get-ChildItem -Path $dirCore -Filter '*.ps1' -File)) {
        if (($global:OptiLowOrdenCore -notcontains $archivo.Name) -and ($archivo.Name -ne 'Loader.ps1')) {
            Write-Log -Nivel WARN -Mensaje "Core\$($archivo.Name) no está en el orden de carga declarado en Loader.ps1; no se cargó."
        }
    }

    $cargados = 0
    $fallidos = 0
    foreach ($carpeta in @('Modules', 'Tweaks')) {
        $dir = Join-Path $Raiz $carpeta
        if (-not (Test-Path -LiteralPath $dir)) { continue }

        $archivos = Get-ChildItem -Path $dir -Filter '*.ps1' -File | Sort-Object Name
        foreach ($archivo in $archivos) {
            if ($archivo.Name.StartsWith('_')) { continue }
            try {
                Import-OptiLowArchivo -Ruta $archivo.FullName
                $cargados++
                Write-Log -Nivel DEBUG -Mensaje "Cargado $carpeta\$($archivo.Name)"
            }
            catch {
                $fallidos++
                Write-Log -Nivel ERROR -Mensaje "No se pudo cargar $carpeta\$($archivo.Name): $($_.Exception.Message)"
            }
        }
    }

    return [pscustomobject]@{ Cargados = $cargados; Fallidos = $fallidos }
}
