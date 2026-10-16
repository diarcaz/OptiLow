<#
.SYNOPSIS
    OptiLow: utilidad de optimización de Windows para equipos de bajos recursos.
.DESCRIPTION
    Punto de entrada. Verifica administrador (relanza con UAC si hace falta), carga el
    proyecto con el cargador único e inicializa el log.
    Sin ninguna acción de consola (y sin -Consola) abre la interfaz gráfica (fase 5).
    Nada se aplica sin una acción explícita del usuario (botón Aplicar, -Aplicar o -Deshacer). El diagnóstico solo lee.
.PARAMETER Consola
    Modo consola: no abre la interfaz.
.PARAMETER MostrarConsola
    En modo interfaz, no oculta la consola de PowerShell (útil para depurar).
.PARAMETER RenderizadoSoftware
    En modo interfaz, fuerza el renderizado por software (drivers de video rotos). Tiene prioridad sobre la
    preferencia guardada. Lo usa «Iniciar (modo seguro).cmd».
.PARAMETER Demo
    En modo interfaz, muestra en la pestaña Diagnóstico el selector de datos simulados (Bajo, Medio, Alto).
    Es solo para ver: con datos simulados no se puede aplicar ni deshacer nada.
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
    [switch]$MostrarConsola,
    [switch]$RenderizadoSoftware,
    [switch]$Demo,
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

function global:Show-ErrorSinWpf {
    <#
    .SYNOPSIS
        Muestra un error de arranque SIN depender de WPF (la consola va oculta en modo interfaz) y lo guarda.
    .DESCRIPTION
        Cadena: log (si ya existe) y %TEMP%\OptiLow-error.log -> WScript.Shell.Popup -> MessageBox de Windows
        Forms (si Windows Script Host está bloqueado por directiva) -> msg.exe -> solo el archivo.
    #>
    param(
        [Parameter(Mandatory)][string]$Mensaje,
        [string]$Titulo = 'OptiLow - error al iniciar'
    )

    try { Write-Log -Nivel ERROR -Mensaje $Mensaje } catch { }
    $archivo = Join-Path $env:TEMP 'OptiLow-error.log'
    try {
        [System.IO.File]::AppendAllText($archivo, ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Mensaje) + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
    }
    catch { }
    Write-Host "[ERROR] $Mensaje" -ForegroundColor Red

    $texto = $Mensaje + "`n`nSe guardó en: $archivo"
    try {
        $wsh = New-Object -ComObject WScript.Shell
        [void]$wsh.Popup($texto, 0, $Titulo, 16)
        return
    }
    catch { }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($texto, $Titulo, 'OK', 'Error')
        return
    }
    catch { }
    try { & "$env:windir\System32\msg.exe" '*' '/TIME:120' $texto } catch { }
}

function ConvertTo-ArgumentosReenvio {
    # Auxiliar: reconstruye los parámetros recibidos para relanzar el script (menos los indicados).
    param(
        [Parameter(Mandatory)]$Parametros,
        [string[]]$Excluir = @()
    )

    $argumentos = @()
    foreach ($par in $Parametros.GetEnumerator()) {
        if ($Excluir -contains $par.Key) { continue }
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
    return $argumentos
}

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
# Sin acción de consola y sin -Consola: se abre la interfaz
$modoInterfaz = (-not $hayAccion) -and (-not $Consola)

# --- 1. Administrador (antes de tocar nada en disco) ---
# Modo consola: se carga todo Core/ (como siempre). Modo interfaz: solo lo mínimo para comprobar el administrador y
# relanzar (Paths, Logging, Admin); el resto de Core/ lo carga la propia interfaz, ya con la ventana en pantalla.
try {
    . (Join-Path $RaizProyecto 'Core\Loader.ps1')
    if ($modoInterfaz) {
        foreach ($nombreCore in @('Paths.ps1', 'Logging.ps1', 'Admin.ps1')) {
            Import-OptiLowArchivo -Ruta (Join-Path (Join-Path $RaizProyecto 'Core') $nombreCore)
        }
    }
    else {
        Import-OptiLowCore -Raiz $RaizProyecto
    }
}
catch {
    if ($modoInterfaz) { Show-ErrorSinWpf -Mensaje $_.Exception.Message } else { Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red }
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
    $argumentos = @('-Elevado') + @(ConvertTo-ArgumentosReenvio -Parametros $PSBoundParameters -Excluir @('SinElevar', 'Elevado'))
    # En modo interfaz el proceso elevado lleva la consola oculta (salvo -MostrarConsola)
    if (Invoke-RelanzarComoAdministrador -RutaScript $PSCommandPath -Argumentos $argumentos -Oculto:($modoInterfaz -and -not $MostrarConsola)) {
        exit 0
    }
    if ($modoInterfaz) {
        # La consola puede estar oculta: el aviso tiene que verse sin depender de ella
        Show-ErrorSinWpf -Titulo 'OptiLow' -Mensaje 'OptiLow necesita permisos de administrador y no se concedieron (se canceló la ventana de Windows o falló). Para mirar sin aplicar nada, abre OptiLow.ps1 con -SinElevar.'
    }
    exit 1
}

# --- 1b. Modo interfaz ---
if ($modoInterfaz) {
    # WPF exige un hilo STA: si el proceso no lo es, se relanza con -STA
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        $exeSta = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
        $partesSta = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) + @(ConvertTo-ArgumentosReenvio -Parametros $PSBoundParameters)
        $cadenaSta = ($partesSta | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
        $procSta = Start-Process -FilePath $exeSta -ArgumentList $cadenaSta -Wait -PassThru -NoNewWindow
        exit $procSta.ExitCode
    }
    $codigoUi = 1
    try {
        foreach ($nombreUi in @('Interfaz.ps1', 'Trabajos.ps1', 'Inicio.ps1')) {
            Import-OptiLowArchivo -Ruta (Join-Path (Join-Path $RaizProyecto 'UI') $nombreUi)
        }
        $codigoUi = @(Start-OptiLowInterfaz -Raiz $RaizProyecto -Opciones @{
            Demo                = [bool]$Demo
            SinElevar           = [bool]$SinElevar
            RenderizadoSoftware = [bool]$RenderizadoSoftware
            MostrarConsola      = [bool]$MostrarConsola
        })
    }
    catch {
        Show-ErrorSinWpf -Mensaje "No se pudo iniciar la interfaz: $($_.Exception.Message)"
    }
    # La función devuelve un solo número; se toma el último valor por si algo más llegara a la salida
    exit ([int]@($codigoUi)[-1])
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
    Write-Log -Nivel INFO -Mensaje 'Modo consola (-Consola) sin ninguna acción: usa -Diagnostico, -Listar, -Aplicar, -Deshacer o -ListarSesiones (sin -Consola se abre la interfaz).'
}

Wait-CierreVentana
exit $codigo
