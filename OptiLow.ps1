<#
.SYNOPSIS
    OptiLow: utilidad de optimización de Windows para equipos de bajos recursos.
.DESCRIPTION
    Punto de entrada. Verifica administrador (relanza con UAC si hace falta), carga el
    proyecto con el cargador único e inicializa el log.
    Fase 1: solo estructura, cargador, administrador y logging. Todavía no aplica nada.
.PARAMETER Consola
    Modo sin interfaz (la interfaz gráfica llega en la fase 5).
.PARAMETER SinElevar
    No pedir permisos de administrador (modo limitado, útil para pruebas).
.PARAMETER Elevado
    Interno: lo agrega el propio programa al relanzarse con UAC.
#>
[CmdletBinding()]
param(
    [switch]$Consola,
    [switch]$SinElevar,
    [switch]$Elevado
)

$ErrorActionPreference = 'Stop'
$RaizProyecto = $PSScriptRoot

function Wait-CierreVentana {
    # En una ventana elevada nueva, evita que se cierre antes de leer el resultado.
    if ($Elevado) {
        Read-Host 'Presione Enter para cerrar esta ventana' | Out-Null
    }
}

# --- 1. Administrador (antes de tocar nada en disco) ---
# Se carga solo lo mínimo de Core para comprobarlo; el resto se carga ya elevado.
try {
    . (Join-Path $RaizProyecto 'Core\Loader.ps1')
    Import-OptiLowCore -Raiz $RaizProyecto
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Wait-CierreVentana
    exit 1
}

$esAdmin = Test-EsAdministrador
if (-not $esAdmin -and -not $SinElevar) {
    if ($Elevado) {
        Write-Host '[ERROR] Se relanzó como administrador pero el proceso no tiene permisos elevados.' -ForegroundColor Red
        Wait-CierreVentana
        exit 1
    }
    Write-Host 'Se necesitan permisos de administrador. Solicitando elevación (UAC)...' -ForegroundColor Cyan
    $argumentos = @('-Elevado')
    if ($Consola) { $argumentos += '-Consola' }
    if (Invoke-RelanzarComoAdministrador -RutaScript $PSCommandPath -Argumentos $argumentos) {
        exit 0
    }
    exit 1
}

# --- 2. Rutas y log ---
try {
    Initialize-OptiLowRutas -Raiz $RaizProyecto
    Initialize-OptiLowLog -Destino Consola
}
catch {
    Write-Host "[ERROR] No se pudo inicializar rutas y log: $($_.Exception.Message)" -ForegroundColor Red
    Wait-CierreVentana
    exit 1
}

# Carpeta de respaldos protegida (solo se crea elevado). Sin ella no se aplica ningún cambio.
if ($esAdmin) {
    [void](Initialize-CarpetaRespaldos)
}

$apartamento = [System.Threading.Thread]::CurrentThread.GetApartmentState()
Write-Log -Mensaje "OptiLow iniciado. PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)), hilo $apartamento."
Write-Log -Mensaje "Usuario: $([Security.Principal.WindowsIdentity]::GetCurrent().Name). Administrador: $(if ($esAdmin) { 'sí' } else { 'no' })."
Write-Log -Mensaje "Carpeta del programa: $RaizProyecto"
Write-Log -Mensaje "Log: $($global:OptiLow.DirLogs)"

if (-not $esAdmin) {
    Write-Log -Nivel WARN -Mensaje 'Se ejecuta SIN permisos de administrador (-SinElevar): no se podrán aplicar cambios al sistema.'
}

# --- 3. Escritorio de otro usuario ---
$otro = Test-EscritorioDeOtroUsuario
if ($otro -and $otro.Distinto) {
    Write-Log -Nivel WARN -Mensaje "El escritorio pertenece a '$($otro.UsuarioEscritorio)' pero el script corre como '$($otro.UsuarioProceso)'. Los cambios de HKCU y %APPDATA% se aplicarían a la cuenta equivocada."
}

# --- 4. Modules y Tweaks (tolerantes a fallos) ---
$resultado = Import-OptiLowExtras -Raiz $RaizProyecto
Write-Log -Nivel OK -Mensaje "Carga terminada. Archivos de Modules/Tweaks cargados: $($resultado.Cargados). Con error: $($resultado.Fallidos)."

if (-not $Consola) {
    Write-Log -Nivel INFO -Mensaje 'La interfaz gráfica aún no existe (fase 5). Se trabaja en modo consola.'
}

Wait-CierreVentana
exit 0
