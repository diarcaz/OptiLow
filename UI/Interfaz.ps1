# UI/Interfaz.ps1
# Ventana principal: crea la ventana desde UI/MainWindow.xaml, localiza los controles por su x:Name, conecta los
# eventos y construye las vistas (lista de optimizaciones, diagnóstico, sesiones del journal).
#
# REGLAS (CLAUDE.md y docs/PLAN-FASE5.md):
#   - Este archivo solo LLAMA a funciones de Core/ y Modules/ (Get-Tweak, Get-JournalSesiones...); no contiene
#     lógica de optimización. Todo lo pesado se hace en el runspace de trabajo (UI/Trabajos.ps1).
#   - El estado compartido vive en UNA sola variable global: $global:OptiLowUI. Los controles con nombre están
#     en $global:OptiLowUI.C (se obtienen de los x:Name del XAML).
#   - Los manejadores de eventos llaman a funciones globales (este archivo se carga con Import-OptiLowArchivo).
#   - Sin efectos pesados (sombras, desenfoques, animaciones): ver el XAML.

# ---------------------------------------------------------------------------------------------------------------
# Estado y ayudantes
# ---------------------------------------------------------------------------------------------------------------

function Initialize-EstadoUI {
    <#
    .SYNOPSIS
        Crea $global:OptiLowUI (el estado compartido de la interfaz).
    #>
    param(
        [Parameter(Mandatory)][string]$Raiz,
        [hashtable]$Opciones = @{}
    )

    $global:OptiLowUI = @{
        Raiz              = $Raiz
        Opciones          = $Opciones
        C                 = @{}
        Cola              = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        LineasLog         = New-Object System.Collections.ArrayList
        Filas             = [ordered]@{}
        Estados           = @{}
        Recomendados      = @{}
        Hardware          = $null
        Simulado          = $false
        OtroUsuario       = $null
        Runspace          = $null
        Trabajo           = $null
        Timer             = $null
        TrabajosIniciados = 0
        MedirTicks        = $false
        Ticks             = New-Object System.Collections.ArrayList
        Tiempos           = [ordered]@{}
        ModoRender        = 'Automático'
        DialogoResultado  = -1
        FrameBomba        = $null
        SesionesCache     = @()
        PincelCache       = @{}
    }
}

function Get-PincelUI {
    # Auxiliar interna: pincel del tema (recurso del XAML) por clave.
    param(
        [Parameter(Mandatory)][string]$Clave
    )
    $ui = $global:OptiLowUI
    if (-not $ui.PincelCache.ContainsKey($Clave)) {
        $ui.PincelCache[$Clave] = $ui.C.VentanaPrincipal.FindResource($Clave)
    }
    return $ui.PincelCache[$Clave]
}

function New-EspesorUI {
    # Auxiliar interna: Thickness desde "t" o "h,v" o "i,s,d,b" (WPF no tiene Thickness.Parse).
    param(
        [Parameter(Mandatory)][string]$Texto
    )
    $v = @($Texto.Split(',') | ForEach-Object { [double]$_.Trim() })
    switch ($v.Count) {
        1 { return New-Object System.Windows.Thickness($v[0]) }
        2 { return New-Object System.Windows.Thickness($v[0], $v[1], $v[0], $v[1]) }
        default { return New-Object System.Windows.Thickness($v[0], $v[1], $v[2], $v[3]) }
    }
}

function New-TextoUI {
    <#
    .SYNOPSIS
        Crea un TextBlock con los colores del tema.
    #>
    param(
        [AllowEmptyString()][string]$Texto,
        [string]$Color = 'BrushTexto',
        [switch]$Negrita,
        [double]$Tam = 13,
        [string]$Margen = '0,0,0,0',
        [switch]$SinAjuste
    )

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Texto
    $tb.Foreground = Get-PincelUI -Clave $Color
    $tb.FontSize = $Tam
    if ($Negrita) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $tb.Margin = (New-EspesorUI $Margen)
    if (-not $SinAjuste) { $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap }
    return $tb
}

function Invoke-ManejadorUI {
    <#
    .SYNOPSIS
        Ejecuta el cuerpo de un manejador de eventos sin dejar que un error escape (se registra en el log).
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Bloque
    )
    try { & $Bloque }
    catch {
        try { Write-Log -Nivel ERROR -Mensaje "Error en la interfaz: $($_.Exception.Message)" } catch { }
    }
}

function Invoke-BombearUI {
    <#
    .SYNOPSIS
        Deja que WPF procese lo pendiente (pintar, eventos) y vuelve. Sirve durante la carga y en las pruebas.
    #>
    $ui = $global:OptiLowUI
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $ui.FrameBomba = $frame
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [Action] { $global:OptiLowUI.FrameBomba.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

# ---------------------------------------------------------------------------------------------------------------
# Preferencias de la interfaz (no son un cambio del sistema: no pasan por el journal)
# ---------------------------------------------------------------------------------------------------------------

function Get-RutaPreferenciasUI {
    return [System.IO.Path]::Combine($env:ProgramData, 'OptiLow', 'ui.json')
}

function Get-PreferenciasUI {
    <#
    .SYNOPSIS
        Lee las preferencias de la interfaz (%ProgramData%\OptiLow\ui.json). Si no existen o están dañadas,
        devuelve los valores por defecto.
    #>
    $prefs = @{ RenderizadoSoftware = $false }
    try {
        $ruta = Get-RutaPreferenciasUI
        if (Test-Path -LiteralPath $ruta) {
            $json = [System.IO.File]::ReadAllText($ruta, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($null -ne $json.RenderizadoSoftware) { $prefs.RenderizadoSoftware = [bool]$json.RenderizadoSoftware }
        }
    }
    catch { }
    return $prefs
}

function Save-PreferenciasUI {
    <#
    .SYNOPSIS
        Guarda las preferencias (UTF-8 sin BOM, ConvertTo-Json -Depth 100). Devuelve $true si se guardó.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Preferencias
    )

    try {
        $ruta = Get-RutaPreferenciasUI
        $dir = [System.IO.Path]::GetDirectoryName($ruta)
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop) }
        $json = ConvertTo-Json -InputObject $Preferencias -Depth 100
        [System.IO.File]::WriteAllText($ruta, $json, (New-Object System.Text.UTF8Encoding($false)))
        return $true
    }
    catch {
        Write-Log -Nivel WARN -Mensaje "No se pudo guardar la preferencia de la interfaz: $($_.Exception.Message)"
        return $false
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Diálogos (ventanas modales propias con los colores del tema; Enter y Esc con IsDefault / IsCancel)
# ---------------------------------------------------------------------------------------------------------------

function Show-DialogoOptiLow {
    <#
    .SYNOPSIS
        Muestra un diálogo modal y devuelve el índice del botón elegido.
    .PARAMETER Detalles
        Líneas de texto con scroll (p. ej. la lista de cambios).
    .PARAMETER Advertencia
        Recuadro de advertencia aparte (riesgo Alto, no reversible, escritorio de otro usuario).
    .PARAMETER Cancelar
        Índice del botón que responde a Esc y a cerrar la ventana (-1 si no hay).
    .NOTES
        Las pruebas sustituyen esta función por una de prueba que devuelve respuestas fijas.
    #>
    param(
        [Parameter(Mandatory)][string]$Titulo,
        [Parameter(Mandatory)][string]$Mensaje,
        [string[]]$Detalles = @(),
        [string]$Advertencia = '',
        [string[]]$Botones = @('Aceptar'),
        [int]$Predeterminado = 0,
        [int]$Cancelar = -1,
        [ValidateSet('Info', 'Aviso', 'Peligro')][string]$Tipo = 'Info'
    )

    $ui = $global:OptiLowUI
    $principal = $ui.C.VentanaPrincipal
    $colorTipo = switch ($Tipo) { 'Aviso' { 'BrushAviso' } 'Peligro' { 'BrushError' } default { 'BrushAcento' } }

    $dlg = New-Object System.Windows.Window
    $dlg.Title = $Titulo
    $dlg.Width = [math]::Min(600, [math]::Max(420, $principal.ActualWidth - 40))
    $dlg.SizeToContent = [System.Windows.SizeToContent]::Height
    $dlg.MaxHeight = [math]::Max(300, [System.Windows.SystemParameters]::WorkArea.Height * 0.9)
    $dlg.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $dlg.ShowInTaskbar = $false
    $dlg.UseLayoutRounding = $true
    $dlg.FontFamily = $principal.FontFamily
    $dlg.FontSize = 13
    $dlg.Background = Get-PincelUI -Clave 'BrushFondo'
    $dlg.Foreground = Get-PincelUI -Clave 'BrushTexto'
    if ($principal.IsVisible) {
        $dlg.Owner = $principal
        $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    }
    else {
        $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    }
    foreach ($k in @($principal.Resources.Keys)) { $dlg.Resources[$k] = $principal.Resources[$k] }

    $raiz = New-Object System.Windows.Controls.Grid
    $raiz.Margin = (New-EspesorUI '16')
    [void]$raiz.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))
    [void]$raiz.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::Auto }))

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $scroll.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
    $pila = New-Object System.Windows.Controls.StackPanel
    $pila.Margin = (New-EspesorUI '0,0,8,0')
    $tbTitulo = New-TextoUI -Texto $Titulo -Color $colorTipo -Negrita -Tam 16 -Margen '0,0,0,8'
    [void]$pila.Children.Add($tbTitulo)
    [void]$pila.Children.Add((New-TextoUI -Texto $Mensaje -Margen '0,0,0,8'))
    foreach ($linea in $Detalles) {
        [void]$pila.Children.Add((New-TextoUI -Texto $linea -Color 'BrushTextoSuave' -Margen '0,0,0,4'))
    }
    if ($Advertencia) {
        $marco = New-Object System.Windows.Controls.Border
        $marco.BorderBrush = Get-PincelUI -Clave 'BrushError'
        $marco.BorderThickness = (New-EspesorUI '2')
        $marco.Padding = (New-EspesorUI '8,6')
        $marco.Margin = (New-EspesorUI '0,8,0,4')
        $marco.Child = (New-TextoUI -Texto $Advertencia -Color 'BrushError')
        [void]$pila.Children.Add($marco)
    }
    $scroll.Content = $pila
    [System.Windows.Controls.Grid]::SetRow($scroll, 0)
    [void]$raiz.Children.Add($scroll)

    $fila = New-Object System.Windows.Controls.WrapPanel
    $fila.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $fila.Margin = (New-EspesorUI '0,12,0,0')
    for ($i = 0; $i -lt $Botones.Count; $i++) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $Botones[$i]
        $b.Tag = $i
        $b.MinWidth = 90
        $b.Margin = (New-EspesorUI '8,0,0,0')
        $b.TabIndex = $i
        if ($i -eq $Predeterminado) { $b.IsDefault = $true }
        if ($i -eq $Cancelar) { $b.IsCancel = $true }
        $b.Add_Click({ param($s, $e) $global:OptiLowUI.DialogoResultado = [int]$s.Tag; [System.Windows.Window]::GetWindow($s).Close() })
        [void]$fila.Children.Add($b)
    }
    [System.Windows.Controls.Grid]::SetRow($fila, 1)
    [void]$raiz.Children.Add($fila)
    $dlg.Content = $raiz

    $resultadoPorDefecto = $Predeterminado
    if ($Cancelar -ge 0) { $resultadoPorDefecto = $Cancelar }
    $ui.DialogoResultado = $resultadoPorDefecto
    # Foco inicial en el botón predeterminado
    $dlg.Add_ContentRendered({
            param($s, $e)
            foreach ($bb in $s.Content.Children[1].Children) { if ($bb.IsDefault) { [void]$bb.Focus() } }
        })
    [void]$dlg.ShowDialog()
    return [int]$ui.DialogoResultado
}

# ---------------------------------------------------------------------------------------------------------------
# Creación de la ventana
# ---------------------------------------------------------------------------------------------------------------

function New-OptiLowVentana {
    <#
    .SYNOPSIS
        Crea la ventana desde UI/MainWindow.xaml (sin mostrarla) y localiza los controles por su x:Name.
    .DESCRIPTION
        Requiere $global:OptiLowUI (ver Initialize-EstadoUI) y los ensamblados de WPF cargados. No necesita Core/.
    #>
    $ui = $global:OptiLowUI
    $rutaXaml = Join-Path (Join-Path $ui.Raiz 'UI') 'MainWindow.xaml'
    if (-not (Test-Path -LiteralPath $rutaXaml)) { throw "Falta el archivo de la interfaz: $rutaXaml" }
    $xaml = [System.IO.File]::ReadAllText($rutaXaml, [System.Text.Encoding]::UTF8)

    $lector = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader($xaml)))
    try { $ventana = [System.Windows.Markup.XamlReader]::Load($lector) }
    finally { $lector.Close() }

    # Controles con nombre: se obtienen de los x:Name del propio XAML
    # (los nombres dentro de <Window.Resources>, p. ej. los de las plantillas de estilo, tienen su propio ámbito)
    $c = @{}
    $xamlSinRecursos = [regex]::Replace($xaml, '(?s)<Window\.Resources>.*?</Window\.Resources>', '')
    foreach ($m in [regex]::Matches($xamlSinRecursos, 'x:Name="(\w+)"')) {
        $nombre = $m.Groups[1].Value
        $ctl = $ventana.FindName($nombre)
        if ($null -eq $ctl) { throw "El XAML declara el control '$nombre' pero no se pudo localizar." }
        $c[$nombre] = $ctl
    }
    $ui.C = $c
    $ui.PincelCache = @{}

    # Tamaño inicial: 1000x600 recortado al área de trabajo (la barra de tareas no cuenta)
    $area = [System.Windows.SystemParameters]::WorkArea
    $ventana.Width = [math]::Min(1000, $area.Width)
    $ventana.Height = [math]::Min(600, $area.Height)
    return $ventana
}

# ---------------------------------------------------------------------------------------------------------------
# Botones, banners y cabecera
# ---------------------------------------------------------------------------------------------------------------

function Get-MotivoNoAplicarUI {
    <#
    .SYNOPSIS
        Por qué no se puede aplicar ni deshacer nada ahora (o $null si se puede).
    #>
    $ui = $global:OptiLowUI
    if ($ui.Simulado) { return 'Hay datos simulados (-Demo): solo sirven para ver. No se puede aplicar ni deshacer nada.' }
    if (-not (Test-EsAdministrador)) { return 'OptiLow no tiene permisos de administrador (modo limitado): no se puede aplicar ni deshacer nada.' }
    if (-not $global:OptiLow.DirRespaldos) { return 'No hay una carpeta de respaldos segura (journal): sin ella no se podrían deshacer los cambios, así que no se aplica nada.' }
    return $null
}

function Update-EstadoBotonesUI {
    <#
    .SYNOPSIS
        Activa o desactiva los botones de acción: todos se desactivan mientras corre un trabajo (solo uno a la vez).
    #>
    $ui = $global:OptiLowUI
    $c = $ui.C
    if ((-not $c) -or (-not $c.BtnAplicar)) { return }
    $ocupado = [bool]$ui.Trabajo
    $motivo = Get-MotivoNoAplicarUI
    $hayRec = ($ui.Recomendados.Count -gt 0)

    $c.BtnActualizarDiag.IsEnabled = -not $ocupado
    foreach ($n in @('DemoReal', 'DemoBajo', 'DemoMedio', 'DemoAlto')) { $c[$n].IsEnabled = -not $ocupado }
    $c.BtnSeleccionarRec.IsEnabled = (-not $ocupado) -and $hayRec
    $c.BtnQuitarSel.IsEnabled = -not $ocupado
    $c.ChkOmitirPunto.IsEnabled = -not $ocupado
    $c.BtnAplicar.IsEnabled = (-not $ocupado) -and ($null -eq $motivo)
    $c.BtnActualizarSesiones.IsEnabled = (-not $ocupado) -and [bool]$global:OptiLow.DirRespaldos
    $c.BtnDeshacer.IsEnabled = (-not $ocupado) -and ($null -eq $motivo)
    if ($motivo) {
        $c.BtnAplicar.ToolTip = $motivo
        $c.BtnDeshacer.ToolTip = $motivo
    }
    else {
        $c.BtnAplicar.ToolTip = $null
        $c.BtnDeshacer.ToolTip = $null
    }
    Update-SeleccionUI
}

function Update-BannersUI {
    <#
    .SYNOPSIS
        Banners visibles: escritorio de otro usuario, sin journal / sin administrador, y datos simulados.
    #>
    $ui = $global:OptiLowUI
    $c = $ui.C

    $otro = $ui.OtroUsuario
    if ($otro -and $otro.Distinto) {
        $c.TxtBannerOtroUsuario.Text = "El escritorio pertenece a '$($otro.UsuarioEscritorio)' pero OptiLow corre como '$($otro.UsuarioProceso)'. Los cambios de HKCU y %APPDATA% se aplicarían a la cuenta equivocada."
        $c.BannerOtroUsuario.Visibility = 'Visible'
    }
    else { $c.BannerOtroUsuario.Visibility = 'Collapsed' }

    $esAdmin = Test-EsAdministrador
    if (-not $esAdmin) {
        $c.TxtBannerJournal.Text = 'OptiLow se abrió SIN permisos de administrador (modo limitado): puedes mirar el diagnóstico y las optimizaciones, pero no se puede aplicar ni deshacer nada.'
        $c.BannerJournal.Visibility = 'Visible'
    }
    elseif (-not $global:OptiLow.DirRespaldos) {
        $c.TxtBannerJournal.Text = 'No hay una carpeta de respaldos segura (journal): sin ella no se podrían deshacer los cambios, así que no se aplica nada. Revisa el registro.'
        $c.BannerJournal.Visibility = 'Visible'
    }
    else { $c.BannerJournal.Visibility = 'Collapsed' }

    if ($ui.Simulado) { $c.BannerSimulado.Visibility = 'Visible' } else { $c.BannerSimulado.Visibility = 'Collapsed' }

    if ($esAdmin) { $c.TxtAdmin.Text = 'Administrador: sí' } else { $c.TxtAdmin.Text = 'Administrador: NO (modo limitado)' }
    if ($global:OptiLow.DirRespaldos) { $c.TxtJournal.Text = 'Journal: listo' } else { $c.TxtJournal.Text = 'Journal: NO disponible' }
}

function Set-VistaUI {
    <#
    .SYNOPSIS
        Muestra la vista de la pestaña indicada (0 a 4) y oculta las demás.
    #>
    param(
        [Parameter(Mandatory)][int]$Indice
    )

    $ui = $global:OptiLowUI
    $c = $ui.C
    $vistas = @('VistaDiagnostico', 'VistaOptimizaciones', 'VistaInicio', 'VistaRespaldo', 'VistaRegistro')
    for ($i = 0; $i -lt $vistas.Count; $i++) {
        if ($i -eq $Indice) { $c[$vistas[$i]].Visibility = 'Visible' } else { $c[$vistas[$i]].Visibility = 'Collapsed' }
    }
    if (($Indice -eq 3) -and (-not $ui.SesionesCargadas) -and (-not $ui.Trabajo) -and $global:OptiLow.DirRespaldos) {
        Update-SesionesUI
    }
    if (($Indice -eq 4) -and ($c.ListaLog.Items.Count -gt 0)) {
        $c.ListaLog.ScrollIntoView($c.ListaLog.Items[$c.ListaLog.Items.Count - 1])
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Optimizaciones
# ---------------------------------------------------------------------------------------------------------------

function Get-TextoEstadoUI {
    # Auxiliar interna: texto y color de un estado de tweak.
    param(
        [string]$Estado
    )
    switch ($Estado) {
        'Aplicado'    { return @('Aplicado', 'BrushOk') }
        'Pendiente'   { return @('Pendiente', 'BrushTexto') }
        'NoAplica'    { return @('No aplica', 'BrushTextoSuave') }
        'Error'       { return @('Error', 'BrushError') }
        'Desconocido' { return @('Sin comprobar', 'BrushTextoSuave') }
        default       { return @('Comprobando…', 'BrushTextoSuave') }
    }
}

function Test-FilaSeleccionableUI {
    # Auxiliar interna: las filas ya aplicadas o que no aplican no se seleccionan (ni las que aún se comprueban).
    param(
        [Parameter(Mandatory)]$Fila
    )
    return (@('Pendiente', 'Desconocido', 'Error') -contains $Fila.Estado)
}

function New-FilaOptimizacionUI {
    <#
    .SYNOPSIS
        Crea la fila de una optimización (casilla, nombre, riesgo, reinicio, estado y marca de recomendada).
    #>
    param(
        [Parameter(Mandatory)]$Def
    )

    $marco = New-Object System.Windows.Controls.Border
    $marco.Background = Get-PincelUI -Clave 'BrushPanel'
    $marco.BorderBrush = Get-PincelUI -Clave 'BrushBorde'
    $marco.BorderThickness = (New-EspesorUI '1')
    $marco.Padding = (New-EspesorUI '10,6')
    $marco.Margin = (New-EspesorUI '0,0,0,6')

    $pila = New-Object System.Windows.Controls.StackPanel
    $linea = New-Object System.Windows.Controls.DockPanel
    $linea.LastChildFill = $true

    # Etiquetas a la derecha (se agregan primero para que ocupen su sitio; la casilla toma el resto)
    $estado = New-TextoUI -Texto 'Comprobando…' -Color 'BrushTextoSuave' -Margen '12,0,0,0' -SinAjuste
    $estado.MinWidth = 84
    $estado.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.DockPanel]::SetDock($estado, [System.Windows.Controls.Dock]::Right)
    [void]$linea.Children.Add($estado)

    $colorRiesgo = switch ($Def.Riesgo) { 'Alto' { 'BrushError' } 'Medio' { 'BrushAviso' } default { 'BrushOk' } }
    $riesgo = New-TextoUI -Texto ('Riesgo ' + $Def.Riesgo.ToLowerInvariant()) -Color $colorRiesgo -Margen '12,0,0,0' -SinAjuste
    $riesgo.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.DockPanel]::SetDock($riesgo, [System.Windows.Controls.Dock]::Right)
    [void]$linea.Children.Add($riesgo)

    if ($Def.Requiere -and ($Def.Requiere -ne 'Nada')) {
        $txtReq = if ($Def.Requiere -eq 'Reiniciar') { 'Reinicio' } else { 'Cerrar sesión' }
        $req = New-TextoUI -Texto $txtReq -Color 'BrushInfo' -Margen '12,0,0,0' -SinAjuste
        $req.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [System.Windows.Controls.DockPanel]::SetDock($req, [System.Windows.Controls.Dock]::Right)
        [void]$linea.Children.Add($req)
    }

    $check = New-Object System.Windows.Controls.CheckBox
    $nombre = New-Object System.Windows.Controls.TextBlock
    $nombre.Text = $Def.Nombre
    $nombre.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $nombre.Foreground = Get-PincelUI -Clave 'BrushTexto'
    $check.Content = $nombre
    $check.Tag = $Def.Id
    $check.ToolTip = $Def.Nombre
    $check.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [void]$linea.Children.Add($check)
    [void]$pila.Children.Add($linea)

    $rec = New-TextoUI -Texto '' -Color 'BrushAcento' -Tam 13 -Margen '22,2,0,0'
    $rec.Visibility = 'Collapsed'
    [void]$pila.Children.Add($rec)
    $marco.Child = $pila
    $marco.Tag = $Def.Id

    $fila = @{ Id = $Def.Id; Def = $Def; Marco = $marco; Check = $check; TxtEstado = $estado; TxtRec = $rec; Estado = 'Comprobando'; Recomendado = $false; Motivo = '' }

    $check.Add_Click({ param($s, $e) Invoke-ManejadorUI { Invoke-ClicCasillaUI -Id $s.Tag } })
    $check.Add_GotKeyboardFocus({ param($s, $e) Invoke-ManejadorUI { Show-DetalleOptimizacionUI -Id $s.Tag } })
    $marco.Add_MouseLeftButtonUp({ param($s, $e) Invoke-ManejadorUI { Show-DetalleOptimizacionUI -Id $s.Tag } })
    return $fila
}

function Initialize-ListaOptimizacionesUI {
    <#
    .SYNOPSIS
        Genera la lista de optimizaciones a partir de los tweaks registrados, agrupada por categoría.
    #>
    $ui = $global:OptiLowUI
    $c = $ui.C
    $c.PanelOptimizaciones.Children.Clear()
    $ui.Filas.Clear()

    $defs = @(Get-Tweak)
    if ($defs.Count -eq 0) {
        [void]$c.PanelOptimizaciones.Children.Add((New-TextoUI -Texto 'No hay ninguna optimización registrada (carpeta Tweaks/). Revisa el registro.' -Color 'BrushAviso'))
        return
    }

    # Orden estable: categorías en orden de aparición, y dentro de cada una el orden de registro
    $categorias = @($defs | ForEach-Object { $_.Categoria } | Select-Object -Unique)
    foreach ($cat in $categorias) {
        [void]$c.PanelOptimizaciones.Children.Add((New-TextoUI -Texto $cat -Color 'BrushAcento' -Negrita -Tam 14 -Margen '0,6,0,6'))
        foreach ($def in @($defs | Where-Object { $_.Categoria -eq $cat })) {
            $fila = New-FilaOptimizacionUI -Def $def
            $ui.Filas[$def.Id] = $fila
            [void]$c.PanelOptimizaciones.Children.Add($fila.Marco)
        }
    }
    # Flechas arriba/abajo entre filas
    $c.PanelOptimizaciones.Add_PreviewKeyDown({
            param($s, $e)
            Invoke-ManejadorUI {
                if (($e.Key -eq 'Down') -or ($e.Key -eq 'Up')) {
                    $dir = if ($e.Key -eq 'Down') { [System.Windows.Input.FocusNavigationDirection]::Down } else { [System.Windows.Input.FocusNavigationDirection]::Up }
                    $actual = [System.Windows.Input.Keyboard]::FocusedElement
                    if ($actual -is [System.Windows.Controls.CheckBox]) {
                        [void]$actual.MoveFocus((New-Object System.Windows.Input.TraversalRequest($dir)))
                        $e.Handled = $true
                    }
                }
            }
        })
}

function Update-FilaUI {
    # Auxiliar interna: repinta el estado y la marca de recomendada de una fila.
    param(
        [Parameter(Mandatory)]$Fila
    )

    $t = Get-TextoEstadoUI -Estado $Fila.Estado
    $Fila.TxtEstado.Text = $t[0]
    $Fila.TxtEstado.Foreground = Get-PincelUI -Clave $t[1]

    $seleccionable = Test-FilaSeleccionableUI -Fila $Fila
    if ($seleccionable) { $Fila.Marco.Opacity = 1.0 } else { $Fila.Marco.Opacity = 0.6 }
    if ((-not $seleccionable) -and $Fila.Check.IsChecked) { $Fila.Check.IsChecked = $false }
    if ($Fila.Estado -eq 'Aplicado') { $Fila.Check.ToolTip = 'Ya está aplicada.' }
    elseif ($Fila.Estado -eq 'NoAplica') { $Fila.Check.ToolTip = 'No aplica en este equipo.' }
    elseif ($Fila.Estado -eq 'Comprobando') { $Fila.Check.ToolTip = 'Comprobando el estado…' }
    else { $Fila.Check.ToolTip = $Fila.Def.Nombre }

    if ($Fila.Recomendado) {
        $txt = 'Recomendada para este equipo'
        if ($Fila.Motivo) { $txt += ': ' + $Fila.Motivo }
        $Fila.TxtRec.Text = $txt
        $Fila.TxtRec.Visibility = 'Visible'
    }
    elseif ($Fila.Motivo) {
        $Fila.TxtRec.Text = 'No recomendada: ' + $Fila.Motivo
        $Fila.TxtRec.Foreground = Get-PincelUI -Clave 'BrushTextoSuave'
        $Fila.TxtRec.Visibility = 'Visible'
    }
    else {
        $Fila.TxtRec.Visibility = 'Collapsed'
    }
    if ($Fila.Recomendado) { $Fila.TxtRec.Foreground = Get-PincelUI -Clave 'BrushAcento' }
}

function Update-EstadosFilasUI {
    <#
    .SYNOPSIS
        Aplica a las filas los estados devueltos por el trabajo "estados" (Id, Estado, Detalle).
    #>
    param(
        [object[]]$Estados
    )

    $ui = $global:OptiLowUI
    foreach ($e in @($Estados)) {
        if ((-not $e) -or (-not $e.Id) -or (-not $ui.Filas.Contains($e.Id))) { continue }
        $ui.Estados[$e.Id] = $e
        $fila = $ui.Filas[$e.Id]
        $fila.Estado = $e.Estado
        if ($e.Detalle) { $fila.DetalleEstado = $e.Detalle }
        Update-FilaUI -Fila $fila
    }
    Update-SeleccionUI
}

function Update-RecomendacionesFilasUI {
    # Auxiliar interna: marca las filas recomendadas con su motivo (resultado del trabajo "diagnostico").
    $ui = $global:OptiLowUI
    foreach ($id in $ui.Filas.Keys) {
        $fila = $ui.Filas[$id]
        $r = $ui.Recomendados[$id]
        if ($r) { $fila.Recomendado = [bool]$r.Recomendado; $fila.Motivo = [string]$r.Motivo }
        else { $fila.Recomendado = $false; $fila.Motivo = '' }
        Update-FilaUI -Fila $fila
    }
}

function Show-DetalleOptimizacionUI {
    <#
    .SYNOPSIS
        Muestra la descripción completa (con el efecto secundario) de una optimización en el panel de detalle.
    #>
    param(
        [Parameter(Mandatory)][string]$Id
    )

    $ui = $global:OptiLowUI
    if (-not $ui.Filas.Contains($Id)) { return }
    $fila = $ui.Filas[$Id]
    $d = $fila.Def
    $rev = 'sí'; if ($d.Reversible -eq $false) { $rev = 'NO (no se puede deshacer desde el journal)' }
    $req = switch ($d.Requiere) { 'Reiniciar' { 'reiniciar el equipo' } 'Cerrar sesión' { 'cerrar sesión' } default { 'nada' } }
    $texto = "{0}  [{1}]`nRiesgo: {2}.  Requiere: {3}.  Reversible: {4}.`n{5}" -f $d.Nombre, $d.Id, $d.Riesgo, $req, $rev, $d.Descripcion
    $t = Get-TextoEstadoUI -Estado $fila.Estado
    $texto += "`nEstado actual: " + $t[0] + '.'
    if ($fila.Recomendado -and $fila.Motivo) { $texto += "`nRecomendada: " + $fila.Motivo }
    elseif ((-not $fila.Recomendado) -and $fila.Motivo) { $texto += "`nNo recomendada: " + $fila.Motivo }
    $ui.C.TxtDetalle.Text = $texto
    $ui.C.TxtDetalle.Foreground = Get-PincelUI -Clave 'BrushTexto'
}

function Invoke-ClicCasillaUI {
    # Auxiliar interna: una casilla de una fila no seleccionable se desmarca y explica por qué.
    param(
        [Parameter(Mandatory)][string]$Id
    )

    $ui = $global:OptiLowUI
    $fila = $ui.Filas[$Id]
    Show-DetalleOptimizacionUI -Id $Id
    if ($fila.Check.IsChecked -and (-not (Test-FilaSeleccionableUI -Fila $fila))) {
        $fila.Check.IsChecked = $false
        $t = Get-TextoEstadoUI -Estado $fila.Estado
        $ui.C.TxtSeleccion.Text = "'$($fila.Def.Nombre)' no se puede seleccionar: estado «$($t[0])»."
        return
    }
    Update-SeleccionUI
}

function Get-IdsSeleccionadosUI {
    $ui = $global:OptiLowUI
    return @($ui.Filas.Keys | Where-Object { $ui.Filas[$_].Check.IsChecked -eq $true -and (Test-FilaSeleccionableUI -Fila $ui.Filas[$_]) })
}

function Update-SeleccionUI {
    # Auxiliar interna: texto "N seleccionadas" y, si no se puede aplicar, el motivo.
    $ui = $global:OptiLowUI
    $c = $ui.C
    if ((-not $c) -or (-not $c.TxtSeleccion)) { return }
    $n = @(Get-IdsSeleccionadosUI).Count
    $txt = "$n seleccionada(s)."
    $motivo = Get-MotivoNoAplicarUI
    if ($motivo) { $txt += ' ' + $motivo }
    $c.TxtSeleccion.Text = $txt
}

function Invoke-SeleccionarRecomendadasUI {
    <#
    .SYNOPSIS
        Marca las optimizaciones recomendadas para este hardware, omitiendo las ya aplicadas o que no aplican.
    #>
    $ui = $global:OptiLowUI
    if ($ui.Recomendados.Count -eq 0) {
        $ui.C.TxtSeleccion.Text = 'Aún no hay diagnóstico: espera a que termine o pulsa «Actualizar diagnóstico».'
        return
    }
    $n = 0
    foreach ($id in $ui.Filas.Keys) {
        $fila = $ui.Filas[$id]
        $marcar = ($fila.Recomendado -and (Test-FilaSeleccionableUI -Fila $fila))
        $fila.Check.IsChecked = $marcar
        if ($marcar) { $n++ }
    }
    Update-SeleccionUI
    if ($n -eq 0) { $ui.C.TxtSeleccion.Text = 'No hay optimizaciones recomendadas pendientes para este equipo. ' + $ui.C.TxtSeleccion.Text }
}

function Invoke-QuitarSeleccionUI {
    $ui = $global:OptiLowUI
    foreach ($id in $ui.Filas.Keys) { $ui.Filas[$id].Check.IsChecked = $false }
    Update-SeleccionUI
}

# ---------------------------------------------------------------------------------------------------------------
# Aplicar seleccionadas (máquina de estados: confirmar -> preparar -> decidir sobre el punto -> aplicar -> resumen)
# ---------------------------------------------------------------------------------------------------------------

function Get-ResultadoUnicoUI {
    # Auxiliar interna: el último objeto con propiedades que devolvió un trabajo (los trabajos devuelven uno).
    param(
        $Resultado
    )
    $objs = @($Resultado.Salida | Where-Object { $null -ne $_ })
    if ($objs.Count -eq 0) { return $null }
    return $objs[$objs.Count - 1]
}

function Invoke-AplicarSeleccionUI {
    <#
    .SYNOPSIS
        Botón «Aplicar seleccionadas»: motivo de rechazo, confirmación con la lista de cambios y advertencias,
        y arranque del trabajo «preparar».
    #>
    $ui = $global:OptiLowUI
    if ($ui.Trabajo) { return }

    $motivo = Get-MotivoNoAplicarUI
    if ($motivo) {
        [void](Show-DialogoOptiLow -Titulo 'No se puede aplicar' -Mensaje $motivo -Tipo Aviso -Botones @('Entendido'))
        return
    }
    $ids = @(Get-IdsSeleccionadosUI)
    if ($ids.Count -eq 0) {
        $ui.C.TxtSeleccion.Text = 'No hay nada seleccionado.'
        return
    }

    $defs = @($ids | ForEach-Object { $ui.Filas[$_].Def })
    $lineas = New-Object System.Collections.ArrayList
    foreach ($d in $defs) {
        [void]$lineas.Add(('• {0} [{1}] — Riesgo: {2} — Requiere: {3}' -f $d.Nombre, $d.Id, $d.Riesgo, $d.Requiere))
        [void]$lineas.Add('    ' + $d.Descripcion)
    }
    $adv = New-Object System.Collections.ArrayList
    $graves = @($defs | Where-Object { ($_.Riesgo -eq 'Alto') -or ($_.Reversible -eq $false) })
    if ($graves.Count -gt 0) {
        [void]$adv.Add('ATENCIÓN: estas optimizaciones son de riesgo ALTO o NO se pueden deshacer desde el journal:')
        foreach ($d in $graves) {
            $m = @(); if ($d.Riesgo -eq 'Alto') { $m += 'riesgo Alto' }; if ($d.Reversible -eq $false) { $m += 'no reversible' }
            [void]$adv.Add(('  ! {0} [{1}]: {2}' -f $d.Nombre, $d.Id, ($m -join ', ')))
        }
    }
    $otro = $ui.OtroUsuario
    if ($otro -and $otro.Distinto) {
        [void]$adv.Add("ESCRITORIO DE OTRO USUARIO: el escritorio es de '$($otro.UsuarioEscritorio)' pero OptiLow corre como '$($otro.UsuarioProceso)'. Los cambios de HKCU y %APPDATA% se aplicarían a la cuenta equivocada.")
    }
    $omitir = ($ui.C.ChkOmitirPunto.IsChecked -eq $true)
    $msg = 'Se van a aplicar estas optimizaciones. Antes se guarda un respaldo (journal) para poder deshacerlas'
    if ($omitir) { $msg += ' y NO se creará un punto de restauración de Windows (lo pediste).' } else { $msg += ' y se crea un punto de restauración de Windows.' }
    $r = Show-DialogoOptiLow -Titulo 'Confirmar cambios' -Mensaje $msg -Detalles @($lineas) -Advertencia ($adv -join "`n") `
        -Botones @('Cancelar', 'Aplicar') -Predeterminado 0 -Cancelar 0 -Tipo $(if ($adv.Count -gt 0) { 'Peligro' } else { 'Aviso' })
    if ($r -ne 1) {
        Write-Log -Mensaje 'Aplicar cancelado por el usuario. No se aplicó nada.'
        return
    }

    $ui.IdsAAplicar = @($ids)
    [void](Start-TrabajoUI -Nombre 'preparar' -Texto 'preparando el respaldo y el punto de restauración' -Parametros @{ Omitir = $omitir } -AlTerminar {
            param($res) Invoke-TrasPrepararUI -Resultado $res
        })
}

function Start-AplicarLoteUI {
    # Auxiliar interna: lanza el trabajo «aplicar» (misma sesión del journal, mismo runspace).
    $ui = $global:OptiLowUI
    [void](Start-TrabajoUI -Nombre 'aplicar' -Texto 'aplicando optimizaciones' -Parametros @{ Ids = @($ui.IdsAAplicar) } -AlTerminar {
            param($res) Invoke-TrasAplicarUI -Resultado $res
        })
}

function Invoke-TrasPrepararUI {
    <#
    .SYNOPSIS
        Decide qué hacer con el resultado del punto de restauración, con las mismas decisiones que la consola.
    #>
    param(
        [Parameter(Mandatory)]$Resultado,
        [switch]$YaIntentoActivar
    )

    $ui = $global:OptiLowUI
    if ($Resultado.Error) {
        [void](Show-DialogoOptiLow -Titulo 'No se pudo preparar el respaldo' -Mensaje "No se aplicó nada. $($Resultado.Error)" -Tipo Peligro -Botones @('Cerrar'))
        return
    }
    $out = Get-ResultadoUnicoUI -Resultado $Resultado
    if ((-not $out) -or $out.Omitido -or ($out.Punto -and $out.Punto.Creado)) {
        Start-AplicarLoteUI
        return
    }

    $p = $out.Punto
    $motivo = [string]$p.Motivo
    if ((@('Desactivada', 'SinEspacioAsignado') -contains $motivo) -and (-not $YaIntentoActivar)) {
        $r = Show-DialogoOptiLow -Titulo 'Protección del sistema desactivada' `
            -Mensaje "No se creó el punto de restauración: $($p.Detalle)" `
            -Detalles @('Puedo activar la Protección del sistema en la unidad del sistema.') `
            -Advertencia 'Ten en cuenta que la Protección del sistema USA ESPACIO EN DISCO (Windows reserva una parte de la unidad para los puntos de restauración).' `
            -Botones @('Cancelar', 'No activar', 'Activar protección') -Predeterminado 0 -Cancelar 0 -Tipo Aviso
        if ($r -eq 2) {
            [void](Start-TrabajoUI -Nombre 'proteccion' -Texto 'activando la Protección del sistema' -AlTerminar {
                    param($res) Invoke-TrasProteccionUI -Resultado $res
                })
            return
        }
        if ($r -eq 0) { Write-Log -Mensaje 'Cancelado. No se aplicó nada.'; return }
        # 'No activar' sigue con la pregunta de continuar sin punto
    }
    elseif ($motivo -eq 'YaExisteReciente') {
        $pr = $p.PuntoReciente
        $r = Show-DialogoOptiLow -Titulo 'Ya existe un punto de restauración reciente' `
            -Mensaje ("Windows no creó otro porque ya hay uno de las últimas 24 h: '{0}', creado el {1:yyyy-MM-dd HH:mm:ss} (número {2})." -f $pr.Descripcion, $pr.Fecha, $pr.Secuencia) `
            -Detalles @('¿Quieres continuar usando ese punto como respaldo de Windows? (El journal de OptiLow también permite deshacer.)') `
            -Botones @('Cancelar', 'Continuar con ese punto') -Predeterminado 0 -Cancelar 0 -Tipo Aviso
        if ($r -ne 1) { Write-Log -Mensaje 'Cancelado. No se aplicó nada.'; return }
        Start-AplicarLoteUI
        return
    }

    $r = Show-DialogoOptiLow -Titulo 'No se creó el punto de restauración' `
        -Mensaje "No se creó el punto de restauración: $($p.Detalle)" `
        -Detalles @('Si continúas, el journal seguirá permitiendo deshacer los cambios, pero no tendrás un punto de restauración de Windows.') `
        -Botones @('Cancelar', 'Continuar sin punto nuevo') -Predeterminado 0 -Cancelar 0 -Tipo Aviso
    if ($r -ne 1) { Write-Log -Mensaje 'Cancelado. No se aplicó nada.'; return }
    Start-AplicarLoteUI
}

function Invoke-TrasProteccionUI {
    # Auxiliar interna: resultado de activar la Protección del sistema (y de crear el punto tras activarla).
    param(
        [Parameter(Mandatory)]$Resultado
    )

    if ($Resultado.Error) {
        [void](Show-DialogoOptiLow -Titulo 'No se pudo activar la protección' -Mensaje "No se aplicó nada. $($Resultado.Error)" -Tipo Peligro -Botones @('Cerrar'))
        return
    }
    $out = Get-ResultadoUnicoUI -Resultado $Resultado
    if ($out.Punto -and $out.Punto.Creado) {
        Start-AplicarLoteUI
        return
    }
    $detalle = if ($out.Activacion.Activada) { 'La protección se activó pero tampoco se pudo crear el punto.' } else { 'No quedó activa: ' + $out.Activacion.Detalle + ' (puede que haga falta asignar espacio en Propiedades del sistema > Protección del sistema > Configurar).' }
    Write-Log -Nivel WARN -Mensaje $detalle
    # Se pregunta si seguir sin punto, usando el punto devuelto si lo hay
    $puntoFalso = $out.Punto
    if (-not $puntoFalso) { $puntoFalso = [pscustomobject]@{ Creado = $false; Motivo = 'Desactivada'; Detalle = $detalle; PuntoReciente = $null } }
    Invoke-TrasPrepararUI -Resultado ([pscustomobject]@{ Error = $null; Salida = @([pscustomobject]@{ Omitido = $false; Punto = $puntoFalso }) }) -YaIntentoActivar
}

function Invoke-TrasAplicarUI {
    <#
    .SYNOPSIS
        Resumen con el estado de cada optimización y el aviso de reiniciar o cerrar sesión; refresca los estados.
    #>
    param(
        [Parameter(Mandatory)]$Resultado
    )

    $ui = $global:OptiLowUI
    Invoke-QuitarSeleccionUI
    if ($Resultado.Error) {
        [void](Show-DialogoOptiLow -Titulo 'Error al aplicar' -Mensaje "Ocurrió un error: $($Resultado.Error)" -Detalles @('Lo que se haya aplicado a medias queda en el journal y se puede deshacer desde «Respaldo y restauración».') -Tipo Peligro -Botones @('Cerrar'))
    }
    else {
        $lote = Get-ResultadoUnicoUI -Resultado $Resultado
        $lineas = New-Object System.Collections.ArrayList
        $malos = 0
        foreach ($r in @($lote.Resultados)) {
            [void]$lineas.Add(('{0,-11} {1}  -  {2}' -f $r.Estado, $r.Nombre, $r.Detalle))
            if (@('Fallido', 'Parcial') -contains $r.Estado) { $malos++ }
        }
        $aviso = ''
        if ($lote.Requiere -eq 'Reiniciar') {
            $aviso = 'REINICIA el equipo para completar los cambios de: ' + ((@($lote.TweaksQueRequieren | Where-Object { $_.Requiere -eq 'Reiniciar' } | ForEach-Object { $_.Nombre })) -join ', ') + '. (Los servicios cambiados a Disabled siguen en ejecución hasta que reinicies.)'
        }
        elseif ($lote.Requiere -eq 'Cerrar sesión') {
            $aviso = 'CIERRA SESIÓN y vuelve a entrar para completar los cambios de: ' + ((@($lote.TweaksQueRequieren | ForEach-Object { $_.Nombre })) -join ', ') + '.'
        }
        $titulo = 'Resumen'; $tipo = 'Info'
        if ($malos -gt 0) { $titulo = 'Resumen: hubo fallos'; $tipo = 'Peligro' } elseif ($aviso) { $tipo = 'Aviso' }
        $msg = 'Resultado de cada optimización. Para deshacerlo todo: «Respaldo y restauración» > «Deshacer última sesión».'
        [void](Show-DialogoOptiLow -Titulo $titulo -Mensaje $msg -Detalles @($lineas) -Advertencia $aviso -Tipo $tipo -Botones @('Cerrar'))
    }
    Update-EstadosAsincronoUI
    $ui.SesionesCargadas = $false
}

function Update-EstadosAsincronoUI {
    <#
    .SYNOPSIS
        Lanza el trabajo «estados» y actualiza las filas al terminar.
    #>
    param(
        [scriptblock]$Despues
    )
    $ui = $global:OptiLowUI
    $ui.Despues = $Despues
    [void](Start-TrabajoUI -Nombre 'estados' -Texto 'comprobando el estado de las optimizaciones' -AlTerminar {
            param($res)
            if ($res.Error) { Write-Log -Nivel ERROR -Mensaje "No se pudieron comprobar los estados: $($res.Error)" }
            else { Update-EstadosFilasUI -Estados @($res.Salida) }
            $siguiente = $global:OptiLowUI.Despues
            $global:OptiLowUI.Despues = $null
            if ($siguiente) { & $siguiente }
        })
}

# ---------------------------------------------------------------------------------------------------------------
# Diagnóstico
# ---------------------------------------------------------------------------------------------------------------

function Add-FilaDatoUI {
    # Auxiliar interna: "Etiqueta: valor" en el panel del diagnóstico.
    param(
        [Parameter(Mandatory)][string]$Etiqueta,
        [AllowEmptyString()][string]$Valor,
        [string]$Color = 'BrushTexto'
    )

    $panel = $global:OptiLowUI.C.PanelDiagnostico
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $tb.Margin = (New-EspesorUI '0,0,0,3')
    $r1 = New-Object System.Windows.Documents.Run($Etiqueta + ': ')
    $r1.Foreground = Get-PincelUI -Clave 'BrushTextoSuave'
    $r2 = New-Object System.Windows.Documents.Run($Valor)
    $r2.Foreground = Get-PincelUI -Clave $Color
    [void]$tb.Inlines.Add($r1)
    [void]$tb.Inlines.Add($r2)
    [void]$panel.Children.Add($tb)
}

function Show-DiagnosticoUI {
    <#
    .SYNOPSIS
        Pinta el diagnóstico (solo muestra): datos del equipo, perfil con su motivo, recomendaciones por nivel,
        optimizaciones recomendadas con su motivo, duración y consultas lentas o fallidas.
    #>
    param(
        [Parameter(Mandatory)]$Hardware,
        [object[]]$Recomendados = @()
    )

    $ui = $global:OptiLowUI
    $panel = $ui.C.PanelDiagnostico
    $panel.Children.Clear()
    $hw = $Hardware

    if ($hw.Simulado) {
        [void]$panel.Children.Add((New-TextoUI -Texto 'DIAGNÓSTICO SIMULADO (datos de prueba, solo para ver)' -Color 'BrushSimulado' -Negrita -Margen '0,0,0,6'))
    }

    [void]$panel.Children.Add((New-TextoUI -Texto 'Equipo' -Color 'BrushAcento' -Negrita -Tam 14 -Margen '0,4,0,4'))
    $e = $hw.Equipo
    Add-FilaDatoUI -Etiqueta 'Equipo' -Valor ('{0} {1}' -f (Format-ValorHw $e.Fabricante), (Format-ValorHw $e.Modelo))
    if ($hw.EsMaquinaVirtual -eq $true) {
        Add-FilaDatoUI -Etiqueta 'Máquina virtual' -Valor ('hipervisor {0}. Motivo: {1}' -f (Format-ValorHw $hw.Hipervisor), $hw.MotivoVM) -Color 'BrushInfo'
    }
    $w = $hw.Windows
    if ($w) { Add-FilaDatoUI -Etiqueta 'Windows' -Valor ('{0} (compilación {1}, {2})' -f (Format-ValorHw $w.Nombre), (Format-ValorHw $w.Compilacion), (Format-ValorHw $w.Arquitectura)) }
    $cpu = $hw.CPU
    if ($cpu) { Add-FilaDatoUI -Etiqueta 'CPU' -Valor ('{0}  [{1} núcleos / {2} hilos]' -f (Format-ValorHw $cpu.Nombre), (Format-ValorHw $cpu.Nucleos), (Format-ValorHw $cpu.Hilos)) }
    else { Add-FilaDatoUI -Etiqueta 'CPU' -Valor 'desconocido' }
    Add-FilaDatoUI -Etiqueta 'RAM' -Valor (Format-RamHw -Ram $hw.RAM)

    if (@($hw.GPUs).Count -eq 0) { Add-FilaDatoUI -Etiqueta 'GPU' -Valor 'desconocido' }
    foreach ($g in @($hw.GPUs)) {
        $marcas = @()
        if ($hw.GPUPrincipal -and ($g.Nombre -eq $hw.GPUPrincipal.Nombre)) { $marcas += 'principal' }
        if ($g.EsVirtual) { $marcas += 'virtual/remota' }
        if ($g.SinDriver) { $marcas += 'SIN DRIVER' }
        if ($g.EsAntigua) { $marcas += 'antigua' }
        if ($g.SinSoporteFabricante) { $marcas += 'sin soporte activo del fabricante' }
        $fecha = 'sin fecha'; if ($g.FechaDriver) { $fecha = ('{0:yyyy-MM-dd}' -f $g.FechaDriver) }
        $extra = ''; if ($marcas.Count -gt 0) { $extra = '  <' + ($marcas -join ', ') + '>' }
        Add-FilaDatoUI -Etiqueta 'GPU' -Valor ('{0}  [driver {1}, {2}]{3}' -f $g.Nombre, (Format-ValorHw $g.DriverVersion), $fecha, $extra)
    }
    $d = $hw.Disco
    if ($d) {
        $tipoTxt = $d.Tipo; if ($d.EsNVMe) { $tipoTxt = 'SSD NVMe' }
        Add-FilaDatoUI -Etiqueta 'Disco' -Valor ('{0} {1}  [{2}; {3} GB, libre {4} GB = {5} %; salud {6}]' -f $d.Unidad, (Format-ValorHw $d.Modelo), $tipoTxt, (Format-ValorHw $d.TamanoGB), (Format-ValorHw $d.LibreGB), (Format-ValorHw $d.LibrePct), (Format-ValorHw $d.Salud))
        if ($d.EsVirtual) { Add-FilaDatoUI -Etiqueta '' -Valor '(disco virtual: el tipo y la salud no son fiables)' -Color 'BrushTextoSuave' }
    }
    else { Add-FilaDatoUI -Etiqueta 'Disco' -Valor 'desconocido' }
    $port = 'desconocido'; if ($hw.EsPortatil -eq $true) { $port = 'sí' } elseif ($hw.EsPortatil -eq $false) { $port = 'no' }
    Add-FilaDatoUI -Etiqueta 'Portátil' -Valor $port
    $ini = 'desconocido'; if ($null -ne $hw.InicioRapido) { $ini = $(if ($hw.InicioRapido) { 'activado' } else { 'desactivado' }) }
    $txtArranque = 'tiempo encendido desconocido'; if ($null -ne $hw.ArranqueDias) { $txtArranque = ('{0} días encendido' -f $hw.ArranqueDias) }
    Add-FilaDatoUI -Etiqueta 'Arranque' -Valor ('{0} (inicio rápido: {1})' -f $txtArranque, $ini)
    if ($hw.ProgramasInicio) { Add-FilaDatoUI -Etiqueta 'Programas de inicio' -Valor ('{0} habilitados ({1} deshabilitados)' -f $hw.ProgramasInicio.Habilitados, $hw.ProgramasInicio.Deshabilitados) }
    else { Add-FilaDatoUI -Etiqueta 'Programas de inicio' -Valor 'desconocido' }
    $a = $hw.Administracion
    if ($a) {
        $txtAdm = 'no se pudo comprobar'
        if ($a.Administrado -eq $true) { $txtAdm = 'SÍ: ' + ($a.Bloqueantes -join '; ') } elseif ($a.Administrado -eq $false) { $txtAdm = 'no (sin dominio ni Entra ID)' }
        Add-FilaDatoUI -Etiqueta 'Equipo administrado' -Valor $txtAdm
    }

    $colorPerfil = 'BrushTexto'
    if ($hw.Perfil -eq 'Bajo') { $colorPerfil = 'BrushAviso' } elseif ($hw.Perfil -eq 'Alto') { $colorPerfil = 'BrushOk' }
    [void]$panel.Children.Add((New-TextoUI -Texto ('PERFIL: {0}  ({1})' -f $hw.Perfil, $hw.PerfilMotivo) -Color $colorPerfil -Negrita -Tam 14 -Margen '0,12,0,4'))

    [void]$panel.Children.Add((New-TextoUI -Texto 'Recomendaciones' -Color 'BrushAcento' -Negrita -Tam 14 -Margen '0,10,0,4'))
    if (@($hw.Recomendaciones).Count -eq 0) { [void]$panel.Children.Add((New-TextoUI -Texto 'Sin recomendaciones.' -Color 'BrushTextoSuave')) }
    foreach ($rec in @($hw.Recomendaciones)) {
        $clave = switch ($rec.Nivel) { 'Crítico' { 'BrushError' } 'Aviso' { 'BrushAviso' } 'Info' { 'BrushInfo' } default { 'BrushTextoSuave' } }
        [void]$panel.Children.Add((New-TextoUI -Texto ('[{0}] {1}' -f $rec.Nivel, $rec.Titulo) -Color $clave -Negrita -Margen '0,4,0,0'))
        [void]$panel.Children.Add((New-TextoUI -Texto $rec.Detalle -Color 'BrushTextoSuave' -Tam 13 -Margen '14,0,0,2'))
    }

    if (@($Recomendados).Count -gt 0) {
        [void]$panel.Children.Add((New-TextoUI -Texto 'Optimizaciones recomendadas para este equipo' -Color 'BrushAcento' -Negrita -Tam 14 -Margen '0,12,0,4'))
        foreach ($t in @($Recomendados)) {
            $marca = 'No recomendada'; $clave = 'BrushTextoSuave'
            if ($t.Recomendado) { $marca = 'RECOMENDADA'; $clave = 'BrushOk' }
            [void]$panel.Children.Add((New-TextoUI -Texto ('{0}  ·  {1}  ·  {2}' -f $marca, $t.Nombre, $t.Estado) -Color $clave -Negrita -Margen '0,3,0,0'))
            if ($t.Motivo) { [void]$panel.Children.Add((New-TextoUI -Texto ('Por qué: ' + $t.Motivo) -Color 'BrushTextoSuave' -Tam 13 -Margen '14,0,0,2')) }
        }
    }

    [void]$panel.Children.Add((New-TextoUI -Texto '' -Margen '0,6,0,0'))
    if ($hw.Simulado) {
        [void]$panel.Children.Add((New-TextoUI -Texto 'Diagnóstico simulado: no se consultó el hardware real.' -Color 'BrushSimulado'))
    }
    else {
        [void]$panel.Children.Add((New-TextoUI -Texto ('Diagnóstico completado en {0:N1} s.' -f ($hw.DuracionMs / 1000)) -Color 'BrushTextoSuave'))
        $consultas = @($hw.Consultas)
        $lentas = @($consultas | Sort-Object Ms -Descending | Select-Object -First 3)
        if ($lentas.Count -gt 0) { [void]$panel.Children.Add((New-TextoUI -Texto ('Consultas más lentas: ' + (($lentas | ForEach-Object { '{0} ({1} ms)' -f $_.Nombre, $_.Ms }) -join ', ')) -Color 'BrushTextoSuave' -Tam 13)) }
        $malas = @($consultas | Where-Object { $_.Estado -ne 'Ok' })
        if ($malas.Count -gt 0) { [void]$panel.Children.Add((New-TextoUI -Texto ('Sin datos (marcadas como desconocidas): ' + (($malas | ForEach-Object { '{0} [{1}]' -f $_.Nombre, $_.Estado }) -join ', ')) -Color 'BrushAviso' -Tam 13)) }
        if ($hw.DuracionMs -gt 10000) { [void]$panel.Children.Add((New-TextoUI -Texto 'Aviso: el diagnóstico tardó más de 10 s (equipo lento o alguna consulta con problemas).' -Color 'BrushAviso' -Tam 13)) }
    }
}

function Invoke-DiagnosticoUI {
    <#
    .SYNOPSIS
        Lanza el diagnóstico en segundo plano (real, o simulado si el selector -Demo lo pide) y lo pinta al terminar.
    #>
    $ui = $global:OptiLowUI
    if ($ui.Trabajo) { return }
    $c = $ui.C
    $perfil = $null
    if ($c.DemoBajo.IsChecked) { $perfil = 'Bajo' } elseif ($c.DemoMedio.IsChecked) { $perfil = 'Medio' } elseif ($c.DemoAlto.IsChecked) { $perfil = 'Alto' }

    $c.TxtDiagEstado.Text = 'Analizando el equipo…'
    $parametros = @{ Perfil = $perfil }
    $texto = 'diagnóstico del equipo'; if ($perfil) { $texto = "diagnóstico simulado ($perfil)" }
    [void](Start-TrabajoUI -Nombre 'diagnostico' -Texto $texto -Parametros $parametros -AlTerminar {
            param($res)
            $ui = $global:OptiLowUI
            if ($res.Error) {
                $ui.C.PanelDiagnostico.Children.Clear()
                [void]$ui.C.PanelDiagnostico.Children.Add((New-TextoUI -Texto "No se pudo completar el diagnóstico: $($res.Error)" -Color 'BrushError'))
                return
            }
            $out = Get-ResultadoUnicoUI -Resultado $res
            $ui.Hardware = $out.Hardware
            $ui.Simulado = [bool]$out.Hardware.Simulado
            # Bloqueo estricto también en el hilo de la interfaz (el runspace de trabajo lo fija por su cuenta)
            $global:OptiLow.SimulacionActiva = $ui.Simulado
            $ui.Recomendados = @{}
            foreach ($r in @($out.Recomendados)) { $ui.Recomendados[$r.Id] = $r }
            Show-DiagnosticoUI -Hardware $out.Hardware -Recomendados @($out.Recomendados)
            Update-RecomendacionesFilasUI
            Update-BannersUI
            Update-EstadoBotonesUI
        })
}

# ---------------------------------------------------------------------------------------------------------------
# Respaldo y restauración (mínimo en la fase 5: listar y deshacer la última sesión)
# ---------------------------------------------------------------------------------------------------------------

function Update-SesionesUI {
    <#
    .SYNOPSIS
        Carga en segundo plano la lista de sesiones del journal y la pinta.
    #>
    $ui = $global:OptiLowUI
    if ($ui.Trabajo) { return }
    if (-not $global:OptiLow.DirRespaldos) {
        $ui.C.TxtRespaldoInfo.Text = 'No hay carpeta de respaldos (journal) disponible: ' + $(if (Test-EsAdministrador) { 'revisa el registro.' } else { 'se necesitan permisos de administrador.' })
        return
    }
    [void](Start-TrabajoUI -Nombre 'sesiones' -Texto 'leyendo las sesiones del journal' -AlTerminar {
            param($res)
            $ui = $global:OptiLowUI
            $c = $ui.C
            $c.PanelSesiones.Children.Clear()
            if ($res.Error) {
                $c.TxtRespaldoInfo.Text = "No se pudieron leer las sesiones: $($res.Error)"
                return
            }
            $ui.SesionesCargadas = $true
            $sesiones = @($res.Salida | Where-Object { $null -ne $_ })
            $ui.SesionesCache = $sesiones
            if ($sesiones.Count -eq 0) {
                $c.TxtRespaldoInfo.Text = 'No hay sesiones en el journal todavía.'
                return
            }
            $pendientes = @($sesiones | Where-Object { ($_.Estado -ne 'Restaurado') -and ($_.Entradas -gt 0) }).Count
            $c.TxtRespaldoInfo.Text = "$($sesiones.Count) sesión(es); $pendientes pendiente(s) de deshacer. «Deshacer última sesión» revierte la más reciente que no esté restaurada."
            foreach ($s in $sesiones) {
                $marco = New-Object System.Windows.Controls.Border
                $marco.Background = Get-PincelUI -Clave 'BrushPanel'
                $marco.BorderBrush = Get-PincelUI -Clave 'BrushBorde'
                $marco.BorderThickness = (New-EspesorUI '1')
                $marco.Padding = (New-EspesorUI '10,6')
                $marco.Margin = (New-EspesorUI '0,0,0,6')
                $pila = New-Object System.Windows.Controls.StackPanel
                $clave = switch ($s.Estado) { 'Restaurado' { 'BrushTextoSuave' } 'RestauradoParcial' { 'BrushAviso' } default { 'BrushTexto' } }
                [void]$pila.Children.Add((New-TextoUI -Texto ('{0}  ·  iniciada {1}  ·  {2}  ·  {3} entrada(s)' -f $s.Id, $s.Inicio, $s.Estado, $s.Entradas) -Color $clave -Negrita))
                $tw = 'sin optimizaciones registradas'; if (@($s.Tweaks).Count -gt 0) { $tw = @($s.Tweaks) -join ', ' }
                [void]$pila.Children.Add((New-TextoUI -Texto ('Optimizaciones: ' + $tw) -Color 'BrushTextoSuave' -Tam 13))
                $marco.Child = $pila
                [void]$c.PanelSesiones.Children.Add($marco)
            }
        })
}

function Invoke-DeshacerUI {
    <#
    .SYNOPSIS
        Botón «Deshacer última sesión»: confirmación, trabajo «deshacer», resultado y refresco de los estados.
    #>
    $ui = $global:OptiLowUI
    if ($ui.Trabajo) { return }
    $motivo = Get-MotivoNoAplicarUI
    if ($motivo) {
        [void](Show-DialogoOptiLow -Titulo 'No se puede deshacer' -Mensaje $motivo -Tipo Aviso -Botones @('Entendido'))
        return
    }
    # Se vuelve a leer la lista para no deshacer a partir de datos viejos; después se decide
    $ui.SesionesCargadas = $false
    [void](Start-TrabajoUI -Nombre 'sesiones' -Texto 'buscando la última sesión pendiente' -AlTerminar {
            param($res)
            $ui = $global:OptiLowUI
            if ($res.Error) {
                [void](Show-DialogoOptiLow -Titulo 'No se pudo leer el journal' -Mensaje $res.Error -Tipo Peligro -Botones @('Cerrar'))
                return
            }
            $sesiones = @($res.Salida | Where-Object { $null -ne $_ })
            $objetivo = $sesiones | Where-Object { ($_.Estado -ne 'Restaurado') -and ($_.Entradas -gt 0) } | Select-Object -First 1
            if (-not $objetivo) {
                [void](Show-DialogoOptiLow -Titulo 'Nada que deshacer' -Mensaje 'No hay ninguna sesión pendiente de deshacer.' -Botones @('Cerrar'))
                Update-SesionesUI
                return
            }
            $det = @("Sesión $($objetivo.Id), iniciada $($objetivo.Inicio), estado $($objetivo.Estado), $($objetivo.Entradas) entrada(s).")
            if (@($objetivo.Tweaks).Count -gt 0) { $det += 'Optimizaciones de esa sesión: ' + (@($objetivo.Tweaks) -join ', ') }
            $r = Show-DialogoOptiLow -Titulo 'Deshacer la última sesión' -Mensaje 'Se van a revertir los cambios de esta sesión del journal, en orden inverso.' -Detalles $det `
                -Botones @('Cancelar', 'Deshacer') -Predeterminado 0 -Cancelar 0 -Tipo Aviso
            if ($r -ne 1) { Write-Log -Mensaje 'Deshacer cancelado por el usuario.'; return }
            $ui.SesionDeshacer = $objetivo
            [void](Start-TrabajoUI -Nombre 'deshacer' -Texto 'deshaciendo la sesión' -Parametros @{ Id = $objetivo.Id } -AlTerminar {
                    param($res2)
                    Invoke-TrasDeshacerUI -Resultado $res2
                })
        })
}

function Invoke-TrasDeshacerUI {
    # Auxiliar interna: resultado de deshacer (restauradas y fallidas) y refresco de estados y sesiones.
    param(
        [Parameter(Mandatory)]$Resultado
    )

    $ui = $global:OptiLowUI
    if ($Resultado.Error) {
        [void](Show-DialogoOptiLow -Titulo 'Error al deshacer' -Mensaje $Resultado.Error -Tipo Peligro -Botones @('Cerrar'))
    }
    else {
        $r = Get-ResultadoUnicoUI -Resultado $Resultado
        if ($r -and ($r.Estado -eq 'RestauradoParcial')) {
            $det = @($r.Fallidas | ForEach-Object { '{0} ({1}): {2}' -f $_.Descripcion, $_.Tipo, $_.Error })
            [void](Show-DialogoOptiLow -Titulo 'Restauración parcial' -Mensaje "Se restauraron $($r.Restauradas) entrada(s), pero estas fallaron:" -Detalles $det -Tipo Peligro -Botones @('Cerrar'))
        }
        elseif ($r) {
            [void](Show-DialogoOptiLow -Titulo 'Sesión deshecha' -Mensaje "Se restauraron $($r.Restauradas) entrada(s) correctamente." -Botones @('Cerrar'))
        }
        else {
            [void](Show-DialogoOptiLow -Titulo 'Nada que deshacer' -Mensaje 'No había ninguna sesión pendiente.' -Botones @('Cerrar'))
        }
    }
    $ui.SesionesCargadas = $false
    Update-EstadosAsincronoUI -Despues { Update-SesionesUI }
}

# ---------------------------------------------------------------------------------------------------------------
# Registro (log)
# ---------------------------------------------------------------------------------------------------------------

function Copy-LogUI {
    $ui = $global:OptiLowUI
    try {
        [System.Windows.Clipboard]::SetText(($ui.LineasLog -join "`r`n"))
        $ui.C.TxtEstadoTrabajo.Text = "Copiadas $($ui.LineasLog.Count) líneas del registro."
    }
    catch {
        Write-Log -Nivel WARN -Mensaje "No se pudo copiar al portapapeles: $($_.Exception.Message)"
    }
}

function Open-CarpetaLogsUI {
    $dir = $global:OptiLow.DirLogs
    if (-not $dir) { Write-Log -Nivel WARN -Mensaje 'No hay carpeta de logs disponible.'; return }
    try { [void][System.Diagnostics.Process]::Start('explorer.exe', ('"' + $dir + '"')) }
    catch { Write-Log -Nivel WARN -Mensaje "No se pudo abrir la carpeta de logs: $($_.Exception.Message)" }
}

function Clear-VistaLogUI {
    $ui = $global:OptiLowUI
    $ui.C.ListaLog.Items.Clear()
    $ui.LineasLog.Clear()
}

# ---------------------------------------------------------------------------------------------------------------
# Renderizado por software y cierre
# ---------------------------------------------------------------------------------------------------------------

function Invoke-CasillaSoftwareUI {
    # Auxiliar interna: guarda la preferencia de renderizado por software (se aplica al reabrir).
    $ui = $global:OptiLowUI
    $marcado = ($ui.C.ChkSoftware.IsChecked -eq $true)
    $ok = Save-PreferenciasUI -Preferencias @{ RenderizadoSoftware = $marcado }
    if ($ok) {
        Write-Log -Mensaje ("Preferencia guardada: renderizado por software {0}. Se aplica al volver a abrir OptiLow." -f $(if ($marcado) { 'ACTIVADO' } else { 'desactivado' }))
        [void](Show-DialogoOptiLow -Titulo 'Renderizado por software' -Mensaje 'Preferencia guardada. Cierra y vuelve a abrir OptiLow para que se aplique.' -Botones @('Entendido'))
    }
    else {
        [void](Show-DialogoOptiLow -Titulo 'Renderizado por software' -Mensaje 'No se pudo guardar la preferencia (mira el registro). Mientras tanto puedes abrir OptiLow con «Iniciar (modo seguro).cmd».' -Tipo Aviso -Botones @('Entendido'))
    }
}

function Test-PuedeCerrarUI {
    <#
    .SYNOPSIS
        Lógica de cierre: sin trabajo en curso se cierra; con uno, pide confirmación avisando de que lo aplicado
        a medias queda en el journal y se puede deshacer. No se cancela un trabajo a la mitad.
    #>
    $ui = $global:OptiLowUI
    if (-not $ui.Trabajo) { return $true }
    $r = Show-DialogoOptiLow -Titulo 'Hay un trabajo en curso' `
        -Mensaje ("OptiLow todavía está trabajando ({0}). Si cierras ahora, lo que se haya aplicado a medias queda registrado en el journal y se puede deshacer desde «Respaldo y restauración» la próxima vez." -f $ui.Trabajo.Texto) `
        -Botones @('Seguir esperando', 'Cerrar de todos modos') -Predeterminado 0 -Cancelar 0 -Tipo Aviso
    return ($r -eq 1)
}

# ---------------------------------------------------------------------------------------------------------------
# Conexión de eventos y contenido inicial
# ---------------------------------------------------------------------------------------------------------------

function Connect-EventosUI {
    <#
    .SYNOPSIS
        Conecta los eventos de los controles. Los manejadores llaman a funciones globales.
    #>
    $ui = $global:OptiLowUI
    $c = $ui.C

    $c.Navegacion.Add_SelectionChanged({ param($s, $e) Invoke-ManejadorUI { if ($s.SelectedIndex -ge 0) { Set-VistaUI -Indice $s.SelectedIndex } } })
    $c.BtnActualizarDiag.Add_Click({ Invoke-ManejadorUI { Invoke-DiagnosticoUI } })
    foreach ($n in @('DemoReal', 'DemoBajo', 'DemoMedio', 'DemoAlto')) {
        $c[$n].Add_Click({ Invoke-ManejadorUI { Invoke-DiagnosticoUI } })
    }
    $c.BtnSeleccionarRec.Add_Click({ Invoke-ManejadorUI { Invoke-SeleccionarRecomendadasUI } })
    $c.BtnQuitarSel.Add_Click({ Invoke-ManejadorUI { Invoke-QuitarSeleccionUI } })
    $c.BtnAplicar.Add_Click({ Invoke-ManejadorUI { Invoke-AplicarSeleccionUI } })
    $c.BtnActualizarSesiones.Add_Click({ Invoke-ManejadorUI { $global:OptiLowUI.SesionesCargadas = $false; Update-SesionesUI } })
    $c.BtnDeshacer.Add_Click({ Invoke-ManejadorUI { Invoke-DeshacerUI } })
    $c.BtnCopiarLog.Add_Click({ Invoke-ManejadorUI { Copy-LogUI } })
    $c.BtnAbrirLogs.Add_Click({ Invoke-ManejadorUI { Open-CarpetaLogsUI } })
    $c.BtnLimpiarLog.Add_Click({ Invoke-ManejadorUI { Clear-VistaLogUI } })
    $c.ChkSoftware.Add_Click({ Invoke-ManejadorUI { Invoke-CasillaSoftwareUI } })

    $c.VentanaPrincipal.Add_Closing({
            param($s, $e)
            try { if (-not (Test-PuedeCerrarUI)) { $e.Cancel = $true } } catch { }
        })
    $c.VentanaPrincipal.Add_Closed({
            param($s, $e)
            try { Stop-TrabajosUI } catch { }
            try { $s.Dispatcher.InvokeShutdown() } catch { }
        })
}

function Initialize-ContenidoUI {
    <#
    .SYNOPSIS
        Rellena la ventana cuando Core/, Modules/ y Tweaks/ ya están cargados: cabecera, banners, lista de
        optimizaciones, eventos, temporizador y estado de la barra inferior. No arranca los trabajos.
    #>
    $ui = $global:OptiLowUI
    $c = $ui.C
    $opc = $ui.Opciones

    $ui.OtroUsuario = Test-EscritorioDeOtroUsuario
    if ($ui.OtroUsuario -and $ui.OtroUsuario.Distinto) {
        Write-Log -Nivel WARN -Mensaje "El escritorio pertenece a '$($ui.OtroUsuario.UsuarioEscritorio)' pero el script corre como '$($ui.OtroUsuario.UsuarioProceso)'. Los cambios de HKCU y %APPDATA% se aplicarían a la cuenta equivocada."
    }

    if ($opc.Demo) { $c.PanelDemo.Visibility = 'Visible' }
    $c.ChkSoftware.IsChecked = ($opc.PreferenciaSoftware -eq $true) -or ($ui.ModoRender -like 'Software*')

    Initialize-ListaOptimizacionesUI
    Connect-EventosUI
    Update-BannersUI
    Update-EstadoBotonesUI

    $tier = 'desconocida'
    try { $tier = [string]([System.Windows.Media.RenderCapability]::Tier -shr 16) } catch { }
    $c.TxtRender.Text = "Render: $($ui.ModoRender) · Capacidad gráfica: nivel $tier"
    Write-Log -Mensaje "Renderizado: $($ui.ModoRender). Capacidad gráfica de WPF (RenderCapability.Tier): nivel $tier (0 = sin aceleración)."
}

function Start-TrabajosIniciales {
    <#
    .SYNOPSIS
        Arranca el runspace de trabajo y encadena: cargar el motor -> estados de las optimizaciones -> diagnóstico.
    #>
    $ui = $global:OptiLowUI
    Start-TemporizadorUI
    Start-RunspaceTrabajo
    [void](Start-TrabajoUI -Nombre 'iniciar' -Texto 'cargando el motor en segundo plano' `
            -Parametros @{ Raiz = $ui.Raiz; Cola = $ui.Cola; SinElevar = [bool]$ui.Opciones.SinElevar } -AlTerminar {
            param($res)
            if ($res.Error) {
                Write-Log -Nivel ERROR -Mensaje "No se pudo cargar el motor en segundo plano: $($res.Error)"
                $global:OptiLowUI.C.TxtDiagEstado.Text = "No se pudo cargar el motor en segundo plano: $($res.Error)"
                return
            }
            Update-EstadosAsincronoUI -Despues { Invoke-DiagnosticoUI }
        })
}
