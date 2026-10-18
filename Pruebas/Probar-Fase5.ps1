<#
.SYNOPSIS
    Autopruebas de la Fase 5 (interfaz WPF/XAML).
.DESCRIPTION
    No aplica nada real: no pide confirmación y no necesita administrador (pero se puede ejecutar elevado).
    Abre la ventana REAL en este mismo proceso por el mismo camino que el arranque normal y la maneja con el
    dispatcher. Para no tocar el sistema ni el journal real:
      - %ProgramData% se redirige a una carpeta temporal durante la prueba (logs, respaldos y preferencias);
      - los diálogos se sustituyen por respuestas fijas;
      - en el runspace de trabajo se sustituyen New-PuntoRestauracion, Invoke-TweaksLote, Enable-ProteccionSistema,
        Start-JournalSesion y Assert-JournalListo por funciones de prueba (el diagnóstico y los estados son
        de solo lectura y se ejecutan de verdad).
    Comprueba: XAML sin efectos pesados, controles y pestañas, diseño a 4 tamaños, que la interfaz no se congela,
    un trabajo a la vez, cierre con trabajo en curso, flujo de aplicar (confirmación, decisiones del punto de
    restauración, una sola sesión), modo simulado, banners, teclado, preferencia de renderizado y tiempos de
    apertura (normal y software, en procesos aparte). Guarda capturas PNG en %TEMP%\OptiLow-capturas\.
    Este script NUNCA lo carga el cargador (está fuera de Core/, Modules/ y Tweaks/).
    Ejecutar en Windows PowerShell 5.1 (hilo STA):
        powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Pruebas\Probar-Fase5.ps1
.PARAMETER SoloArranque
    Interno: arranca la interfaz, imprime los tiempos y sale (lo usa la propia prueba en procesos aparte).
.PARAMETER Software
    Interno: con -SoloArranque, fuerza el renderizado por software.
.PARAMETER SimularFalloVentana
    Interno: con -SoloArranque, hace fallar la primera creación de la ventana (prueba el reintento en software).
.PARAMETER CerrarEn
    Interno: con -SoloArranque, cierra la ventana en cuanto se anota esa etapa de arranque (cierre a mitad de la carga).
.PARAMETER ProbarInstancia
    Interno: intenta tomar el mutex de instancia única con ese nombre, imprime PRIMERA=True/False y sale.
.PARAMETER SimularErrorArranque
    Interno: con -SoloArranque, hace fallar siempre la creación de la ventana (prueba el aviso sin WPF).
#>
param(
    [switch]$SoloArranque,
    [switch]$Software,
    [switch]$SimularFalloVentana,
    [switch]$SimularErrorArranque,
    [string]$ProbarInstancia,
    [string]$CerrarEn
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
$script:bien = 0
$script:mal = 0
function T { param([string]$Nombre, [bool]$Condicion)
    if ($Condicion) { $script:bien++; Write-Host "  OK     $Nombre" -ForegroundColor Green }
    else { $script:mal++; Write-Host "  FALLA  $Nombre" -ForegroundColor Red } }
function Info { param([string]$Texto) Write-Host "  (info) $Texto" -ForegroundColor DarkGray }
function Seccion { param([string]$Texto) Write-Host ''; Write-Host "== $Texto ==" -ForegroundColor Cyan }

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'Esta prueba necesita un hilo STA. Ejecuta: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Pruebas\Probar-Fase5.ps1' -ForegroundColor Red
    exit 1
}

# --- Aislamiento: %ProgramData% temporal (logs, respaldos y preferencias de la prueba) ---
$programDataReal = $env:ProgramData
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('OptiLow-PruebaF5-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $tmp -Force)
$env:ProgramData = $tmp

# --- Carga igual que OptiLow.ps1 en modo interfaz ---
. (Join-Path $raiz 'Core\Loader.ps1')
foreach ($n in @('Paths.ps1', 'Logging.ps1', 'Admin.ps1')) { Import-OptiLowArchivo -Ruta (Join-Path (Join-Path $raiz 'Core') $n) }
foreach ($n in @('Interfaz.ps1', 'Trabajos.ps1', 'Inicio.ps1')) { Import-OptiLowArchivo -Ruta (Join-Path (Join-Path $raiz 'UI') $n) }

# Show-ErrorSinWpf vive en OptiLow.ps1 (no se puede cargar sin ejecutarlo): aquí se sustituye por una de prueba
$global:PruebaErrores = New-Object System.Collections.ArrayList
function global:Show-ErrorSinWpf { param([string]$Mensaje, [string]$Titulo) [void]$global:PruebaErrores.Add($Mensaje) }

if ($ProbarInstancia) {
    Write-Output ('PRIMERA=' + (Enter-InstanciaUnica -Nombre $ProbarInstancia))
    $env:ProgramData = $programDataReal
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

# ---------------------------------------------------------------------------------------------
# Modo interno: arrancar, imprimir tiempos y salir (procesos aparte)
# ---------------------------------------------------------------------------------------------
if ($SoloArranque) {
    if ($SimularFalloVentana -or $SimularErrorArranque) {
        $global:PruebaIntentos = 0
        $global:PruebaFalloSiempre = [bool]$SimularErrorArranque
        $original = ${function:New-OptiLowVentana}
        $global:PruebaOriginalVentana = $original
        function global:New-OptiLowVentana {
            $global:PruebaIntentos++
            if ($global:PruebaFalloSiempre -or ($global:PruebaIntentos -eq 1)) { throw 'Fallo simulado al crear la ventana.' }
            & $global:PruebaOriginalVentana
        }
    }
    if ($CerrarEn) {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $global:PruebaEtapaCierre = $CerrarEn
        $tmCierre = New-Object System.Windows.Threading.DispatcherTimer
        $tmCierre.Interval = [TimeSpan]::FromMilliseconds(10)
        $tmCierre.Add_Tick({
                param($s, $e)
                $u = $global:OptiLowUI
                if ($u -and $u.C.VentanaPrincipal -and $u.Tiempos.Contains($global:PruebaEtapaCierre)) { $s.Stop(); $u.C.VentanaPrincipal.Close() }
            })
        $tmCierre.Start()
    }
    $codigo = @(Start-OptiLowInterfaz -Raiz $raiz -Opciones @{ Demo = $false; SinElevar = $false; RenderizadoSoftware = [bool]$Software } -SinBucle)[-1]
    $ui = $global:OptiLowUI
    Write-Output "RESULTADO: cerrada=$($ui.Cerrada) codigo=$codigo modo=[$($ui.ModoRender)] intentos=$($global:PruebaIntentos) errores=$($global:PruebaErrores.Count) modoProceso=$(try { [System.Windows.Media.RenderOptions]::ProcessRenderMode } catch { 'n/d' })"
    foreach ($par in $ui.Tiempos.GetEnumerator()) { Write-Output ('TIEMPO: {0} = {1} ms' -f $par.Key, $par.Value) }
    if ($global:PruebaErrores.Count -gt 0) { Write-Output ('ERROR-MOSTRADO: ' + $global:PruebaErrores[0]) }
    try { Stop-TrabajosUI } catch { }
    $env:ProgramData = $programDataReal
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

# ---------------------------------------------------------------------------------------------
# Ayudantes de la prueba
# ---------------------------------------------------------------------------------------------
function Wait-UI {
    # Bombea el dispatcher hasta que se cumpla la condición (o pase el tiempo límite). Devuelve si se cumplió.
    param([scriptblock]$Condicion, [int]$LimiteMs = 60000)
    $reloj = [System.Diagnostics.Stopwatch]::StartNew()
    while ($reloj.ElapsedMilliseconds -lt $LimiteMs) {
        Invoke-BombearUI
        if (& $Condicion) { return $true }
        Start-Sleep -Milliseconds 15
    }
    return $false
}
function Esperar-Libre { param([int]$LimiteMs = 90000) return (Wait-UI -Condicion { -not $global:OptiLowUI.Trabajo } -LimiteMs $LimiteMs) }

function Get-RectEn { param($El, $Raiz)
    $p = $El.TransformToAncestor($Raiz).Transform((New-Object System.Windows.Point(0, 0)))
    return [pscustomobject]@{ X = $p.X; Y = $p.Y; Der = $p.X + $El.ActualWidth; Aba = $p.Y + $El.ActualHeight }
}
function En-Scroll { param($El)
    $p = [System.Windows.Media.VisualTreeHelper]::GetParent($El)
    while ($p) { if ($p -is [System.Windows.Controls.ScrollViewer]) { return $true }; $p = [System.Windows.Media.VisualTreeHelper]::GetParent($p) }
    return $false
}
function Save-Captura { param([string]$Nombre)
    try {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) 'OptiLow-capturas'
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $w = $global:OptiLowUI.C.VentanaPrincipal
        $r = $w.Content
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$r.ActualWidth, [int]$r.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        # El fondo oscuro es el de la ventana (no del contenido): se pinta primero para que la captura sea fiel
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen(); $dc.DrawRectangle($w.Background, $null, (New-Object System.Windows.Rect(0, 0, $r.ActualWidth, $r.ActualHeight))); $dc.Close()
        $bmp.Render($dv)
        $bmp.Render($r)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $ruta = Join-Path $dir ($Nombre + '.png')
        $fs = [System.IO.File]::Create($ruta); $enc.Save($fs); $fs.Close()
    } catch { Info "No se pudo guardar la captura '$Nombre': $($_.Exception.Message)" }
}

# Diálogos de prueba: respuestas fijas y registro de lo que se mostró
$global:PruebaDialogos = New-Object System.Collections.ArrayList
$global:PruebaRespuestas = New-Object System.Collections.Queue
function global:Show-DialogoOptiLow {
    param([string]$Titulo, [string]$Mensaje, [string[]]$Detalles = @(), [string]$Advertencia = '', [string[]]$Botones = @('Aceptar'),
        [int]$Predeterminado = 0, [int]$Cancelar = -1, [string]$Tipo = 'Info')
    [void]$global:PruebaDialogos.Add([pscustomobject]@{ Titulo = $Titulo; Mensaje = $Mensaje; Detalles = $Detalles; Advertencia = $Advertencia; Botones = $Botones; Tipo = $Tipo; Predeterminado = $Predeterminado; Cancelar = $Cancelar })
    if ($global:PruebaRespuestas.Count -gt 0) { return [int]$global:PruebaRespuestas.Dequeue() }
    if ($Cancelar -ge 0) { return $Cancelar }
    return $Predeterminado
}
function Reset-Dialogos { $global:PruebaDialogos.Clear(); $global:PruebaRespuestas.Clear() }

# Vuelve a cargar las funciones reales que la prueba sustituyó (diálogos y administrador)
function Restaurar-Entorno {
    try { Import-OptiLowArchivo -Ruta (Join-Path $raiz 'UI\Interfaz.ps1') } catch { }
    try { Import-OptiLowArchivo -Ruta (Join-Path $raiz 'Core\Admin.ps1') } catch { }
}

# ---------------------------------------------------------------------------------------------
Seccion '1. XAML: sin efectos pesados y con todos los controles con nombre'
$rutaXaml = Join-Path $raiz 'UI\MainWindow.xaml'
$xamlTexto = [System.IO.File]::ReadAllText($rutaXaml, [System.Text.Encoding]::UTF8)
$sinComentarios = [regex]::Replace($xamlTexto, '<!--.*?-->', '', 'Singleline')
$prohibidos = @('DropShadowEffect', 'BlurEffect', 'Effect=', 'BitmapEffect', 'AllowsTransparency', 'Storyboard', 'BeginStoryboard', 'DoubleAnimation',
    'ColorAnimation', 'ThicknessAnimation', 'Animation', '<Image', 'BitmapImage', 'ImageBrush', 'ProgressBar', 'ShaderEffect', 'RenderTransform', 'Viewport3D')
foreach ($p in $prohibidos) { T "El XAML no contiene '$p'" (-not ($sinComentarios -match [regex]::Escape($p))) }
T 'El XAML declara UseLayoutRounding y SnapsToDevicePixels' (($sinComentarios -match 'UseLayoutRounding="True"') -and ($sinComentarios -match 'SnapsToDevicePixels="True"'))
T 'Hay colores definidos como recursos (SolidColorBrush con clave)' ([regex]::Matches($sinComentarios, '<SolidColorBrush x:Key="Brush\w+"').Count -ge 10)
# (los nombres dentro de <Window.Resources>, p. ej. los de las plantillas, tienen su propio ámbito y pueden repetirse)
$sinRecursos = [regex]::Replace($sinComentarios, '(?s)<Window\.Resources>.*?</Window\.Resources>', '')
$nombresXaml = @([regex]::Matches($sinRecursos, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value })
T 'Los x:Name del XAML no se repiten' (@($nombresXaml | Select-Object -Unique).Count -eq $nombresXaml.Count)
$tam = [regex]::Matches($sinComentarios, 'FontSize="(\d+(\.\d+)?)"') | ForEach-Object { [double]$_.Groups[1].Value }
T 'Ninguna fuente fija del XAML es menor de 13 px (salvo los textos secundarios creados en código de 12)' (@($tam | Where-Object { $_ -lt 13 }).Count -eq 0)
$textoOptiLow = Get-Content -LiteralPath (Join-Path $raiz 'OptiLow.ps1') -Raw
foreach ($tok in @('WScript.Shell', 'Popup', 'MessageBox', 'msg.exe', 'OptiLow-error.log')) { T "Show-ErrorSinWpf (OptiLow.ps1) usa '$tok'" ($textoOptiLow -match 'function global:Show-ErrorSinWpf' -and $textoOptiLow.Contains($tok)) }
T 'Iniciar.cmd oculta la consola sin argumentos' ((Get-Content -LiteralPath (Join-Path $raiz 'Iniciar.cmd') -Raw) -match '-WindowStyle Hidden')
T '«Iniciar (modo seguro).cmd» pasa -RenderizadoSoftware y oculta la consola' ((Get-Content -LiteralPath (Join-Path $raiz 'Iniciar (modo seguro).cmd') -Raw) -match '(?s)-WindowStyle Hidden.*-RenderizadoSoftware')

# ---------------------------------------------------------------------------------------------
Seccion '2. Arranque real (mismo camino que OptiLow.ps1) y tiempos de apertura'
$codigo = @(Start-OptiLowInterfaz -Raiz $raiz -Opciones @{ Demo = $true; SinElevar = $false; RenderizadoSoftware = $false } -SinBucle)[-1]
$ui = $global:OptiLowUI
T 'Start-OptiLowInterfaz arrancó sin error (código 0)' ($codigo -eq 0)
if ($codigo -ne 0) {
    Write-Host ('El arranque falló: ' + ($global:PruebaErrores -join ' | ')) -ForegroundColor Red
    Write-Host ("RESULTADO: {0} bien, {1} fallos (abortada)" -f $script:bien, $script:mal) -ForegroundColor Red
    $env:ProgramData = $programDataReal
    exit 1
}
$c = $ui.C
$w = $c.VentanaPrincipal
T 'La ventana está visible' ($w.IsVisible)
T 'El panel "Cargando…" ya se ocultó' ($c.PanelCarga.Visibility -eq 'Collapsed')
T 'Modo de renderizado por defecto: Automático' ($ui.ModoRender -eq 'Automático')
foreach ($etapa in @('Script en marcha', 'WPF cargado', 'Ventana creada', 'Core/ cargado', 'Modules/ y Tweaks/ cargados', 'Lista de optimizaciones visible')) {
    T "Se midió la etapa '$etapa'" ($ui.Tiempos.Contains($etapa))
}
foreach ($par in $ui.Tiempos.GetEnumerator()) { Info ('{0,-40} {1,6} ms desde el inicio del proceso' -f $par.Key, $par.Value) }
T 'La barra de estado muestra "Abierto en X,X s"' ($c.TxtApertura.Text -like 'Abierto en *')
T 'La barra de estado muestra el modo y la capacidad gráfica' ($c.TxtRender.Text -like 'Render: *Capacidad gráfica: nivel *')
T 'La ventana tiene el tamaño inicial recortado al área de trabajo' (($w.Width -le [System.Windows.SystemParameters]::WorkArea.Width) -and ($w.Height -le [System.Windows.SystemParameters]::WorkArea.Height))
T 'MinWidth 860 y MinHeight 460' (($w.MinWidth -eq 860) -and ($w.MinHeight -eq 460))
T 'La lista tiene una fila por cada optimización registrada' ($ui.Filas.Count -eq @(Get-Tweak).Count -and $ui.Filas.Count -ge 3)
T 'Con -Demo el selector de datos simulados es visible' ($c.PanelDemo.Visibility -eq 'Visible')

# Sin -Demo el selector no existe (ventana auxiliar sin mostrar)
$ventanaAux = New-OptiLowVentana
$demoAux = $ventanaAux.FindName('PanelDemo')
T 'Sin -Demo el selector está oculto en el XAML (solo el código lo muestra)' ($demoAux.Visibility -eq 'Collapsed')
# New-OptiLowVentana reemplazó $ui.C: se restaura el de la ventana real
$ui.C = $c; $ui.PincelCache = @{}
$ventanaAux = $null

Seccion '3. Controles con nombre y pestañas'
$requeridos = @('VentanaPrincipal', 'Navegacion', 'NavDiagnostico', 'NavOptimizaciones', 'NavInicio', 'NavRespaldo', 'NavRegistro',
    'VistaDiagnostico', 'VistaOptimizaciones', 'VistaInicio', 'VistaRespaldo', 'VistaRegistro', 'BtnActualizarDiag', 'BtnSeleccionarRec',
    'BtnQuitarSel', 'BtnAplicar', 'ChkOmitirPunto', 'BtnActualizarSesiones', 'BtnDeshacer', 'BtnCopiarLog', 'BtnAbrirLogs', 'BtnLimpiarLog',
    'ListaLog', 'ChkSoftware', 'PanelOptimizaciones', 'PanelDiagnostico', 'PanelSesiones', 'PanelBanners', 'BannerOtroUsuario',
    'BannerJournal', 'BannerSimulado', 'TxtEstadoTrabajo', 'TxtApertura', 'TxtRender', 'TxtDetalle', 'PanelCarga')
foreach ($n in $requeridos) { T "Existe el control '$n'" ($null -ne $c[$n]) }
T 'Hay exactamente cinco pestañas' ($c.Navegacion.Items.Count -eq 5)
$vistas = @('VistaDiagnostico', 'VistaOptimizaciones', 'VistaInicio', 'VistaRespaldo', 'VistaRegistro')
for ($i = 0; $i -lt 5; $i++) {
    $c.Navegacion.SelectedIndex = $i
    Invoke-BombearUI
    $visibles = @($vistas | Where-Object { $c[$_].Visibility -eq 'Visible' })
    T "Pestaña $($i + 1): solo se ve '$($vistas[$i])'" (($visibles.Count -eq 1) -and ($visibles[0] -eq $vistas[$i]))
}
$c.Navegacion.SelectedIndex = 0
T 'Programas de inicio es un marcador de la fase 6' ($c.TxtInicioMarcador.Text -match 'fase 6')

Seccion '4. Trabajos de arranque: motor, estados y diagnóstico (en segundo plano)'
$ok = Wait-UI -Condicion { (-not $global:OptiLowUI.Trabajo) -and $global:OptiLowUI.Hardware } -LimiteMs 180000
T 'El motor, los estados y el diagnóstico terminaron' $ok
T 'Todas las filas salieron de "Comprobando"' (@($ui.Filas.Values | Where-Object { $_.Estado -eq 'Comprobando' }).Count -eq 0)
T 'Hay hardware y recomendaciones para cada optimización' (($null -ne $ui.Hardware) -and ($ui.Recomendados.Count -eq $ui.Filas.Count))
T 'El diagnóstico se pintó (perfil y recomendaciones)' ($c.PanelDiagnostico.Children.Count -gt 8)
$textoDiag = (@($c.PanelDiagnostico.Children | ForEach-Object { if ($_ -is [System.Windows.Controls.TextBlock]) { $_.Text } }) -join "`n")
T 'El diagnóstico muestra PERFIL y "completado en"' (($textoDiag -match 'PERFIL: ') -and ($textoDiag -match 'completado en'))
T 'La cola de log llegó a la vista del registro' ($c.ListaLog.Items.Count -gt 0)
T 'No quedó ningún trabajo en curso y los botones están activos' ((-not $ui.Trabajo) -and $c.BtnActualizarDiag.IsEnabled -and $c.BtnQuitarSel.IsEnabled)
Info ("Estados: " + (($ui.Filas.Keys | ForEach-Object { "$_=$($ui.Filas[$_].Estado)" }) -join ', '))
Info ("Perfil: $($ui.Hardware.Perfil). Diagnóstico en $([math]::Round($ui.Hardware.DuracionMs / 1000, 1)) s.")
$j = Get-Content -LiteralPath (Join-Path $global:OptiLow.DirLogs ('OptiLow_{0:yyyy-MM-dd}.log' -f (Get-Date))) -Raw
T 'El log en archivo registra los tiempos de arranque' ($j -match 'Tiempos de arranque')

Seccion '5. La interfaz no se congela durante un trabajo'
$ui.Ticks.Clear(); $ui.MedirTicks = $true
$iniciado = Start-TrabajoUI -Nombre 'prueba' -Texto 'prueba de fluidez' -Parametros @{ Milisegundos = 2500 } -AlTerminar { param($r) $global:PruebaTerminado = $r }
T 'Start-TrabajoUI aceptó el trabajo de prueba' $iniciado
T 'Mientras corre hay un trabajo en curso' ([bool]$ui.Trabajo)
T 'Solo un trabajo a la vez: un segundo Start-TrabajoUI se rechaza' (-not (Start-TrabajoUI -Nombre 'prueba' -Parametros @{ Milisegundos = 100 }))
Invoke-BombearUI
T 'La barra de estado dice "Trabajando…"' ($c.TxtEstadoTrabajo.Text -like 'Trabajando:*')
T 'Los botones de acción se desactivan durante el trabajo' ((-not $c.BtnActualizarDiag.IsEnabled) -and (-not $c.BtnQuitarSel.IsEnabled) -and (-not $c.BtnAplicar.IsEnabled) -and (-not $c.BtnDeshacer.IsEnabled) -and (-not $c.BtnActualizarSesiones.IsEnabled) -and (-not $c.ChkOmitirPunto.IsEnabled))
$antesLineas = $c.ListaLog.Items.Count
$global:PruebaTerminado = $null
[void](Wait-UI -Condicion { $null -ne $global:PruebaTerminado } -LimiteMs 20000)
T 'El trabajo terminó y su manejador se ejecutó en el hilo de la interfaz' ($null -ne $global:PruebaTerminado)
T 'El trabajo devolvió su resultado' ((@($global:PruebaTerminado.Salida) -contains 'listo') -and (-not $global:PruebaTerminado.Error))
T 'Los botones se reactivan al terminar' ($c.BtnActualizarDiag.IsEnabled -and $c.BtnQuitarSel.IsEnabled -and $c.ChkOmitirPunto.IsEnabled)
T 'La barra de estado vuelve a "Listo"' ($c.TxtEstadoTrabajo.Text -eq 'Listo')
T 'Las líneas de log del trabajo llegaron a la vista por la cola' ($c.ListaLog.Items.Count -gt $antesLineas)
$ui.MedirTicks = $false
$marcas = @($ui.Ticks)
$huecos = @(); for ($i = 1; $i -lt $marcas.Count; $i++) { $huecos += (($marcas[$i] - $marcas[$i - 1]) * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency) }
T 'El temporizador latió durante el trabajo (al menos 8 veces)' ($marcas.Count -ge 8)
if ($huecos.Count -gt 0) {
    $maxHueco = ($huecos | Measure-Object -Maximum).Maximum
    Info ("Huecos entre latidos: {0} latidos, máximo {1:N0} ms, media {2:N0} ms" -f $marcas.Count, $maxHueco, ($huecos | Measure-Object -Average).Average)
    T 'Ningún hueco entre latidos pasa de 250 ms (la interfaz no se congeló)' ($maxHueco -le 250)
}

Seccion '6. Cierre con trabajo en curso'
Reset-Dialogos
T 'Sin trabajo en curso se puede cerrar sin preguntar' ((Test-PuedeCerrarUI) -and ($global:PruebaDialogos.Count -eq 0))
[void](Start-TrabajoUI -Nombre 'prueba' -Texto 'prueba de cierre' -Parametros @{ Milisegundos = 1200 })
$global:PruebaRespuestas.Enqueue(0)
T 'Con trabajo en curso y respuesta "Seguir esperando", NO se cierra' (-not (Test-PuedeCerrarUI))
T 'La pregunta avisa de que lo aplicado a medias queda en el journal' (($global:PruebaDialogos.Count -eq 1) -and ($global:PruebaDialogos[0].Mensaje -match 'journal'))
$global:PruebaRespuestas.Enqueue(1)
T 'Con trabajo en curso y respuesta "Cerrar de todos modos", se cierra' (Test-PuedeCerrarUI)
[void](Esperar-Libre 20000)

Seccion '7. Aplicar seleccionadas: confirmación, punto de restauración y una sola sesión (con funciones de prueba)'
# Funciones de prueba en el hilo de la interfaz: administrador y journal "listos"
$global:PruebaAdmin = $true
function global:Test-EsAdministrador { return [bool]$global:PruebaAdmin }
$global:OptiLow.DirRespaldos = Join-Path $tmp 'backups-falsos'
Update-BannersUI; Update-EstadoBotonesUI

# Funciones de prueba en el runspace de trabajo (nada toca el sistema ni el journal real)
$global:OptiLowScriptsTrabajo['stubs'] = @'
$global:StubNueva = 0; $global:StubPuntos = 0; $global:StubLotes = 0; $global:StubProteccion = 0; $global:StubIds = @(); $global:StubModoPunto = 'Creado'
function global:Assert-JournalListo { param([switch]$Completo) }
function global:Start-JournalSesion { param([switch]$Nueva) if ($Nueva) { $global:StubNueva++ }; 'sesion-falsa' }
function global:New-PuntoRestauracion {
    param([string]$Descripcion)
    $global:StubPuntos++
    switch ($global:StubModoPunto) {
        'Creado'    { return [pscustomobject]@{ Creado = $true; Motivo = 'Creado'; Detalle = 'Punto número 1.'; Metodo = 'prueba'; SequenceNumber = 1; PuntoReciente = $null } }
        'Desactivada' { return [pscustomobject]@{ Creado = $false; Motivo = 'Desactivada'; Detalle = 'La Protección del sistema parece desactivada.'; Metodo = ''; SequenceNumber = $null; PuntoReciente = $null } }
        'Reciente'  { return [pscustomobject]@{ Creado = $false; Motivo = 'YaExisteReciente'; Detalle = 'Ya existe uno.'; Metodo = 'prueba'; SequenceNumber = $null; PuntoReciente = [pscustomobject]@{ Secuencia = 7; Descripcion = 'Punto de prueba'; Fecha = (Get-Date).AddHours(-3) } } }
        default     { return [pscustomobject]@{ Creado = $false; Motivo = 'ErrorDeSistema'; Detalle = 'Error simulado.'; Metodo = 'prueba'; SequenceNumber = $null; PuntoReciente = $null } }
    }
}
function global:Enable-ProteccionSistema { $global:StubProteccion++; $global:StubModoPunto = 'Creado'; [pscustomobject]@{ Activada = $true; Motivo = 'Activa'; Detalle = 'Activa.' } }
function global:Invoke-TweaksLote {
    param([string[]]$Ids)
    $global:StubLotes++; $global:StubIds = @($Ids)
    $res = @($Ids | ForEach-Object { [pscustomobject]@{ Id = $_; Nombre = "Nombre de $_"; Estado = 'Aplicado'; Detalle = '1 elemento(s) cambiados.'; Cambiados = 1; Requiere = 'Reiniciar'; Reversible = $true; Riesgo = 'Bajo' } })
    [pscustomobject]@{ Resultados = $res; Requiere = 'Reiniciar'; TweaksQueRequieren = @($res) }
}
'listo'
'@
$global:OptiLowScriptsTrabajo['stubs-modo'] = @'
param($Modo)
$global:StubModoPunto = $Modo
'listo'
'@
$global:OptiLowScriptsTrabajo['stubs-contadores'] = @'
[pscustomobject]@{ Nueva = $global:StubNueva; Puntos = $global:StubPuntos; Lotes = $global:StubLotes; Proteccion = $global:StubProteccion; Ids = @($global:StubIds) }
'@
function Get-Contadores {
    $global:PruebaCont = $null
    [void](Start-TrabajoUI -Nombre 'stubs-contadores' -AlTerminar { param($r) $global:PruebaCont = (Get-ResultadoUnicoUI -Resultado $r) })
    [void](Wait-UI -Condicion { $null -ne $global:PruebaCont } -LimiteMs 20000)
    return $global:PruebaCont
}
function Set-ModoPunto { param([string]$Modo)
    [void](Start-TrabajoUI -Nombre 'stubs-modo' -Parametros @{ Modo = $Modo })
    [void](Esperar-Libre 20000) }

[void](Start-TrabajoUI -Nombre 'stubs')
T 'Las funciones de prueba del runspace se instalaron' (Esperar-Libre 20000)

# Estados fijos para que la prueba no dependa de este equipo
function Set-EstadosFijos { param([string]$Estado = 'Pendiente')
    Update-EstadosFilasUI -Estados @($ui.Filas.Keys | ForEach-Object { [pscustomobject]@{ Id = $_; Estado = $Estado; Detalle = '' } }) }
Set-EstadosFijos
$ids = @($ui.Filas.Keys)
$idA = $ids[0]; $idB = $ids[1]

# 7a. Camino feliz con punto creado. Se pasa por el Click real de la casilla.
Invoke-QuitarSeleccionUI
$ui.Filas[$idA].Check.IsChecked = $true; $ui.Filas[$idB].Check.IsChecked = $true
Update-SeleccionUI
T 'Hay 2 seleccionadas' (@(Get-IdsSeleccionadosUI).Count -eq 2)
T 'El texto de selección dice "2 seleccionada(s)"' ($c.TxtSeleccion.Text -like '2 seleccionada(s).*')
T 'Con administrador y journal (de prueba) el botón Aplicar está activo' ($c.BtnAplicar.IsEnabled)
Reset-Dialogos
$global:PruebaRespuestas.Enqueue(1)   # confirmar
Invoke-AplicarSeleccionUI
[void](Wait-UI -Condicion { (-not $global:OptiLowUI.Trabajo) -and ($global:PruebaDialogos.Count -ge 2) } -LimiteMs 60000)
[void](Esperar-Libre 60000)
$cont = Get-Contadores
T '7a: se mostró la confirmación y luego el resumen' (($global:PruebaDialogos.Count -ge 2) -and ($global:PruebaDialogos[0].Titulo -eq 'Confirmar cambios') -and ($global:PruebaDialogos[1].Titulo -like 'Resumen*'))
T '7a: el resumen dice que cada optimización se puede deshacer con el botón Deshacer de su fila' ($global:PruebaDialogos[1].Mensaje -match 'deshacer cada optimización con el botón Deshacer de su fila')
T '7a: la confirmación lista cada cambio con su descripción' (@($global:PruebaDialogos[0].Detalles).Count -ge 4)
T '7a: UNA sola sesión nueva del journal' ($cont.Nueva -eq 1)
T '7a: se intentó crear un punto de restauración (una vez)' ($cont.Puntos -eq 1)
T '7a: el lote se aplicó una vez con los Ids elegidos' (($cont.Lotes -eq 1) -and (@($cont.Ids | Sort-Object) -join ',') -eq ((@($idA, $idB) | Sort-Object) -join ','))
T '7a: el resumen avisa de reiniciar' ($global:PruebaDialogos[1].Advertencia -match 'REINICIA')
T '7a: tras aplicar se quita la selección' (@(Get-IdsSeleccionadosUI).Count -eq 0)

# 7b. Omitir el punto
Set-EstadosFijos; Reset-Dialogos
$ui.Filas[$idA].Check.IsChecked = $true
$c.ChkOmitirPunto.IsChecked = $true
$global:PruebaRespuestas.Enqueue(1)
Invoke-AplicarSeleccionUI
[void](Esperar-Libre 60000)
$c.ChkOmitirPunto.IsChecked = $false
$cont2 = Get-Contadores
T '7b: con "omitir" no se llama a New-PuntoRestauracion' ($cont2.Puntos -eq $cont.Puntos)
T '7b: la confirmación dice que NO se creará punto' ($global:PruebaDialogos[0].Mensaje -match 'NO se creará un punto')
T '7b: se abrió otra sesión (una por ejecución) y se aplicó el lote' (($cont2.Nueva -eq 2) -and ($cont2.Lotes -eq 2))

# 7c. Cancelar la confirmación: no se hace nada
Set-EstadosFijos; Reset-Dialogos
$ui.Filas[$idA].Check.IsChecked = $true
$global:PruebaRespuestas.Enqueue(0)
Invoke-AplicarSeleccionUI
[void](Esperar-Libre 20000)
$cont3 = Get-Contadores
T '7c: cancelar la confirmación no abre sesión ni aplica nada' (($cont3.Nueva -eq $cont2.Nueva) -and ($cont3.Lotes -eq $cont2.Lotes))

# 7d. Protección desactivada: se ofrece activarla avisando del espacio en disco
Set-ModoPunto 'Desactivada'
Set-EstadosFijos; Reset-Dialogos
$ui.Filas[$idA].Check.IsChecked = $true
$global:PruebaRespuestas.Enqueue(1)   # confirmar
$global:PruebaRespuestas.Enqueue(2)   # Activar protección
Invoke-AplicarSeleccionUI
[void](Esperar-Libre 60000)
$cont4 = Get-Contadores
$dlgProt = $global:PruebaDialogos | Where-Object { $_.Titulo -like 'Protección del sistema*' } | Select-Object -First 1
T '7d: se ofreció activar la protección' ($null -ne $dlgProt)
T '7d: el aviso dice que USA ESPACIO EN DISCO' ($dlgProt -and ($dlgProt.Advertencia -match 'ESPACIO EN DISCO'))
T '7d: se activó la protección una vez y luego se aplicó el lote' (($cont4.Proteccion -eq 1) -and ($cont4.Lotes -eq $cont3.Lotes + 1))
T '7d: sigue siendo UNA sola sesión nueva para esa ejecución' ($cont4.Nueva -eq $cont3.Nueva + 1)

# 7e. Ya existe un punto reciente: se muestra fecha y descripción
foreach ($caso in @(@{ Resp = 1; Aplica = $true }, @{ Resp = 0; Aplica = $false })) {
    Set-ModoPunto 'Reciente'
    Set-EstadosFijos; Reset-Dialogos
    $antes = Get-Contadores
    $ui.Filas[$idA].Check.IsChecked = $true
    $global:PruebaRespuestas.Enqueue(1); $global:PruebaRespuestas.Enqueue($caso.Resp)
    Invoke-AplicarSeleccionUI
    [void](Esperar-Libre 60000)
    $despues = Get-Contadores
    $dlgRec = $global:PruebaDialogos | Where-Object { $_.Titulo -like 'Ya existe un punto*' } | Select-Object -First 1
    T "7e: se muestra el punto reciente (respuesta $($caso.Resp))" ($dlgRec -and ($dlgRec.Mensaje -match 'Punto de prueba') -and ($dlgRec.Mensaje -match '\d{4}-\d{2}-\d{2}'))
    $esperado = $antes.Lotes; if ($caso.Aplica) { $esperado++ }
    T "7e: continuar con ese punto = $($caso.Aplica) -> lotes aplicados $esperado" ($despues.Lotes -eq $esperado)
}

# 7f. Error al crear el punto: se pregunta si continuar sabiendo que el journal sigue funcionando
Set-ModoPunto 'Error'
Set-EstadosFijos; Reset-Dialogos
$antes = Get-Contadores
$ui.Filas[$idA].Check.IsChecked = $true
$global:PruebaRespuestas.Enqueue(1); $global:PruebaRespuestas.Enqueue(1)
Invoke-AplicarSeleccionUI
[void](Esperar-Libre 60000)
$despues = Get-Contadores
$dlgErr = $global:PruebaDialogos | Where-Object { $_.Titulo -like 'No se creó el punto*' } | Select-Object -First 1
T '7f: se preguntó si continuar y se explicó que el journal sigue funcionando' ($dlgErr -and (($dlgErr.Detalles -join ' ') -match 'journal'))
T '7f: al continuar se aplicó el lote' ($despues.Lotes -eq $antes.Lotes + 1)
Set-ModoPunto 'Creado'

# 7g. Riesgo Alto o no reversible: advertencia APARTE; y banner de otro usuario repetido en la confirmación
Set-EstadosFijos; Reset-Dialogos
$defOriginal = $ui.Filas[$idA].Def
$copia = $defOriginal | Select-Object *
$copia.Riesgo = 'Alto'; $copia | Add-Member -NotePropertyName Reversible -NotePropertyValue $false -Force
$ui.Filas[$idA].Def = $copia
$ui.OtroUsuario = [pscustomobject]@{ Distinto = $true; UsuarioEscritorio = 'PC\otra'; UsuarioProceso = 'PC\yo' }
Update-BannersUI
T '7g: banner de otro usuario visible, con ambos nombres' (($c.BannerOtroUsuario.Visibility -eq 'Visible') -and ($c.TxtBannerOtroUsuario.Text -match 'PC\\otra') -and ($c.TxtBannerOtroUsuario.Text -match 'cuenta equivocada'))
$ui.Filas[$idA].Check.IsChecked = $true
$global:PruebaRespuestas.Enqueue(0)   # cancelar: solo interesa lo que se mostró
Invoke-AplicarSeleccionUI
$conf = $global:PruebaDialogos | Select-Object -First 1
T '7g: la confirmación lleva advertencia aparte de riesgo Alto / no reversible' ($conf.Advertencia -match 'riesgo ALTO' -and $conf.Advertencia -match 'no reversible')
T '7g: la confirmación repite el aviso de escritorio de otro usuario' ($conf.Advertencia -match 'ESCRITORIO DE OTRO USUARIO' -and $conf.Advertencia -match 'cuenta equivocada')
T '7g: el diálogo de confirmación se marca como Peligro' ($conf.Tipo -eq 'Peligro')
$ui.Filas[$idA].Def = $defOriginal
$ui.OtroUsuario = $null; Update-BannersUI
T '7g: sin otro usuario el banner desaparece' ($c.BannerOtroUsuario.Visibility -eq 'Collapsed')

# 7h. Filas aplicadas o que no aplican no se seleccionan
Update-EstadosFilasUI -Estados @([pscustomobject]@{ Id = $idA; Estado = 'Aplicado'; Detalle = '' }, [pscustomobject]@{ Id = $idB; Estado = 'NoAplica'; Detalle = '' })
$ui.Filas[$idA].Check.IsChecked = $true
Invoke-ClicCasillaUI -Id $idA
T '7h: una fila ya aplicada no se queda marcada' ($ui.Filas[$idA].Check.IsChecked -ne $true)
$ui.Filas[$idB].Check.IsChecked = $true
Invoke-ClicCasillaUI -Id $idB
T '7h: una fila que no aplica no se queda marcada' ($ui.Filas[$idB].Check.IsChecked -ne $true)
T '7h: se explica por qué' ($c.TxtSeleccion.Text -match 'no se puede seleccionar')
Set-EstadosFijos

Seccion '8. Modo simulado (-Demo): solo para ver'
$global:OptiLow.SimulacionActiva = $false
$global:OptiLow.DirRespaldos = Join-Path $tmp 'backups-falsos'
Update-EstadoBotonesUI
$c.DemoBajo.IsChecked = $true
Invoke-DiagnosticoUI
[void](Esperar-Libre 120000)
T '8: con datos simulados el diagnóstico es simulado' ($ui.Simulado -and $ui.Hardware.Simulado -and $ui.Hardware.Perfil -eq 'Bajo')
T '8: aparece el banner SIMULADO' ($c.BannerSimulado.Visibility -eq 'Visible')
T '8: Aplicar y Deshacer quedan desactivados' ((-not $c.BtnAplicar.IsEnabled) -and (-not $c.BtnDeshacer.IsEnabled))
T '8: el motivo habla de datos simulados' ((Get-MotivoNoAplicarUI) -match 'simulados')
T '8: SimulacionActiva está fijada en la interfaz' ($global:OptiLow.SimulacionActiva -eq $true)
$global:OptiLowScriptsTrabajo['verif-sim'] = @'
$global:StubOk = $true
try { Assert-JournalListo -Completo; 'no-bloqueo' } catch { $_.Exception.Message }
'@
# Assert-JournalListo real en el runspace (se reinstala porque el de prueba lo sustituía)
$global:OptiLowScriptsTrabajo['reponer-assert'] = "Import-OptiLowArchivo -Ruta (Join-Path '$raiz' 'Core\Journal.ps1')"
[void](Start-TrabajoUI -Nombre 'reponer-assert'); [void](Esperar-Libre 20000)
$global:PruebaMsg = $null
[void](Start-TrabajoUI -Nombre 'verif-sim' -AlTerminar { param($r) $global:PruebaMsg = (@($r.Salida) -join ' ') })
[void](Wait-UI -Condicion { $null -ne $global:PruebaMsg } -LimiteMs 20000)
T '8: el motor del runspace rechaza cualquier escritura con datos simulados' ($global:PruebaMsg -match 'SIMULADO')
# Aplicar con datos simulados: el botón está desactivado, pero aunque se llame a la función se rechaza
Reset-Dialogos
Set-EstadosFijos
$ui.Filas[$idA].Check.IsChecked = $true
Invoke-AplicarSeleccionUI
T '8: Invoke-AplicarSeleccionUI rechaza con un diálogo y no lanza ningún trabajo' (($global:PruebaDialogos.Count -eq 1) -and ($global:PruebaDialogos[0].Titulo -eq 'No se puede aplicar') -and (-not $ui.Trabajo))
Invoke-QuitarSeleccionUI
Invoke-SeleccionarRecomendadasUI
$marcadas = @(Get-IdsSeleccionadosUI)
$recomendadas = @($ui.Filas.Values | Where-Object { $_.Recomendado })
T '8: "Seleccionar recomendadas" sí funciona con datos simulados' (($recomendadas.Count -ge 1) -and ($marcadas.Count -eq $recomendadas.Count))
Invoke-QuitarSeleccionUI
T '8: "Quitar selección" deja todo sin marcar' (@(Get-IdsSeleccionadosUI).Count -eq 0)
$c.DemoReal.IsChecked = $true
Invoke-DiagnosticoUI
[void](Esperar-Libre 120000)
T '8: volver a "Este equipo" desactiva la simulación' ((-not $ui.Simulado) -and ($c.BannerSimulado.Visibility -eq 'Collapsed') -and ($global:OptiLow.SimulacionActiva -eq $false))

Seccion '9. Banners y cabecera'
$global:PruebaAdmin = $true
$global:OptiLow.DirRespaldos = $null
Update-BannersUI
T '9: administrador sin carpeta de respaldos -> banner que lo explica' (($c.BannerJournal.Visibility -eq 'Visible') -and ($c.TxtBannerJournal.Text -match 'carpeta de respaldos'))
T '9: la cabecera dice "Journal: NO disponible"' ($c.TxtJournal.Text -match 'NO disponible')
$global:PruebaAdmin = $false
Update-BannersUI; Update-EstadoBotonesUI
T '9: sin administrador -> banner de modo limitado' (($c.BannerJournal.Visibility -eq 'Visible') -and ($c.TxtBannerJournal.Text -match 'SIN permisos de administrador'))
T '9: sin administrador el botón Aplicar está desactivado' (-not $c.BtnAplicar.IsEnabled)
$global:PruebaAdmin = $true
$global:OptiLow.DirRespaldos = Join-Path $tmp 'backups-falsos'
Update-BannersUI; Update-EstadoBotonesUI
T '9: con administrador y journal no hay banner de journal' ($c.BannerJournal.Visibility -eq 'Collapsed')

Seccion '10. Respaldo y restauración (mínimo): lista de sesiones y deshacer'
# Journal falso en la carpeta temporal para que Get-JournalSesiones lo lea (en el runspace se usa la función real)
$dirBk = $global:OptiLow.DirRespaldos
[void](New-Item -ItemType Directory -Path $dirBk -Force)
$sesionFalsa = @{ Version = 1; Id = '20260101-000000000-1'; Inicio = '2026-01-01T00:00:00'; Estado = 'Activo'; Entradas = @(@{ Indice = 1; Tipo = 'Nota'; TweakId = 'prueba-tweak'; Descripcion = 'nota' }) }
[System.IO.File]::WriteAllText((Join-Path $dirBk '20260101-000000000-1.json'), (ConvertTo-Json -InputObject $sesionFalsa -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
# El runspace de trabajo apunta a la carpeta temporal de la prueba
$global:OptiLowScriptsTrabajo['apuntar-backups'] = "param(`$Dir) `$global:OptiLow.DirRespaldos = `$Dir; function global:Test-AclRespaldos { [pscustomobject]@{ Valido = `$true; Motivos = @() } }; function global:Test-EsAdministrador { `$true }; 'listo'"
[void](Start-TrabajoUI -Nombre 'apuntar-backups' -Parametros @{ Dir = $dirBk }); [void](Esperar-Libre 20000)
$ui.SesionesCargadas = $false
Update-SesionesUI
[void](Esperar-Libre 30000)
T '10: la lista de sesiones muestra la sesión del journal' (($c.PanelSesiones.Children.Count -ge 1) -and ($c.TxtRespaldoInfo.Text -match '1 ejecución'))
# Fase 6a: tarjeta comprensible (fecha local, estado en palabras de usuario, Id solo en el tooltip)
$tarjeta = $c.PanelSesiones.Children[0]
$textoTarjeta = (@($tarjeta.Child.Children | ForEach-Object { if ($_ -is [System.Windows.Controls.TextBlock]) { $_.Text + ' ' + (@($_.Inlines | ForEach-Object { $_.Text }) -join '') } }) -join ' | ')
T '10: la tarjeta dice «Se puede deshacer» (no «Activo») y no muestra el Id' (($textoTarjeta -match 'Se puede deshacer') -and ($textoTarjeta -notmatch 'Activo') -and ($textoTarjeta -notmatch '20260101-000000000-1'))
T '10: la tarjeta muestra la fecha en formato local, no ISO' (($textoTarjeta -notmatch '2026-01-01T') -and ($textoTarjeta -match '2026') -and ($textoTarjeta -notmatch ':00:00'))
T '10: el Id de la sesión está en el tooltip de la tarjeta' ([string]$tarjeta.ToolTip -match '20260101-000000000-1')
Reset-Dialogos
$global:PruebaRespuestas.Enqueue(1)   # Deshacer
Invoke-DeshacerUI
[void](Esperar-Libre 60000)
T '10: deshacer pide confirmación con el Id de la sesión' (($global:PruebaDialogos.Count -ge 1) -and ($global:PruebaDialogos[0].Titulo -like 'Deshacer*') -and (($global:PruebaDialogos[0].Detalles -join ' ') -match '20260101-000000000-1'))
T '10: tras deshacer se muestra el resultado' (@($global:PruebaDialogos | Where-Object { $_.Titulo -like 'Sesión deshecha*' -or $_.Titulo -like 'Restauración parcial*' -or $_.Titulo -like 'Error al deshacer*' }).Count -ge 1)
Info ("Diálogos mostrados al deshacer: " + (($global:PruebaDialogos | ForEach-Object { $_.Titulo }) -join ' | '))

# Fase 6a: deshacer UNA optimización desde su fila, con aviso de conflicto con una sesión posterior
$jsonX = Join-Path $tmp 'x6a.json'
[System.IO.File]::WriteAllText($jsonX, '{"k":2}', (New-Object System.Text.UTF8Encoding($false)))
function Nueva-EntradaJson($Indice, $Tweak, $Orig, $Nuevo) { @{ Indice = $Indice; Hora = '2026-01-02T00:00:00'; Estado = 'Aplicada'; TweakId = $Tweak; Tipo = 'Json'; Descripcion = "JSON x6a.json : k"; Ruta = $jsonX; Clave = @('k'); ClaveExistia = $true; ValorOriginal = $Orig; IntermediosCreados = @(); ValorNuevo = $Nuevo; CopiaEmergencia = 'no-importa' } }
$sx = @{ Version = 1; Id = '20260102-000000000-1'; Inicio = '2026-01-02T00:00:00'; Estado = 'Activo'; Entradas = @(Nueva-EntradaJson 1 'prueba-x' 0 1) }
$sy = @{ Version = 1; Id = '20260103-000000000-1'; Inicio = '2026-01-03T00:00:00'; Estado = 'Activo'; Entradas = @(Nueva-EntradaJson 1 'prueba-y' 1 2) }
foreach ($sf in @($sx, $sy)) { [System.IO.File]::WriteAllText((Join-Path $dirBk ($sf.Id + '.json')), (ConvertTo-Json -InputObject $sf -Depth 100), (New-Object System.Text.UTF8Encoding($false))) }
Reset-Dialogos
$global:PruebaRespuestas.Enqueue(1)   # confirmar «Deshacer»
$global:PruebaRespuestas.Enqueue(0)   # en el aviso de conflicto: Cancelar
Invoke-DeshacerTweakUI -Id 'prueba-x'
[void](Esperar-Libre 60000); [void](Esperar-Libre 60000)
$titulos = @($global:PruebaDialogos | ForEach-Object { $_.Titulo })
T '6a: deshacer una optimización pide confirmación y luego avisa del conflicto con la sesión posterior' (($titulos -contains 'Deshacer una optimización') -and ($titulos -contains 'Deshacer podría borrar otros cambios'))
$dlgAviso = $global:PruebaDialogos | Where-Object { $_.Titulo -eq 'Deshacer podría borrar otros cambios' } | Select-Object -First 1
T '6a: el aviso nombra la optimización posterior y el botón predeterminado es Cancelar' ($dlgAviso -and (($dlgAviso.Detalles -join ' ') -match 'prueba-y') -and ($dlgAviso.Predeterminado -eq 0))
T '6a: al cancelar el aviso NO se tocó nada (k sigue en 2)' ((([System.IO.File]::ReadAllText($jsonX) | ConvertFrom-Json).k) -eq 2)
Reset-Dialogos
$global:PruebaRespuestas.Enqueue(1)   # confirmar «Deshacer»
$global:PruebaRespuestas.Enqueue(1)   # en el aviso: «Deshacer de todos modos»
Invoke-DeshacerTweakUI -Id 'prueba-x'
[void](Esperar-Libre 60000); [void](Esperar-Libre 60000)
$titulos = @($global:PruebaDialogos | ForEach-Object { $_.Titulo })
T '6a: tras confirmar explícitamente se deshace y se muestra el resultado' (($titulos -contains 'Optimización deshecha') -and ((([System.IO.File]::ReadAllText($jsonX) | ConvertFrom-Json).k) -eq 0))

Seccion '11. Teclado'
$c.Navegacion.SelectedIndex = 0
Invoke-BombearUI
$interactivos = New-Object System.Collections.ArrayList
function Buscar-Interactivos { param($Nodo)
    if (-not $Nodo) { return }
    if (($Nodo -is [System.Windows.Controls.Button]) -or ($Nodo -is [System.Windows.Controls.CheckBox]) -or ($Nodo -is [System.Windows.Controls.RadioButton]) -or ($Nodo -is [System.Windows.Controls.ListBox])) {
        [void]$interactivos.Add($Nodo)
    }
    $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Nodo)
    for ($i = 0; $i -lt $n; $i++) { Buscar-Interactivos ([System.Windows.Media.VisualTreeHelper]::GetChild($Nodo, $i)) }
}
Buscar-Interactivos $w.Content
T 'Se encontraron controles interactivos' ($interactivos.Count -gt 10)
# (un ListBox no es tabulable en sí: Tab entra en el elemento seleccionado y las flechas se mueven dentro)
$noEnfocables = @($interactivos | Where-Object { $_.Name -and ((-not $_.Focusable) -or (($_ -isnot [System.Windows.Controls.ListBox]) -and (-not $_.IsTabStop))) })
T 'Todos los controles interactivos con nombre son enfocables y tabulables' ($noEnfocables.Count -eq 0)
if ($noEnfocables.Count -gt 0) { Info ('No enfocables: ' + (($noEnfocables | ForEach-Object { $_.Name }) -join ', ')) }
# TabIndex monótono respecto al orden visual dentro de cada vista (por filas y luego por X)
foreach ($v in @(@{ N = 0; V = 'VistaDiagnostico' }, @{ N = 1; V = 'VistaOptimizaciones' }, @{ N = 3; V = 'VistaRespaldo' }, @{ N = 4; V = 'VistaRegistro' })) {
    $c.Navegacion.SelectedIndex = $v.N
    Invoke-BombearUI
    $lista = New-Object System.Collections.ArrayList
    $interactivos.Clear()
    Buscar-Interactivos $c[$v.V]
    $ctl = @($interactivos | Where-Object { $_.Name -and $_.IsVisible -and ($_ -isnot [System.Windows.Controls.ListBox] -or $_.Name -eq 'ListaLog') })
    $ordenTab = @($ctl | Sort-Object { $_.TabIndex })
    $claves = @($ordenTab | ForEach-Object { $r = Get-RectEn -El $_ -Raiz $w.Content; [math]::Round($r.Y / 24) * 100000 + $r.X })
    $monotono = $true; for ($i = 1; $i -lt $claves.Count; $i++) { if ($claves[$i] -lt $claves[$i - 1]) { $monotono = $false } }
    T "TabIndex sigue el orden visual en $($v.V) ($(@($ordenTab | ForEach-Object { $_.Name }) -join ' > '))" $monotono
}
T 'La navegación (TabIndex 0) va antes que el contenido' ($c.Navegacion.TabIndex -eq 0 -and $c.BtnActualizarDiag.TabIndex -gt 0)
$c.Navegacion.SelectedIndex = 0
# Botones de diálogo con IsDefault / IsCancel y respuesta por teclado: se prueba el diálogo REAL
$global:PruebaDlg = $null
$tm = New-Object System.Windows.Threading.DispatcherTimer
$tm.Interval = [TimeSpan]::FromMilliseconds(400)
$tm.Add_Tick({
        param($s, $e)
        $s.Stop()
        $dlg = $global:OptiLowUI.C.VentanaPrincipal.OwnedWindows | Select-Object -First 1
        if (-not $dlg) { $global:PruebaDlg = [pscustomobject]@{ Hay = $false }; return }
        $botones = @($dlg.Content.Children[1].Children)
        $info = [pscustomobject]@{
            Hay = $true; Cuantos = $botones.Count
            Default = @($botones | Where-Object { $_.IsDefault }).Count
            Cancel = @($botones | Where-Object { $_.IsCancel }).Count
            Enfocables = @($botones | Where-Object { $_.Focusable -and $_.IsTabStop }).Count
            Titulo = $dlg.Title
        }
        $global:PruebaDlg = $info
        # Simula pulsar "Aplicar" (índice 1) con el patrón Invoke de accesibilidad
        $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($botones[1])
        $peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Invoke).Invoke()
    })
# Show-DialogoOptiLow de la prueba está sustituido: se vuelve a cargar el real para esta comprobación
Restaurar-Entorno
$global:PruebaDlg = $null
$tm.Start()
$resp = Show-DialogoOptiLow -Titulo 'Prueba de diálogo' -Mensaje 'Texto' -Detalles @('uno', 'dos') -Botones @('Cancelar', 'Aplicar') -Predeterminado 0 -Cancelar 0
T 'Diálogo real: se abrió como ventana propia de la principal' ($global:PruebaDlg -and $global:PruebaDlg.Hay)
T 'Diálogo real: exactamente un botón IsDefault y uno IsCancel' ($global:PruebaDlg.Default -eq 1 -and $global:PruebaDlg.Cancel -eq 1)
T 'Diálogo real: los botones son enfocables' ($global:PruebaDlg.Enfocables -eq 2)
T 'Diálogo real: pulsar el segundo botón devuelve su índice (1)' ($resp -eq 1)
$ui.C = $c

Seccion '11b. Diagnóstico: cada forma de datos se pinta completa (incluida una VM con disco virtual) y un error no corta el resto'
function Get-TextoDiag { return (@($c.PanelDiagnostico.Children | ForEach-Object { if ($_ -is [System.Windows.Controls.TextBlock]) { if ($_.Text) { $_.Text } else { (@($_.Inlines | ForEach-Object { $_.Text }) -join '') } } }) -join "`n") }
$ui.C = $c
$ui.Recomendados = @{}
T 'Add-FilaDatoUI acepta una etiqueta vacía (la causa del fallo en la VM)' ($(try { $c.PanelDiagnostico.Children.Clear(); Add-FilaDatoUI -Etiqueta '' -Valor 'línea sin etiqueta'; $true } catch { $false }))
foreach ($perfilSim in @('Bajo', 'Medio', 'Alto')) {
    $h = New-HardwareSimulado -Perfil $perfilSim
    $fallos = Show-DiagnosticoUI -Hardware $h -Recomendados @()
    $txt = Get-TextoDiag
    T "Perfil simulado $perfilSim`: se pinta completo (Portátil, Arranque, Programas de inicio, administrado, PERFIL y recomendaciones)" (($fallos -eq 0) -and ($txt -match 'Portátil') -and ($txt -match 'Arranque') -and ($txt -match 'Programas de inicio') -and ($txt -match 'Equipo administrado') -and ($txt -match "PERFIL: $perfilSim") -and ($txt -match 'Recomendaciones'))
}
# VM: disco virtual (la línea "(disco virtual...)" no tiene etiqueta; en un equipo real no aparece)
$hVm = New-HardwareSimulado -Perfil Bajo
$hVm.EsMaquinaVirtual = $true; $hVm.Hipervisor = 'VirtualBox'; $hVm.MotivoVM = 'fabricante innotek GmbH'
$hVm.Disco.EsVirtual = $true
$hVm = Complete-Diagnostico -Hardware $hVm
$fallos = Show-DiagnosticoUI -Hardware $hVm -Recomendados @()
$txt = Get-TextoDiag
T 'VM con disco virtual: se pinta la línea "(disco virtual...)" y TODO lo que va después' (($fallos -eq 0) -and ($txt -match 'disco virtual') -and ($txt -match 'Máquina virtual') -and ($txt -match 'Portátil') -and ($txt -match 'Arranque') -and ($txt -match 'Equipo administrado') -and ($txt -match 'PERFIL: '))
# Datos que faltan (RAM, disco, CPU y arranque desconocidos)
$hVacio = New-HardwareSimulado -Perfil Medio
$hVacio.RAM = $null; $hVacio.Disco = $null; $hVacio.CPU = $null; $hVacio.GPUs = @(); $hVacio.ArranqueDias = $null; $hVacio.InicioRapido = $null; $hVacio.ProgramasInicio = $null; $hVacio.Administracion = $null
$fallos = Show-DiagnosticoUI -Hardware $hVacio -Recomendados @()
$txt = Get-TextoDiag
T 'Con datos que faltan: se pinta con "desconocido" y sin errores' (($fallos -eq 0) -and ($txt -match 'desconocido') -and ($txt -match 'PERFIL: '))
if ($ui.Hardware) {
    $fallos = Show-DiagnosticoUI -Hardware $ui.Hardware -Recomendados @()
    T 'El diagnóstico real de este equipo se pinta sin errores' ($fallos -eq 0)
}
# Un error al pintar una parte NO corta el resto
function global:Format-RamHw { throw 'error de prueba en la RAM' }
$fallos = Show-DiagnosticoUI -Hardware (New-HardwareSimulado -Perfil Bajo) -Recomendados @()
$txt = Get-TextoDiag
[void](Invoke-VaciarColaLogUI -Tope 5000)
T 'Un fallo en una parte: se omite, se avisa en la pestaña y el RESTO se pinta' (($fallos -eq 1) -and ($txt -match 'RAM: no se pudo mostrar') -and ($txt -match 'Portátil') -and ($txt -match 'PERFIL: Bajo') -and ($txt -match 'Recomendaciones'))
T 'El fallo parcial queda en el registro' (@($ui.LineasLog | Where-Object { $_ -match 'no se pudo mostrar «RAM»' }).Count -ge 1)
Import-OptiLowArchivo -Ruta (Join-Path $raiz 'Core\Consola.ps1')
# Si el diagnóstico falla (error del trabajo, sin datos o fallo total al pintar) la pestaña lo dice con claridad
$scriptOriginal = $global:OptiLowScriptsTrabajo['diagnostico']
$global:OptiLowScriptsTrabajo['diagnostico'] = "param(`$Perfil) throw 'fallo simulado del diagnóstico'"
Invoke-DiagnosticoUI; [void](Esperar-Libre 30000)
$txt = Get-TextoDiag
T 'Si el trabajo de diagnóstico falla, la pestaña muestra un mensaje claro y cómo reintentar' (($txt -match 'No se pudo completar el diagnóstico') -and ($txt -match 'fallo simulado') -and ($txt -match 'Actualizar diagnóstico'))
$global:OptiLowScriptsTrabajo['diagnostico'] = "param(`$Perfil) `$null"
Invoke-DiagnosticoUI; [void](Esperar-Libre 30000)
T 'Si el diagnóstico no devuelve datos, la pestaña lo dice' ((Get-TextoDiag) -match 'no devolvió datos')
$global:OptiLowScriptsTrabajo['diagnostico'] = $scriptOriginal
function global:Show-DiagnosticoUI { param($Hardware, $Recomendados) throw 'fallo total de prueba al pintar' }
Invoke-DiagnosticoUI; [void](Esperar-Libre 120000)
$txt = Get-TextoDiag
T 'Si falla todo el pintado: mensaje claro en la pestaña' (($txt -match 'no se pudo mostrar') -and ($txt -match 'fallo total de prueba'))
T 'Aunque falle el pintado, las recomendaciones y los botones se actualizan ("Seleccionar recomendadas" activo)' (($ui.Recomendados.Count -gt 0) -and $c.BtnSeleccionarRec.IsEnabled)
Import-OptiLowArchivo -Ruta (Join-Path $raiz 'UI\Interfaz.ps1')
Invoke-DiagnosticoUI; [void](Esperar-Libre 120000)
T 'Tras restaurar, el diagnóstico real se vuelve a pintar completo' ((Get-TextoDiag) -match 'PERFIL: ')

Seccion '11c. Usabilidad: Enter, menú lateral, registro, ayuda de deshacer y tooltips de botones desactivados'
Set-EstadosFijos
$cb = $ui.Filas[$idA].Check
$cb.IsChecked = $false
T 'Enter marca una casilla de optimización' ((Invoke-EnterControlUI -Elemento $cb) -and ($cb.IsChecked -eq $true))
T 'Enter la desmarca' ((Invoke-EnterControlUI -Elemento $cb) -and ($cb.IsChecked -ne $true))
T 'Enter en una fila ya aplicada no la deja marcada (mismo manejador que el clic)' ($(Update-EstadosFilasUI -Estados @([pscustomobject]@{ Id = $idA; Estado = 'Aplicado'; Detalle = '' }); [void](Invoke-EnterControlUI -Elemento $cb); ($cb.IsChecked -ne $true)))
Set-EstadosFijos
$ChkO = $c.ChkOmitirPunto; $ChkO.IsChecked = $false
T 'Enter también marca "Omitir el punto de restauración"' ((Invoke-EnterControlUI -Elemento $ChkO) -and ($ChkO.IsChecked -eq $true))
$ChkO.IsChecked = $false
T 'Enter en un botón no lo gestiona el manejador de casillas (el botón ya reacciona solo)' (-not (Invoke-EnterControlUI -Elemento $c.BtnQuitarSel))
T 'Enter no hace nada en un control desactivado' ($(try { $c.ChkOmitirPunto.IsEnabled = $false; -not (Invoke-EnterControlUI -Elemento $c.ChkOmitirPunto) } finally { $c.ChkOmitirPunto.IsEnabled = $true }))

# Menú lateral completo
$c.Navegacion.SelectedIndex = 3; $w.Width = 860; $w.Height = 460; $w.UpdateLayout(); Invoke-BombearUI
$navTb = $c.NavRespaldo.Content
$rNav = Get-RectEn -El $navTb -Raiz $c.Navegacion
T 'El menú lateral no recorta "Respaldo y restauración" (el texto cabe o salta de línea dentro del menú)' (($navTb.TextWrapping -eq 'Wrap') -and ($rNav.Der -le $c.Navegacion.ActualWidth + 1) -and ($navTb.ActualWidth -ge $navTb.DesiredSize.Width - 1))
$w.Width = 1000; $w.Height = 600; Invoke-BombearUI

# Registro: las líneas largas saltan de línea
Clear-VistaLogUI
$c.Navegacion.SelectedIndex = 4; Invoke-BombearUI
Add-LineaLogUI -Linea ('[10:00:00] [INFO] ' + ('línea muy larga ' * 60))
$w.UpdateLayout(); Invoke-BombearUI
$svLog = $null
function Buscar-Scroll { param($Nodo)
    if ($Nodo -is [System.Windows.Controls.ScrollViewer]) { return $Nodo }
    $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Nodo)
    for ($i = 0; $i -lt $n; $i++) { $r = Buscar-Scroll ([System.Windows.Media.VisualTreeHelper]::GetChild($Nodo, $i)); if ($r) { return $r } }
    return $null }
$svLog = Buscar-Scroll $c.ListaLog
T 'Registro: una línea de 1000 caracteres salta de línea (sin barra de desplazamiento horizontal)' ($svLog -and ($svLog.ExtentWidth -le $svLog.ViewportWidth + 1) -and ($c.ListaLog.Items[0].TextWrapping -eq 'Wrap'))
Clear-VistaLogUI
$c.Navegacion.SelectedIndex = 0

# Ayuda para deshacer
T 'Optimizaciones: texto visible que explica que se deshace desde «Respaldo y restauración»' (($c.TxtAyudaDeshacer.Text -match 'Respaldo y restauración') -and ($c.TxtAyudaDeshacer.Text -match 'Deshacer última sesión'))
Update-EstadosFilasUI -Estados @([pscustomobject]@{ Id = $idA; Estado = 'Aplicado'; Detalle = ''; Deshacible = $true })
T 'Una fila "Aplicado" con respaldo muestra el botón «Deshacer» y su tooltip lo explica' (($ui.Filas[$idA].BtnDeshacer.Visibility -eq 'Visible') -and ($ui.Filas[$idA].Check.ToolTip -match 'Deshacer'))
$dirBkGuardado = $global:OptiLow.DirRespaldos
$global:OptiLow.DirRespaldos = $tmp   # hay journal: una fila aplicada sin respaldo "ya estaba así"
Update-EstadosFilasUI -Estados @([pscustomobject]@{ Id = $idA; Estado = 'Aplicado'; Detalle = ''; Deshacible = $false })
T 'Una fila "Aplicado" sin respaldo no muestra el botón y su tooltip explica que ya estaba así (no es un error)' (($ui.Filas[$idA].BtnDeshacer.Visibility -eq 'Collapsed') -and ($ui.Filas[$idA].Check.ToolTip -match 'Ya estaba así') -and ($ui.Filas[$idA].Check.ToolTip -match 'no es un error'))
T 'Esa fila dice «Ya estaba así en este equipo (OptiLow no lo cambió)» en su segunda línea' (($ui.Filas[$idA].TxtRec.Visibility -eq 'Visible') -and ($ui.Filas[$idA].TxtRec.Text -match 'Ya estaba así en este equipo \(OptiLow no lo cambió\)'))
Update-EstadosFilasUI -Estados @([pscustomobject]@{ Id = $idA; Estado = 'Aplicado'; Detalle = ''; Deshacible = $true })
T 'Una fila aplicada CON respaldo no dice «Ya estaba así»' ($ui.Filas[$idA].TxtRec.Text -notmatch 'Ya estaba así')
$global:OptiLow.DirRespaldos = $null   # sin journal no se puede afirmar que "ya estaba así"
Update-EstadosFilasUI -Estados @([pscustomobject]@{ Id = $idA; Estado = 'Aplicado'; Detalle = ''; Deshacible = $false })
T 'Sin journal NO se afirma «Ya estaba así»' ($ui.Filas[$idA].TxtRec.Text -notmatch 'Ya estaba así')
$global:OptiLow.DirRespaldos = $dirBkGuardado
T 'El botón «Deshacer» usa el estilo destacado (BotonAcento), distinto de los grises' ([object]::ReferenceEquals($ui.Filas[$idA].BtnDeshacer.Style, $c.VentanaPrincipal.TryFindResource('BotonAcento')))
Update-EstadosFilasUI -Estados @([pscustomobject]@{ Id = $idA; Estado = 'Pendiente'; Detalle = ''; Deshacible = $true })
T 'Una fila pendiente nunca muestra «Deshacer»' ($ui.Filas[$idA].BtnDeshacer.Visibility -eq 'Collapsed')
# Una fila aplicada y recomendada no debe sonar a "falta aplicarla"
$ui.Filas[$idA].Recomendado = $true; $ui.Filas[$idA].Motivo = 'motivo de prueba'
Update-EstadosFilasUI -Estados @([pscustomobject]@{ Id = $idA; Estado = 'Aplicado'; Detalle = ''; Deshacible = $true })
T 'Aplicada + recomendada dice «Aplicada (recomendada para este equipo…)»' ($ui.Filas[$idA].TxtRec.Text -match '^Aplicada \(recomendada para este equipo')
Update-EstadosFilasUI -Estados @([pscustomobject]@{ Id = $idA; Estado = 'Pendiente'; Detalle = ''; Deshacible = $false })
T 'Pendiente + recomendada sigue diciendo «Recomendada para este equipo»' ($ui.Filas[$idA].TxtRec.Text -match '^Recomendada para este equipo')
$ui.Filas[$idA].Recomendado = $false; $ui.Filas[$idA].Motivo = ''
Update-EstadosFilasUI -Estados @([pscustomobject]@{ Id = $idA; Estado = 'Aplicado'; Detalle = ''; Deshacible = $true })
Set-EstadosFijos

# Tooltips de los botones desactivados
T 'Los tooltips se muestran también en controles desactivados (ShowOnDisabled)' ([System.Windows.Controls.ToolTipService]::GetShowOnDisabled($c.BtnAplicar) -and [System.Windows.Controls.ToolTipService]::GetShowOnDisabled($c.BtnSeleccionarRec) -and [System.Windows.Controls.ToolTipService]::GetShowOnDisabled($c.ChkOmitirPunto) -and [System.Windows.Controls.ToolTipService]::GetShowOnDisabled($c.DemoBajo))
$recGuardadas = $ui.Recomendados
$ui.Recomendados = @{}
Update-EstadoBotonesUI
T '"Seleccionar recomendadas" sin diagnóstico: desactivado y el tooltip lo explica' ((-not $c.BtnSeleccionarRec.IsEnabled) -and ($c.BtnSeleccionarRec.ToolTip -match 'Aún no hay diagnóstico'))
$ui.Recomendados = $recGuardadas
Update-EstadoBotonesUI
T 'Con diagnóstico se activa y el tooltip desaparece' ($c.BtnSeleccionarRec.IsEnabled -and ($null -eq $c.BtnSeleccionarRec.ToolTip))
[void](Start-TrabajoUI -Nombre 'prueba' -Texto 'prueba de tooltips' -Parametros @{ Milisegundos = 600 })
$busy = @($c.BtnAplicar, $c.BtnQuitarSel, $c.BtnSeleccionarRec, $c.BtnActualizarDiag, $c.BtnDeshacer, $c.BtnActualizarSesiones, $c.ChkOmitirPunto, $c.DemoBajo)
T 'Con un trabajo en curso, cada control desactivado explica por qué (trabajo en curso)' (@($busy | Where-Object { (-not $_.IsEnabled) -and ("$($_.ToolTip)" -match 'trabajo en curso') }).Count -eq $busy.Count)
[void](Esperar-Libre 20000)
T 'Al terminar el trabajo se quitan esos motivos' (@($busy | Where-Object { "$($_.ToolTip)" -match 'trabajo en curso' }).Count -eq 0)
T 'Sin administrador, Aplicar y Deshacer explican el motivo en el tooltip' ($(try { $global:PruebaAdmin = $false; function global:Test-EsAdministrador { return [bool]$global:PruebaAdmin }; Update-EstadoBotonesUI; ((-not $c.BtnAplicar.IsEnabled) -and ($c.BtnAplicar.ToolTip -match 'administrador') -and ($c.BtnDeshacer.ToolTip -match 'administrador')) } finally { Restaurar-Entorno; Update-EstadoBotonesUI }))

Seccion '11d. Instancia única (mutex), señal de apertura y lanzadores'
$nombreMutex = 'Global\OptiLow_Prueba_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
T 'El primer proceso toma el mutex de instancia única' (Enter-InstanciaUnica -Nombre $nombreMutex)
$hijo1 = @(& (Join-Path $PSHOME 'powershell.exe') -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -ProbarInstancia $nombreMutex 2>&1 | ForEach-Object { "$_" })
T 'Un segundo proceso NO lo consigue (ya hay una instancia)' (($hijo1 -join ' ') -match 'PRIMERA=False')
$global:OptiLowMutexInstancia.ReleaseMutex(); $global:OptiLowMutexInstancia.Dispose()
$hijo2 = @(& (Join-Path $PSHOME 'powershell.exe') -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -ProbarInstancia $nombreMutex 2>&1 | ForEach-Object { "$_" })
T 'Al cerrarse la primera, un nuevo arranque sí puede abrir' (($hijo2 -join ' ') -match 'PRIMERA=True')
$textoOptiLow = Get-Content -LiteralPath (Join-Path $raiz 'OptiLow.ps1') -Raw
T 'OptiLow.ps1 comprueba la instancia única antes de pedir el UAC' ($textoOptiLow.IndexOf('Enter-InstanciaUnica') -ge 0 -and $textoOptiLow.IndexOf('Enter-InstanciaUnica') -lt $textoOptiLow.IndexOf('$esAdmin = Test-EsAdministrador'))
T 'Show-YaAbierto trae al frente (AppActivate) o avisa (Popup)' ((Get-Command Show-YaAbierto).Definition -match 'AppActivate' -and (Get-Command Show-YaAbierto).Definition -match 'Popup')
T 'La señal de apertura la escribe Write-SenalApertura y también los errores' (($textoOptiLow -match 'function global:Write-SenalApertura') -and ($textoOptiLow -match '(?s)function global:Show-ErrorSinWpf.*?Write-SenalApertura'))
$okCmd = $true
foreach ($cmd in @('Iniciar.cmd', 'Iniciar (modo seguro).cmd')) {
    $tc = Get-Content -LiteralPath (Join-Path $raiz $cmd) -Raw
    if (-not (($tc -match 'Abriendo OptiLow') -and ($tc -match 'OptiLow-abierto\.flag') -and ($tc -match 'start ""'))) { $okCmd = $false }
}
T 'Los lanzadores muestran "Abriendo OptiLow" y esperan la señal de apertura' $okCmd

Seccion '12. Diseño a cuatro tamaños (1366x728, 1093x582, 911x485, 860x460) y capturas'
$global:PruebaRespuestas.Clear()
$tamanos = @(@{ N = '1366x728'; W = 1366; H = 728 }, @{ N = '1093x582'; W = 1093; H = 582 }, @{ N = '911x485'; W = 911; H = 485 }, @{ N = '860x460'; W = 860; H = 460 })
$nombresTab = @('diagnostico', 'optimizaciones', 'inicio', 'respaldo', 'registro')
$w.WindowState = 'Normal'
foreach ($t in $tamanos) {
    $w.Left = 0; $w.Top = 0
    $w.Width = $t.W; $w.Height = $t.H
    Invoke-BombearUI; Invoke-BombearUI
    for ($i = 0; $i -lt 5; $i++) {
        $c.Navegacion.SelectedIndex = $i
        $w.UpdateLayout(); Invoke-BombearUI; Invoke-BombearUI
        $raizVis = $w.Content
        $rw = $raizVis.ActualWidth; $rh = $raizVis.ActualHeight
        $etq = "$($t.N) / $($nombresTab[$i])"
        $fuera = New-Object System.Collections.ArrayList
        foreach ($par in $c.GetEnumerator()) {
            $el = $par.Value
            if (($el -isnot [System.Windows.FrameworkElement]) -or ($el -eq $w) -or (-not $el.IsVisible) -or ($el.ActualWidth -le 0)) { continue }
            if (En-Scroll $el) { continue }
            if ($par.Key -eq 'PanelCarga') { continue }
            $r = Get-RectEn -El $el -Raiz $raizVis
            if (($r.Der -gt $rw + 1) -or ($r.Aba -gt $rh + 1) -or ($r.X -lt -1) -or ($r.Y -lt -1)) { [void]$fuera.Add("$($par.Key) ($([int]$r.X),$([int]$r.Y))-($([int]$r.Der),$([int]$r.Aba)) en ${rw}x${rh}") }
        }
        T "Diseño $etq`: nada se sale de la ventana" ($fuera.Count -eq 0)
        if ($fuera.Count -gt 0) { Info ('Fuera: ' + ($fuera -join '; ')) }
        $rc = Get-RectEn -El $c.TxtEstadoTrabajo -Raiz $raizVis
        $rn = Get-RectEn -El $c.Navegacion -Raiz $raizVis
        T "Diseño $etq`: cabecera, navegación y barra de estado visibles" ($c.TxtTitulo.IsVisible -and $c.Navegacion.IsVisible -and ($c.Navegacion.ActualHeight -gt 100) -and ($rc.Aba -le $rh + 1) -and ($rn.Aba -le $rh))
        $scrolls = @($c.GetEnumerator() | Where-Object { $_.Value -is [System.Windows.Controls.ScrollViewer] -and $_.Value.IsVisible })
        foreach ($sv in $scrolls) {
            T "Diseño $etq`: $($sv.Key) sin desbordamiento horizontal (extensión <= ventana)" ($sv.Value.ExtentWidth -le $sv.Value.ViewportWidth + 1)
        }
        if ($i -eq 1) {
            T "Diseño $etq`: la lista de optimizaciones conserva altura útil (>= 70)" ($c.ScrollOptimizaciones.ActualHeight -ge 70)
            $rb = Get-RectEn -El $c.BtnAplicar -Raiz $raizVis
            T "Diseño $etq`: el botón Aplicar está visible dentro de la ventana" ($c.BtnAplicar.IsVisible -and ($rb.Der -le $rw + 1) -and ($rb.Aba -le $rh))
        }
        if (($i -eq 0) -and ($t.H -le 485)) {
            $sd = $c.ScrollDiagnostico
            T "Diseño $etq`: el diagnóstico se desplaza verticalmente en vez de cortarse" (($sd.ScrollableHeight -gt 0) -or ($sd.ExtentHeight -le $sd.ViewportHeight + 1))
            Info ("Diagnóstico en $etq`: contenido $([int]$sd.ExtentHeight) px, visible $([int]$sd.ViewportHeight) px")
        }
        Save-Captura -Nombre ("{0}_{1}" -f $t.N, $nombresTab[$i])
    }
}
$c.Navegacion.SelectedIndex = 0
$w.Width = 1000; $w.Height = 600
Info ("Capturas en: " + (Join-Path ([System.IO.Path]::GetTempPath()) 'OptiLow-capturas'))

Seccion '13. Preferencia de renderizado por software'
$global:OptiLowUI.C = $c
T 'Sin archivo, la preferencia por defecto es "no software"' (-not (Get-PreferenciasUI).RenderizadoSoftware)
T 'Save-PreferenciasUI guarda' (Save-PreferenciasUI -Preferencias @{ RenderizadoSoftware = $true })
T 'Se lee de vuelta: software activado' ((Get-PreferenciasUI).RenderizadoSoftware -eq $true)
$bytes = [System.IO.File]::ReadAllBytes((Get-RutaPreferenciasUI))
T 'El archivo ui.json es UTF-8 SIN BOM y JSON válido' (-not (($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) -and ([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json).RenderizadoSoftware)
T 'La ruta de la preferencia está en %ProgramData%\OptiLow\ui.json' ((Get-RutaPreferenciasUI) -eq (Join-Path (Join-Path $env:ProgramData 'OptiLow') 'ui.json'))
[System.IO.File]::WriteAllText((Get-RutaPreferenciasUI), '{ esto no es json', (New-Object System.Text.UTF8Encoding($false)))
T 'Un ui.json dañado se ignora (valores por defecto)' (-not (Get-PreferenciasUI).RenderizadoSoftware)
Remove-Item -LiteralPath (Get-RutaPreferenciasUI) -Force
$global:PruebaRespuestas.Clear(); Reset-Dialogos
$c.ChkSoftware.IsChecked = $true
function global:Show-DialogoOptiLow { param([string]$Titulo, [string]$Mensaje, [string[]]$Detalles = @(), [string]$Advertencia = '', [string[]]$Botones = @('Aceptar'), [int]$Predeterminado = 0, [int]$Cancelar = -1, [string]$Tipo = 'Info') [void]$global:PruebaDialogos.Add([pscustomobject]@{ Titulo = $Titulo; Mensaje = $Mensaje }); return 0 }
Invoke-CasillaSoftwareUI
T 'La casilla guarda la preferencia y pide reabrir' ((Get-PreferenciasUI).RenderizadoSoftware -and ($global:PruebaDialogos[0].Mensaje -match 'vuelve a abrir'))
Remove-Item -LiteralPath (Get-RutaPreferenciasUI) -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------------------------
Seccion '14. Arranque en procesos aparte: modo normal, software, reintento automático y error sin WPF'
$ps = Join-Path $PSHOME 'powershell.exe'
function Invoke-Hijo { param([string[]]$Extra)
    $args2 = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-SoloArranque') + $Extra
    $salida = & $ps @args2 2>&1 | ForEach-Object { "$_" }
    return @($salida) }
$normal = Invoke-Hijo -Extra @()
$soft = Invoke-Hijo -Extra @('-Software')
$reint = Invoke-Hijo -Extra @('-SimularFalloVentana')
$errArr = Invoke-Hijo -Extra @('-SimularErrorArranque')
Info 'Tiempos de apertura (ms desde el inicio del proceso):'
foreach ($par in @(@('normal', $normal), @('software', $soft))) {
    $ult = @($par[1] | Where-Object { $_ -like 'TIEMPO: Lista*' }) | Select-Object -First 1
    $wpf = @($par[1] | Where-Object { $_ -like 'TIEMPO: WPF*' }) | Select-Object -First 1
    $dib = @($par[1] | Where-Object { $_ -like 'TIEMPO: Primer dibujo*' }) | Select-Object -First 1
    Info ("  {0,-9} {1} | {2} | {3}" -f $par[0], $wpf, $dib, $ult)
}
T 'Proceso normal: arranca y devuelve 0 en modo Automático' (($normal -join "`n") -match 'RESULTADO: cerrada=False codigo=0 modo=\[Automático\]')
T 'Proceso -Software: modo "Software (forzado por parámetro)" y ProcessRenderMode = SoftwareOnly' ((($soft -join "`n") -match 'modo=\[Software \(forzado por parámetro\)\]') -and (($soft -join "`n") -match 'modoProceso=SoftwareOnly'))
T 'Reintento automático: tras un fallo de la ventana abre en software y avisa' ((($reint -join "`n") -match 'codigo=0 modo=\[Software \(reintento automático\)\] intentos=2') -and (($reint -join "`n") -match 'modoProceso=SoftwareOnly'))
T 'Error de arranque: devuelve 1 y llama al aviso sin WPF con el motivo' ((($errArr -join "`n") -match 'codigo=1') -and (($errArr -join "`n") -match 'ERROR-MOSTRADO: .*No se pudo iniciar la interfaz.*Fallo simulado'))
foreach ($etapa in @('Ventana creada', 'Core/ cargado', 'Modules/ y Tweaks/ cargados', 'Contenido preparado')) {
    $hc = Invoke-Hijo -Extra @('-CerrarEn', $etapa)
    $tc = $hc -join ' '
    T "Cerrar la ventana a mitad de la carga (tras '$etapa'): salida limpia (código 0), sin ningún aviso de error" (($tc -match 'cerrada=True codigo=0') -and ($tc -match 'errores=0') -and ($tc -notmatch 'ERROR-MOSTRADO') -and ($tc -notmatch 'PushFrame'))
}
foreach ($par in @(@('normal', $normal), @('software', $soft))) {
    T "Proceso $($par[0]): se midieron todas las etapas" (@($par[1] | Where-Object { $_ -like 'TIEMPO:*' }).Count -ge 6)
}

# ---------------------------------------------------------------------------------------------
Seccion '15. Cierre y limpieza'
Restaurar-Entorno
$cerrada = $true
try { $w.Close() } catch { $cerrada = $false }
T 'La ventana se cierra sin error' $cerrada
try { Stop-TrabajosUI } catch { }
$env:ProgramData = $programDataReal
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
T 'Se borró la carpeta temporal de la prueba' (-not (Test-Path -LiteralPath $tmp))
T 'ProgramData se restauró' ($env:ProgramData -eq $programDataReal)

Write-Host ''
Write-Host ("RESULTADO: {0} bien, {1} fallos" -f $script:bien, $script:mal) -ForegroundColor $(if ($script:mal -eq 0) { 'Green' } else { 'Red' })
if ($script:mal -gt 0) { exit 1 }
exit 0
