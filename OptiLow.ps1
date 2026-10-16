<#
.SYNOPSIS
    OptiLow: utilidad de optimización de Windows para equipos de bajos recursos.
.DESCRIPTION
    Punto de entrada. Verifica administrador (relanza con UAC si hace falta), carga el
    proyecto con el cargador único e inicializa el log.
    Fase 3: modo consola con motor de optimizaciones (la interfaz gráfica llega en la fase 5).
    Nada se aplica sin una acción explícita (-Aplicar o -Deshacer). El diagnóstico solo lee.
.PARAMETER Consola
    Modo sin interfaz (la interfaz gráfica llega en la fase 5).
.PARAMETER Listar
    Lista las optimizaciones registradas con su estado actual (solo lee).
.PARAMETER ListarSesiones
    Lista las sesiones del journal de respaldo (requiere administrador).
.PARAMETER Diagnostico
    Muestra el diagnóstico de hardware (solo lee): datos, perfil, recomendaciones y optimizaciones recomendadas.
.PARAMETER PerfilSimulado
    Bajo, Medio o Alto. Con -Diagnostico, muestra datos de PRUEBA en vez del hardware real, para ver cómo cambian
    las recomendaciones. Bloqueo estricto: con un perfil simulado no se puede aplicar ni deshacer nada.
.PARAMETER Aplicar
    Ids de las optimizaciones a aplicar, separados por comas. La palabra "recomendados" añade las que el
    diagnóstico recomienda para este equipo (y muestra por qué). Una ejecución es una sola sesión del journal.
.PARAMETER Deshacer
    Deshace una sesión del journal: por defecto la última que no esté restaurada.
.PARAMETER Sesion
    Con -Deshacer: Id de la sesión a deshacer (ver -ListarSesiones).
.PARAMETER SinPuntoRestauracion
    Con -Aplicar: no crea el punto de restauración (solo funcionará el journal para deshacer).
.PARAMETER SinPreguntar
    No pide confirmaciones. Usa siempre la opción segura: nunca activa la Protección del sistema por su
    cuenta y, si el punto de restauración falla, cancela (salvo que también se pase -SinPuntoRestauracion).
.PARAMETER SinElevar
    No pedir permisos de administrador (modo limitado, útil para pruebas).
.PARAMETER Elevado
    Interno: lo agrega el propio programa al relanzarse con UAC.
.NOTES
    Códigos de salida: 0 = bien, 1 = fallos o error, 2 = cancelado.
.EXAMPLE
    .\OptiLow.ps1 -Listar
.EXAMPLE
    .\OptiLow.ps1 -Aplicar efectos-transparencia-off,telemetria-tareas-off
.EXAMPLE
    .\OptiLow.ps1 -Deshacer
#>
[CmdletBinding()]
param(
    [switch]$Consola,
    [switch]$Listar,
    [switch]$ListarSesiones,
    [switch]$Diagnostico,
    [ValidateSet('Bajo', 'Medio', 'Alto')][string]$PerfilSimulado,
    [string[]]$Aplicar,
    [switch]$Deshacer,
    [string]$Sesion,
    [switch]$SinPuntoRestauracion,
    [switch]$SinPreguntar,
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

# Ids pedidos con -Aplicar (admite comas: en -File una lista con comas llega como un solo texto)
$idsAplicar = @()
if ($PSBoundParameters.ContainsKey('Aplicar')) {
    $idsAplicar = @($Aplicar | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
}
# "recomendados" no es un Id: pide las optimizaciones que recomienda el diagnóstico
$pedirRecomendados = @($idsAplicar | Where-Object { $_ -ieq 'recomendados' }).Count -gt 0
$idsAplicar = @($idsAplicar | Where-Object { $_ -ine 'recomendados' })
$hayAccion = $Listar -or $ListarSesiones -or $Diagnostico -or $Deshacer -or $PSBoundParameters.ContainsKey('Aplicar')

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

# Combinaciones de parámetros no válidas (se avisa antes de pedir elevación)
$errorParametros = $null
if ($Sesion -and -not $Deshacer) { $errorParametros = '-Sesion solo se usa junto con -Deshacer.' }
elseif ($Deshacer -and $PSBoundParameters.ContainsKey('Aplicar')) { $errorParametros = '-Deshacer y -Aplicar no se pueden usar a la vez.' }
elseif ($PSBoundParameters.ContainsKey('Aplicar') -and ($idsAplicar.Count -eq 0) -and (-not $pedirRecomendados)) { $errorParametros = '-Aplicar necesita al menos un Id o la palabra "recomendados" (usa -Listar para ver los Ids).' }
elseif ($PerfilSimulado -and ($Deshacer -or $PSBoundParameters.ContainsKey('Aplicar'))) { $errorParametros = '-PerfilSimulado solo sirve para ver el diagnóstico: con un perfil simulado no se puede aplicar ni deshacer nada.' }
elseif ($PerfilSimulado -and -not $Diagnostico) { $errorParametros = '-PerfilSimulado se usa junto con -Diagnostico.' }
if ($errorParametros) {
    Write-Host "[ERROR] $errorParametros" -ForegroundColor Red
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

    # Se reenvían todos los parámetros recibidos (menos los de control de la elevación)
    $argumentos = @('-Elevado')
    foreach ($par in $PSBoundParameters.GetEnumerator()) {
        if (@('SinElevar', 'Elevado') -contains $par.Key) { continue }
        $valor = $par.Value
        if ($valor -is [System.Management.Automation.SwitchParameter]) {
            if ($valor.IsPresent) { $argumentos += "-$($par.Key)" }
        }
        elseif ($valor -is [array]) {
            $argumentos += "-$($par.Key)"
            $argumentos += (($valor | ForEach-Object { [string]$_ }) -join ',')
        }
        else {
            $argumentos += "-$($par.Key)"
            $argumentos += [string]$valor
        }
    }
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

# Bloqueo estricto: con un perfil simulado, Assert-JournalListo rechaza cualquier escritura o deshacer
if ($PerfilSimulado) { $global:OptiLow.SimulacionActiva = $true }

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
Write-Log -Nivel OK -Mensaje "Carga terminada. Archivos de Modules/Tweaks cargados: $($resultado.Cargados). Con error: $($resultado.Fallidos). Optimizaciones registradas: $(@(Get-Tweak).Count)."

# --- 5. Acciones de consola (solo con una acción explícita) ---
$codigo = 0
if ($Diagnostico) {
    if (-not (Get-Command -Name 'Get-Diagnostico' -ErrorAction SilentlyContinue)) {
        Write-Log -Nivel ERROR -Mensaje 'El módulo de diagnóstico (Modules/Hardware.ps1) no se cargó: revisa el log.'
        $codigo = 1
    }
    else {
        if ($PerfilSimulado) { $hw = New-HardwareSimulado -Perfil $PerfilSimulado } else { $hw = Get-Diagnostico -Forzar }
        Show-DiagnosticoConsola -Hardware $hw
    }
}
if ($ListarSesiones) {
    $codigo = [int](@(Show-SesionesConsola)[-1])
}
if ($Listar) {
    Show-TweaksConsola
}
if ($Deshacer) {
    $codigo = [int](@(Invoke-DeshacerConsola -Sesion $Sesion -SinPreguntar:$SinPreguntar)[-1])
}
elseif ($PSBoundParameters.ContainsKey('Aplicar')) {
    $codigo = [int](@(Invoke-AplicarConsola -Ids $idsAplicar -Recomendados:$pedirRecomendados -SinPuntoRestauracion:$SinPuntoRestauracion -SinPreguntar:$SinPreguntar)[-1])
}

if ((-not $hayAccion) -and (-not $Consola)) {
    Write-Log -Nivel INFO -Mensaje 'La interfaz gráfica aún no existe (fase 5). Se trabaja en modo consola: usa -Diagnostico, -Listar, -Aplicar, -Deshacer o -ListarSesiones.'
}

Wait-CierreVentana
exit $codigo
