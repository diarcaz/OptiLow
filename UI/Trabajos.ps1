# UI/Trabajos.ps1
# Trabajos en segundo plano de la interfaz. La interfaz NUNCA hace trabajo pesado en su hilo:
#   - Un runspace de trabajo de larga vida, creado al arrancar en segundo plano. Carga el proyecto con el
#     mismo cargador y escribe el log en la cola compartida ($global:OptiLowUI.Cola). La sesión del journal
#     vive en ese runspace y se conserva entre trabajos.
#   - Los comandos se pasan COMO TEXTO (AddScript), nunca como scriptblock, para que no se ejecuten en el
#     hilo de la interfaz.
#   - Un DispatcherTimer (~200 ms) en el hilo de la interfaz vacía la cola de log, actualiza el texto
#     "Trabajando…" y detecta cuándo termina el trabajo; los manejadores de final se ejecutan en el hilo
#     de la interfaz.
#   - Solo un trabajo a la vez: mientras corre, se desactivan los botones de acción.
#
# El estado compartido de la interfaz vive en UNA sola variable global: $global:OptiLowUI.

# Textos de los trabajos (se ejecutan en el runspace de trabajo). Cada uno devuelve datos; no toca la interfaz.
$global:OptiLowScriptsTrabajo = @{
    iniciar = @'
param($Raiz, $Cola, $SinElevar)
$ErrorActionPreference = 'Stop'
. (Join-Path $Raiz 'Core\Loader.ps1')
Import-OptiLowCore -Raiz $Raiz
$global:OptiLow = @{ ColaLog = $Cola; LogDestino = 'Cola' }
Initialize-OptiLowRutas -Raiz $Raiz
# Los avisos de las rutas ya los emitió el hilo de la interfaz
$global:OptiLow.Avisos.Clear()
if ((-not $SinElevar) -and (Test-EsAdministrador)) { [void](Initialize-CarpetaRespaldos) }
$r = Import-OptiLowExtras -Raiz $Raiz
[pscustomobject]@{ Tweaks = @(Get-Tweak).Count; Cargados = $r.Cargados; Fallidos = $r.Fallidos; JournalListo = [bool]$global:OptiLow.DirRespaldos }
'@

    estados = @'
foreach ($t in @(Get-Tweak)) { Get-TweakEstado -Id $t.Id }
'@

    diagnostico = @'
param($Perfil)
if ($Perfil) {
    $global:OptiLow.SimulacionActiva = $true
    $hw = New-HardwareSimulado -Perfil $Perfil
}
else {
    $global:OptiLow.SimulacionActiva = $false
    $hw = Get-Diagnostico -Forzar
}
$rec = @(Get-TweaksRecomendados -Hardware $hw)
[pscustomobject]@{ Hardware = $hw; Recomendados = $rec }
'@

    preparar = @'
param($Omitir)
Assert-JournalListo -Completo
[void](Start-JournalSesion -Nueva)
if ($Omitir) {
    Write-Log -Nivel WARN -Mensaje 'Se omite el punto de restauración (a petición del usuario): solo el journal permitirá deshacer.'
    [pscustomobject]@{ Omitido = $true; Punto = $null }
}
else {
    [pscustomobject]@{ Omitido = $false; Punto = (New-PuntoRestauracion -Descripcion 'OptiLow - antes de aplicar cambios') }
}
'@

    proteccion = @'
$a = Enable-ProteccionSistema
$p = $null
if ($a.Activada) { $p = New-PuntoRestauracion -Descripcion 'OptiLow - antes de aplicar cambios' }
[pscustomobject]@{ Activacion = $a; Punto = $p }
'@

    aplicar = @'
param($Ids)
Invoke-TweaksLote -Ids @($Ids)
'@

    sesiones = @'
Get-JournalSesiones
'@

    deshacer = @'
param($Id)
Undo-JournalSesion -Id $Id
'@

    # Trabajo de prueba (sin efectos): sirve para comprobar que la interfaz no se congela
    prueba = @'
param($Milisegundos)
$fin = (Get-Date).AddMilliseconds($Milisegundos)
$n = 0
while ((Get-Date) -lt $fin) {
    Start-Sleep -Milliseconds 50
    $n++
    if (($n % 10) -eq 0) { Write-Log -Nivel INFO -Mensaje "Trabajo de prueba: paso $n" }
}
'listo'
'@
}

function Start-RunspaceTrabajo {
    <#
    .SYNOPSIS
        Crea el runspace de trabajo y lo abre en segundo plano (no bloquea la interfaz).
    #>
    $ui = $global:OptiLowUI
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.OpenAsync()
    $ui.Runspace = $rs
}

function Start-TrabajoUI {
    <#
    .SYNOPSIS
        Inicia un trabajo en segundo plano (solo uno a la vez). Devuelve $false si ya hay uno en curso.
    .PARAMETER Nombre
        Clave de $global:OptiLowScriptsTrabajo.
    .PARAMETER Texto
        Texto que se muestra en la barra de estado mientras corre.
    .PARAMETER Parametros
        Parámetros del texto del trabajo (hashtable).
    .PARAMETER AlTerminar
        Scriptblock que se ejecuta en el hilo de la interfaz con el resultado (Nombre, Salida, Error, Segundos).
    #>
    param(
        [Parameter(Mandatory)][string]$Nombre,
        [string]$Texto = '',
        [hashtable]$Parametros = @{},
        [scriptblock]$AlTerminar
    )

    $ui = $global:OptiLowUI
    if ($ui.Trabajo) { return $false }
    $script = $global:OptiLowScriptsTrabajo[$Nombre]
    if (-not $script) { throw "No existe el trabajo '$Nombre'." }

    $ps = [powershell]::Create()
    $ps.Runspace = $ui.Runspace
    [void]$ps.AddScript($script)
    if ($Parametros.Count -gt 0) { [void]$ps.AddParameters($Parametros) }

    if (-not $Texto) { $Texto = $Nombre }
    $ui.Trabajo = @{
        Nombre = $Nombre; Texto = $Texto; PS = $ps; Handle = $null; AlTerminar = $AlTerminar
        Reloj = [System.Diagnostics.Stopwatch]::StartNew()
    }
    $ui.TrabajosIniciados = 1 + [int]$ui.TrabajosIniciados
    Write-Log -Nivel DEBUG -Mensaje "Trabajo en segundo plano iniciado: $Nombre"
    Update-EstadoBotonesUI
    Update-TextoTrabajoUI
    Invoke-AvanceTrabajoUI
    return $true
}

function Invoke-AvanceTrabajoUI {
    # Auxiliar interna: arranca el trabajo cuando el runspace ya está abierto y detecta cuándo termina.
    $ui = $global:OptiLowUI
    $t = $ui.Trabajo
    if (-not $t) { return }

    if (-not $t.Handle) {
        $estado = $ui.Runspace.RunspaceStateInfo.State
        if ($estado -eq 'Opened') {
            $t.Handle = $t.PS.BeginInvoke()
        }
        elseif ($estado -in @('Broken', 'Closed', 'Closing')) {
            Complete-TrabajoUI -Falla "El runspace de trabajo no está disponible ($estado)."
        }
        return
    }
    if ($t.Handle.IsCompleted) { Complete-TrabajoUI }
}

function Complete-TrabajoUI {
    # Auxiliar interna: recoge el resultado, libera el trabajo y llama al manejador de final (hilo de la interfaz).
    param(
        [string]$Falla
    )

    $ui = $global:OptiLowUI
    $t = $ui.Trabajo
    $salida = @()
    $mensajeError = $Falla
    if ((-not $mensajeError) -and $t.Handle) {
        try {
            $salida = @($t.PS.EndInvoke($t.Handle))
        }
        catch {
            $ex = $_.Exception
            while ($ex.InnerException) { $ex = $ex.InnerException }
            $mensajeError = $ex.Message
        }
        if ((-not $mensajeError) -and ($t.PS.Streams.Error.Count -gt 0)) {
            $mensajeError = (@($t.PS.Streams.Error | ForEach-Object { $_.ToString() }) -join ' | ')
        }
    }
    $resultado = [pscustomobject]@{
        Nombre   = $t.Nombre
        Salida   = $salida
        Error    = $mensajeError
        Segundos = [math]::Round($t.Reloj.Elapsed.TotalSeconds, 1)
    }
    try { $t.PS.Dispose() } catch { }
    $ui.Trabajo = $null
    if ($mensajeError) { Write-Log -Nivel ERROR -Mensaje "Trabajo '$($t.Nombre)' con error: $mensajeError" }
    else { Write-Log -Nivel DEBUG -Mensaje "Trabajo '$($t.Nombre)' terminado en $($resultado.Segundos) s." }

    Update-EstadoBotonesUI
    Update-TextoTrabajoUI
    if ($t.AlTerminar) {
        try { & $t.AlTerminar $resultado }
        catch { Write-Log -Nivel ERROR -Mensaje "Error al procesar el resultado de '$($t.Nombre)': $($_.Exception.Message)" }
    }
}

function Update-TextoTrabajoUI {
    # Auxiliar interna: texto de la barra de estado (texto que cambia, sin barra de progreso animada).
    $ui = $global:OptiLowUI
    $c = $ui.C
    if (-not $c) { return }
    $t = $ui.Trabajo
    if (-not $t) {
        $c.TxtEstadoTrabajo.Text = 'Listo'
        $c.TxtEstadoTrabajo.Foreground = $c.VentanaPrincipal.FindResource('BrushTexto')
        return
    }
    $puntos = '.' * (1 + ([int]$t.Reloj.Elapsed.TotalSeconds % 3))
    $c.TxtEstadoTrabajo.Text = 'Trabajando: {0}{1} ({2} s)' -f $t.Texto, $puntos, [int]$t.Reloj.Elapsed.TotalSeconds
    $c.TxtEstadoTrabajo.Foreground = $c.VentanaPrincipal.FindResource('BrushAviso')
}

function Get-ColorLogUI {
    # Auxiliar interna: pincel según el nivel de una línea de log "[HH:mm:ss] [NIVEL] mensaje".
    param(
        [string]$Linea
    )

    $clave = 'BrushTexto'
    if ($Linea -match '^\[[^\]]*\] \[(INFO|OK|WARN|ERROR|DEBUG)\]') {
        switch ($Matches[1]) {
            'OK'    { $clave = 'BrushOk' }
            'WARN'  { $clave = 'BrushAviso' }
            'ERROR' { $clave = 'BrushError' }
            'DEBUG' { $clave = 'BrushTextoSuave' }
        }
    }
    return $global:OptiLowUI.C.VentanaPrincipal.FindResource($clave)
}

function Add-LineaLogUI {
    <#
    .SYNOPSIS
        Agrega una línea a la vista del registro (máximo 2000 líneas en pantalla).
    #>
    param(
        [Parameter(Mandatory)][string]$Linea
    )

    $ui = $global:OptiLowUI
    $c = $ui.C
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Linea
    $tb.Foreground = Get-ColorLogUI -Linea $Linea
    $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
    [void]$c.ListaLog.Items.Add($tb)
    [void]$ui.LineasLog.Add($Linea)
    while ($c.ListaLog.Items.Count -gt 2000) {
        $c.ListaLog.Items.RemoveAt(0)
        $ui.LineasLog.RemoveAt(0)
    }
}

function Invoke-VaciarColaLogUI {
    <#
    .SYNOPSIS
        Vacía la cola compartida de log hacia la vista (con tope de líneas por vuelta). Devuelve cuántas pasó.
    #>
    param(
        [int]$Tope = 200
    )

    $ui = $global:OptiLowUI
    $n = 0
    $linea = $null
    while (($n -lt $Tope) -and $ui.Cola.TryDequeue([ref]$linea)) {
        Add-LineaLogUI -Linea $linea
        $n++
    }
    if (($n -gt 0) -and ($ui.C.VistaRegistro.Visibility -eq 'Visible') -and ($ui.C.ListaLog.Items.Count -gt 0)) {
        $ui.C.ListaLog.ScrollIntoView($ui.C.ListaLog.Items[$ui.C.ListaLog.Items.Count - 1])
    }
    return $n
}

function Invoke-TickUI {
    # Manejador del DispatcherTimer (~200 ms), en el hilo de la interfaz.
    $ui = $global:OptiLowUI
    try {
        if ($ui.MedirTicks) { [void]$ui.Ticks.Add([System.Diagnostics.Stopwatch]::GetTimestamp()) }
        [void](Invoke-VaciarColaLogUI)
        if ($ui.Trabajo) {
            Invoke-AvanceTrabajoUI
            if ($ui.Trabajo) { Update-TextoTrabajoUI }
        }
    }
    catch {
        # Nunca dejar que un error del temporizador lo detenga
        try { Write-Log -Nivel ERROR -Mensaje "Error en el temporizador de la interfaz: $($_.Exception.Message)" } catch { }
    }
}

function Start-TemporizadorUI {
    $ui = $global:OptiLowUI
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({ Invoke-TickUI })
    $timer.Start()
    $ui.Timer = $timer
}

function Stop-TrabajosUI {
    <#
    .SYNOPSIS
        Detiene el temporizador y cierra el runspace de trabajo (al cerrar la ventana).
    #>
    $ui = $global:OptiLowUI
    if ($ui.Timer) { try { $ui.Timer.Stop() } catch { } }
    if ($ui.Trabajo -and $ui.Trabajo.PS) { try { [void]$ui.Trabajo.PS.BeginStop($null, $null) } catch { } }
    if ($ui.Runspace) {
        # Closed de forma asíncrona: no se espera a un trabajo a medias (lo aplicado queda en el journal)
        try { $ui.Runspace.CloseAsync() } catch { }
    }
}
