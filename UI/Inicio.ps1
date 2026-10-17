# UI/Inicio.ps1
# Arranque de la interfaz. Objetivo: que algo aparezca cuanto antes (la consola va oculta en modo interfaz).
#
# Decisión de diseño (medida, ver docs/PLAN-FASE5.md): NO hay una pantalla de "Cargando…" aparte (formulario de
# Windows Forms en otro hilo). Se midió y no gana tiempo: cargar WPF cuesta unos 15-90 ms con el disco en caché,
# mientras que el formulario aparte aparecía ~100 ms DESPUÉS y, creado antes que la primera ventana WPF, saldría
# borroso con escala del 125-150 % (powershell.exe no declara DPI hasta que WPF crea su primera ventana). La
# propia ventana principal aparece enseguida con un panel "Cargando…" y el proyecto se carga por pasos, dejando
# pintar entre archivo y archivo. Así no hay nada extra que cerrar ni que pueda fallar.
#
# Orden: administrador (sin cargar Core/, en OptiLow.ps1) -> WPF -> ventana con "Cargando…" -> Core/ -> Modules/ y
# Tweaks/ -> lista de optimizaciones -> trabajos en segundo plano (estados y diagnóstico).
# Los tiempos de cada etapa se miden desde el inicio del proceso, se escriben en el log y se muestran en la barra
# de estado ("Abierto en X,X s").

function Set-TiempoUI {
    # Auxiliar interna: anota el tiempo transcurrido desde el inicio del proceso (ms) para una etapa.
    param(
        [Parameter(Mandatory)][string]$Etapa
    )
    $ui = $global:OptiLowUI
    $ui.Tiempos[$Etapa] = [int]((Get-Date) - $ui.InicioProceso).TotalMilliseconds
}

function Add-RegistroInicialUI {
    # Auxiliar interna: mensajes de antes de que exista el log; se vuelcan cuando Core/ ya está cargado.
    param(
        [string]$Nivel = 'INFO',
        [Parameter(Mandatory)][string]$Mensaje
    )
    [void]$global:OptiLowUI.RegistroInicial.Add(@($Nivel, $Mensaje))
}

function Wait-PrimerDibujoUI {
    # Auxiliar interna: bombea mensajes hasta que la ventana hizo su primer dibujo (o pasa el tiempo límite).
    param(
        [int]$LimiteMs = 15000
    )
    $ui = $global:OptiLowUI
    $reloj = [System.Diagnostics.Stopwatch]::StartNew()
    while ((-not $ui.PrimerDibujo) -and ($reloj.ElapsedMilliseconds -lt $LimiteMs)) {
        Invoke-BombearUI
        if (-not $ui.PrimerDibujo) { Start-Sleep -Milliseconds 10 }
    }
}

function Set-TextoCargaUI {
    # Auxiliar interna: texto del panel "Cargando…" y un bombeo para que se pinte.
    param(
        [Parameter(Mandatory)][string]$Texto
    )
    $global:OptiLowUI.C.TxtCarga.Text = $Texto
    Invoke-BombearUI
}

function Start-OptiLowInterfaz {
    <#
    .SYNOPSIS
        Abre la interfaz y no vuelve hasta que se cierra la ventana. Devuelve el código de salida (0 bien, 1 error).
    .PARAMETER Opciones
        Demo, SinElevar, RenderizadoSoftware (forzado por parámetro) y MostrarConsola.
    .PARAMETER SinBucle
        Solo para las pruebas: vuelve tras el arranque sin ejecutar el bucle de la ventana.
    #>
    param(
        [Parameter(Mandatory)][string]$Raiz,
        [hashtable]$Opciones = @{},
        [string[]]$CoreYaCargado = @('Paths.ps1', 'Logging.ps1', 'Admin.ps1'),
        [switch]$SinBucle
    )

    Initialize-EstadoUI -Raiz $Raiz -Opciones $Opciones
    $ui = $global:OptiLowUI
    $ui.RegistroInicial = New-Object System.Collections.ArrayList
    $ui.PrimerDibujo = $false
    $ui.InicioProceso = (Get-Process -Id $PID).StartTime
    Set-TiempoUI -Etapa 'Script en marcha'

    $ventana = $null
    try {
        # 1. WPF (lo más lento en un HDD)
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        Set-TiempoUI -Etapa 'WPF cargado'

        # 2. Modo de renderizado: -RenderizadoSoftware > preferencia guardada > automático. Se fija ANTES de crear
        #    la primera ventana. Es una preferencia: el sistema puede forzar software igualmente.
        $prefs = Get-PreferenciasUI
        $Opciones.PreferenciaSoftware = [bool]$prefs.RenderizadoSoftware
        $forzarSoftware = $false
        if ($Opciones.RenderizadoSoftware) { $ui.ModoRender = 'Software (forzado por parámetro)'; $forzarSoftware = $true }
        elseif ($prefs.RenderizadoSoftware) { $ui.ModoRender = 'Software (preferencia guardada)'; $forzarSoftware = $true }
        if ($forzarSoftware) {
            [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly
        }

        # 3. Ventana. Si falla con el modo normal, se reintenta UNA vez en software y se avisa.
        try {
            $ventana = New-OptiLowVentana
            $ventana.Add_ContentRendered({ $global:OptiLowUI.PrimerDibujo = $true })
            $ventana.Add_Closed({ $global:OptiLowUI.Cerrada = $true })
            $ventana.Show()
        }
        catch {
            if ($forzarSoftware) { throw }
            Add-RegistroInicialUI -Nivel WARN -Mensaje "No se pudo crear la ventana con el renderizado normal ($($_.Exception.Message)). Se reintenta en modo software."
            try { if ($ventana) { $ventana.Close() } } catch { }
            [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly
            $ui.ModoRender = 'Software (reintento automático)'
            $ventana = New-OptiLowVentana
            $ventana.Add_ContentRendered({ $global:OptiLowUI.PrimerDibujo = $true })
            $ventana.Add_Closed({ $global:OptiLowUI.Cerrada = $true })
            $ventana.Show()
        }
        Set-TiempoUI -Etapa 'Ventana creada'
        Wait-PrimerDibujoUI
        Set-TiempoUI -Etapa 'Primer dibujo ("Cargando…")'
        # Iniciar.cmd deja de mostrar "Abriendo OptiLow…" cuando ya hay ventana (la función vive en OptiLow.ps1)
        if (Get-Command -Name 'Write-SenalApertura' -ErrorAction SilentlyContinue) { Write-SenalApertura }

        # 4. Core/ archivo por archivo, pintando entre uno y otro. Un fallo aquí es fatal.
        $orden = @($global:OptiLowOrdenCore)
        for ($i = 0; $i -lt $orden.Count; $i++) {
            $nombre = $orden[$i]
            if ($CoreYaCargado -contains $nombre) { continue }
            Set-TextoCargaUI -Texto ("Cargando el motor… ({0}/{1})" -f ($i + 1), $orden.Count)
            $ruta = Join-Path (Join-Path $Raiz 'Core') $nombre
            if (-not (Test-Path -LiteralPath $ruta)) { throw "Falta el archivo obligatorio 'Core\$nombre'. El programa no puede continuar." }
            try { Import-OptiLowArchivo -Ruta $ruta }
            catch { throw "Error fatal al cargar 'Core\$nombre': $($_.Exception.Message)" }
        }
        Test-OptiLowFuncionesCore
        Set-TiempoUI -Etapa 'Core/ cargado'

        # 5. Rutas y log: el log va a la cola compartida que vacía el temporizador
        Initialize-OptiLowRutas -Raiz $Raiz
        $global:OptiLow.ColaLog = $ui.Cola
        Initialize-OptiLowLog -Destino Cola
        foreach ($m in @($ui.RegistroInicial)) { Write-Log -Nivel $m[0] -Mensaje $m[1] }
        $ui.RegistroInicial.Clear()
        Write-Log -Mensaje "OptiLow (interfaz) iniciado. PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)), hilo $([System.Threading.Thread]::CurrentThread.GetApartmentState())."
        Write-Log -Mensaje "Usuario: $([Security.Principal.WindowsIdentity]::GetCurrent().Name). Administrador: $(if (Test-EsAdministrador) { 'sí' } else { 'no' }). Carpeta del programa: $Raiz"
        if ($Opciones.SinElevar -and -not (Test-EsAdministrador)) {
            Write-Log -Nivel WARN -Mensaje 'Se ejecuta SIN permisos de administrador (-SinElevar): no se podrán aplicar cambios al sistema.'
        }
        if ((Test-EsAdministrador)) { [void](Initialize-CarpetaRespaldos) }

        # 6. Modules/ y Tweaks/ (toleran fallos), también por pasos
        $extras = @(Get-OptiLowArchivosExtras -Raiz $Raiz)
        $cargados = 0; $fallidos = 0
        for ($i = 0; $i -lt $extras.Count; $i++) {
            $archivo = $extras[$i]
            Set-TextoCargaUI -Texto ("Cargando diagnóstico y optimizaciones… ({0}/{1})" -f ($i + 1), $extras.Count)
            try { Import-OptiLowArchivo -Ruta $archivo.FullName; $cargados++ }
            catch {
                $fallidos++
                Write-Log -Nivel ERROR -Mensaje "No se pudo cargar $($archivo.Directory.Name)\$($archivo.Name): $($_.Exception.Message)"
            }
        }
        Write-Log -Nivel OK -Mensaje "Carga terminada. Archivos de Modules/Tweaks cargados: $cargados. Con error: $fallidos. Optimizaciones registradas: $(@(Get-Tweak).Count)."
        Set-TiempoUI -Etapa 'Modules/ y Tweaks/ cargados'

        # 7. Contenido de la ventana y fin del "Cargando…"
        Set-TextoCargaUI -Texto 'Preparando la ventana…'
        Initialize-ContenidoUI
        Set-TiempoUI -Etapa 'Contenido preparado'
        $ui.C.PanelCarga.Visibility = 'Collapsed'
        Invoke-BombearUI
        Invoke-BombearUI
        Set-TiempoUI -Etapa 'Lista de optimizaciones visible'

        $total = $ui.Tiempos['Lista de optimizaciones visible']
        $ui.C.TxtApertura.Text = ('Abierto en {0:N1} s' -f ($total / 1000))
        $partes = @($ui.Tiempos.GetEnumerator() | ForEach-Object { '{0}: {1} ms' -f $_.Key, $_.Value })
        Write-Log -Mensaje ('Tiempos de arranque (desde el inicio del proceso): ' + ($partes -join ' | '))

        # 8. Trabajos en segundo plano: motor -> estados -> diagnóstico
        Start-TrabajosIniciales
    }
    catch {
        # Cerrar la ventana en cualquier momento (incluso mientras carga) no es un error: se sale en silencio
        if (($_.Exception.Message -eq 'OPTILOW-VENTANA-CERRADA') -or $ui.Cerrada) {
            try { Write-Log -Mensaje 'La ventana se cerró mientras se cargaba: se sale sin error.' } catch { }
            try { Stop-TrabajosUI } catch { }
            if (Get-Command -Name 'Write-SenalApertura' -ErrorAction SilentlyContinue) { Write-SenalApertura }
            return 0
        }
        $msg = "No se pudo iniciar la interfaz: $($_.Exception.Message)"
        try { if ($ventana) { $ventana.Close() } } catch { }
        Show-ErrorSinWpf -Mensaje $msg
        return 1
    }

    # Las pruebas automáticas manejan el dispatcher ellas mismas
    if ($SinBucle) { return 0 }

    # Si la ventana se cerró justo antes de empezar el bucle, no hay nada que ejecutar
    $dis = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    if ($ui.Cerrada -or $dis.HasShutdownStarted -or $dis.HasShutdownFinished) { try { Stop-TrabajosUI } catch { }; return 0 }

    # 9. Bucle de la ventana hasta que se cierre (el evento Closed llama a InvokeShutdown)
    try {
        [System.Windows.Threading.Dispatcher]::Run()
    }
    catch {
        if ($ui.Cerrada -or $dis.HasShutdownStarted -or $dis.HasShutdownFinished) { return 0 }
        Show-ErrorSinWpf -Mensaje "La interfaz se cerró por un error: $($_.Exception.Message)"
        return 1
    }
    return 0
}
