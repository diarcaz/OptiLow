# Core/PuntoRestauracion.ps1
# Punto de restauración de Windows.
#
# MÉTODO (decisión tomada tras probar en una VM con Windows 11 24H2):
#   - Windows PowerShell 5.1 (objetivo principal): Checkpoint-Computer -RestorePointType MODIFY_SETTINGS.
#   - PowerShell 7 (donde Checkpoint-Computer no existe): CIM SystemRestore.CreateRestorePoint, solo como respaldo.
#   Motivo: en la VM, CreateRestorePoint por CIM con SystemRestorePointCreationFrequency = 0 terminó sin
#   crear el punto (en menos de un segundo, había uno de las últimas 24 h), mientras que Checkpoint-Computer
#   con el mismo ajuste sí lo creó. Después, Pruebas/Diagnostico-PuntoRestauracion.ps1 mostró que CIM SÍ creó
#   el punto (ReturnValue=0, ~5 s): el fallo es inconsistente. Hipótesis sin confirmar: el proveedor de
#   SystemRestore lee la frecuencia al cargarse y ya estaba cargado antes de ajustarla a 0. Tema cerrado.
#   Por eso el éxito NUNCA se asume: se comprueba comparando los SequenceNumber antes y después, y del
#   método CIM se registra siempre el ReturnValue.
#
# Datos verificados en Microsoft Learn (CreateRestorePoint, clase SystemRestore):
#   - CreateRestorePoint(String Description, uint32 RestorePointType, uint32 EventType)
#     MODIFY_SETTINGS = 12, BEGIN_SYSTEM_CHANGE = 100.
#   - Por defecto Windows OMITE el punto (y devuelve S_OK) si hubo otro en las últimas 24 h.
#     Se evita con el DWORD SystemRestorePointCreationFrequency = 0 en
#     HKLM\Software\Microsoft\Windows NT\CurrentVersion\SystemRestore.
#   - SystemRestore.Enable(String Drive) activa la protección; devuelve sin esperar.
#
# Core/ NO activa la Protección del sistema por su cuenta: devuelve un motivo claro y la consola o la
# interfaz preguntan al usuario antes de llamar a Enable-ProteccionSistema (usa espacio en disco).
#
# Detección de "protección desactivada / sin espacio" (confirmada en la VM para el caso "activa"):
# política DisableSR=1, o ausencia de Win32_ShadowStorage para la unidad del sistema, o MaxSpace = 0.
function Get-EstadoProteccionSistema {
    <#
    .SYNOPSIS
        Estima si la Protección del sistema está activa en la unidad del sistema. Solo lee.
    .OUTPUTS
        Objeto con Motivo y Detalle. Motivo: Activa, BloqueadaPorDirectiva, Desactivada,
        SinEspacioAsignado o Desconocido.
    .EXAMPLE
        Get-EstadoProteccionSistema
    #>
    try {
        $politica = Get-RegistroEstado -Ruta 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Nombre 'DisableSR'
        if ($politica.ValorExiste -and ([int64]$politica.Dato -eq 1)) {
            return [pscustomobject]@{ Motivo = 'BloqueadaPorDirectiva'; Detalle = 'Una directiva del sistema desactiva la Restauración del sistema (DisableSR=1).' }
        }

        $unidad = $env:SystemDrive
        $volumen = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$unidad'" -ErrorAction Stop | Select-Object -First 1
        if (-not $volumen) {
            return [pscustomobject]@{ Motivo = 'Desconocido'; Detalle = "No se encontró el volumen $unidad." }
        }
        $almacen = Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction Stop |
            Where-Object { $_.Volume.DeviceID -eq $volumen.DeviceID } | Select-Object -First 1
        if (-not $almacen) {
            return [pscustomobject]@{ Motivo = 'Desactivada'; Detalle = "La Protección del sistema parece desactivada en $unidad (no hay almacenamiento de instantáneas)." }
        }
        if ([uint64]$almacen.MaxSpace -eq 0) {
            return [pscustomobject]@{ Motivo = 'SinEspacioAsignado'; Detalle = "La Protección del sistema no tiene espacio asignado en $unidad." }
        }
        return [pscustomobject]@{ Motivo = 'Activa'; Detalle = "Protección del sistema activa en $unidad." }
    }
    catch {
        return [pscustomobject]@{ Motivo = 'Desconocido'; Detalle = "No se pudo determinar el estado: $($_.Exception.Message)" }
    }
}

function ConvertFrom-FechaPuntoRestauracion {
    # Auxiliar interna: fecha DMTF de WMI ("20261016033524.000000-000") -> [datetime] local, o $null.
    param(
        [string]$Texto
    )

    if (-not $Texto) { return $null }
    try {
        Add-Type -AssemblyName System.Management -ErrorAction SilentlyContinue
        return [System.Management.ManagementDateTimeConverter]::ToDateTime($Texto)
    }
    catch { }
    try {
        return [datetime]::ParseExact($Texto.Substring(0, 14), 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch { return $null }
}

function Get-PuntosRestauracion {
    <#
    .SYNOPSIS
        Lista los puntos de restauración existentes (Secuencia, Descripcion, Fecha), el más reciente primero.
    .EXAMPLE
        Get-PuntosRestauracion | Format-Table
    #>
    $lista = @(Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore -ErrorAction Stop)
    $puntos = @($lista | ForEach-Object {
            [pscustomobject]@{
                Secuencia   = [int64]$_.SequenceNumber
                Descripcion = [string]$_.Description
                Fecha       = (ConvertFrom-FechaPuntoRestauracion -Texto $_.CreationTime)
            }
        })
    return @($puntos | Sort-Object Secuencia -Descending)
}

function New-ResultadoPunto {
    # Auxiliar interna: objeto de resultado de New-PuntoRestauracion.
    param(
        [bool]$Creado,
        [string]$Motivo,
        [string]$Detalle,
        [string]$Metodo = '',
        $Secuencia = $null,
        $PuntoReciente = $null
    )
    return [pscustomobject]@{
        Creado         = $Creado
        Motivo         = $Motivo
        Detalle        = $Detalle
        Metodo         = $Metodo
        SequenceNumber = $Secuencia
        PuntoReciente  = $PuntoReciente
    }
}

function New-PuntoRestauracion {
    <#
    .SYNOPSIS
        Crea un punto de restauración. No pregunta nada ni activa la protección: devuelve un motivo.
    .DESCRIPTION
        Método: Checkpoint-Computer en Windows PowerShell 5.1; CIM SystemRestore solo como respaldo
        (PowerShell 7, donde Checkpoint-Computer no existe). Ver el comentario al inicio del archivo.
        Ajusta temporalmente SystemRestorePointCreationFrequency = 0 (a través del journal, para
        sobrevivir a un cierre brusco) y lo revierte SIEMPRE en un bloque finally.
        El éxito se comprueba comparando los SequenceNumber antes y después.
    .OUTPUTS
        Objeto con Creado (bool), Motivo, Detalle, Metodo, SequenceNumber y PuntoReciente. Motivos:
        Creado, BloqueadaPorDirectiva, Desactivada, SinEspacioAsignado,
        YaExisteReciente (Windows omitió el punto porque hay uno de las últimas 24 h; PuntoReciente trae
        su número, descripción y fecha para que la consola/interfaz ofrezca continuar con él o cancelar),
        NoSeCreo (omitido sin causa conocida) y ErrorDeSistema.
    .EXAMPLE
        $r = New-PuntoRestauracion -Descripcion 'OptiLow - prueba'
        if (-not $r.Creado) { "$($r.Motivo): $($r.Detalle)" }
    #>
    param(
        [string]$Descripcion = 'OptiLow - antes de aplicar cambios'
    )

    Assert-JournalListo

    $estado = Get-EstadoProteccionSistema
    if (@('BloqueadaPorDirectiva', 'Desactivada', 'SinEspacioAsignado') -contains $estado.Motivo) {
        Write-Log -Nivel WARN -Mensaje "Punto de restauración no creado: $($estado.Detalle)"
        return New-ResultadoPunto -Creado $false -Motivo $estado.Motivo -Detalle $estado.Detalle
    }
    if ($Descripcion.Length -gt 200) { $Descripcion = $Descripcion.Substring(0, 200) }

    $metodo = 'CIM'
    if (($PSVersionTable.PSEdition -ne 'Core') -and (Get-Command -Name 'Checkpoint-Computer' -ErrorAction SilentlyContinue)) {
        $metodo = 'Checkpoint-Computer'
    }

    $rutaFrecuencia = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $nombreFrecuencia = 'SystemRestorePointCreationFrequency'
    $ajuste = $null
    try {
        $antes = @(Get-PuntosRestauracion)
        $maxAntes = -1
        if ($antes.Count -gt 0) { $maxAntes = $antes[0].Secuencia }

        $ajuste = Set-RegistroValorInterno -Ruta $rutaFrecuencia -Nombre $nombreFrecuencia -Valor 0 -Tipo DWord
        if ($ajuste.Estado -eq 'Fallido') {
            Write-Log -Nivel WARN -Mensaje 'No se pudo ajustar la frecuencia de puntos de restauración; si ya hay un punto de las últimas 24 h, Windows omitirá este.'
        }

        Write-Log -Mensaje "Creando punto de restauración: '$Descripcion' (método: $metodo)..."
        if ($metodo -eq 'Checkpoint-Computer') {
            Checkpoint-Computer -Description $Descripcion -RestorePointType MODIFY_SETTINGS -WarningAction SilentlyContinue -WarningVariable avisosCheckpoint -ErrorAction Stop
            foreach ($aviso in @($avisosCheckpoint)) {
                Write-Log -Nivel WARN -Mensaje "Checkpoint-Computer avisó: $aviso"
            }
        }
        else {
            $r = Invoke-CimMethod -Namespace 'root/default' -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{
                Description      = $Descripcion
                RestorePointType = [uint32]12
                EventType        = [uint32]100
            } -ErrorAction Stop
            # No se asume S_OK: se registra siempre el valor devuelto
            Write-Log -Mensaje "CreateRestorePoint devolvió ReturnValue=$($r.ReturnValue)."
            if ([int64]$r.ReturnValue -ne 0) {
                $detalle = "CreateRestorePoint devolvió el código $($r.ReturnValue)."
                Write-Log -Nivel WARN -Mensaje "Punto de restauración no creado: $detalle"
                return New-ResultadoPunto -Creado $false -Motivo 'ErrorDeSistema' -Detalle $detalle -Metodo $metodo
            }
        }

        # Comprobar con los SequenceNumber (unos segundos de margen: la lista puede tardar en reflejarlo)
        $nuevos = @()
        for ($i = 0; $i -lt 3; $i++) {
            $despues = @(Get-PuntosRestauracion)
            $nuevos = @($despues | Where-Object { $_.Secuencia -gt $maxAntes })
            if ($nuevos.Count -gt 0) { break }
            Start-Sleep -Seconds 1
        }
        if ($nuevos.Count -gt 0) {
            $numero = $nuevos[0].Secuencia
            Write-Log -Nivel OK -Mensaje "Punto de restauración creado (número $numero, método $metodo)."
            return New-ResultadoPunto -Creado $true -Motivo 'Creado' -Detalle "Punto número $numero." -Metodo $metodo -Secuencia $numero
        }

        # Windows lo omitió: ¿hay uno reciente (últimas 24 h)?
        $reciente = $antes | Where-Object { $_.Fecha -and (((Get-Date) - $_.Fecha).TotalHours -lt 24) } | Select-Object -First 1
        if ($reciente) {
            $detalle = "Ya existe un punto de restauración de las últimas 24 h: '{0}' creado el {1:yyyy-MM-dd HH:mm:ss} (número {2}). Windows no creó otro." -f $reciente.Descripcion, $reciente.Fecha, $reciente.Secuencia
            Write-Log -Nivel WARN -Mensaje "Punto de restauración no creado: $detalle"
            return New-ResultadoPunto -Creado $false -Motivo 'YaExisteReciente' -Detalle $detalle -Metodo $metodo -PuntoReciente $reciente
        }
        $detalle = 'Windows no creó el punto y no se encontró ninguno reciente que lo explique.'
        Write-Log -Nivel WARN -Mensaje "Punto de restauración no creado: $detalle"
        return New-ResultadoPunto -Creado $false -Motivo 'NoSeCreo' -Detalle $detalle -Metodo $metodo
    }
    catch {
        $detalle = $_.Exception.Message
        Write-Log -Nivel ERROR -Mensaje "Punto de restauración no creado ($metodo): $detalle"
        return New-ResultadoPunto -Creado $false -Motivo 'ErrorDeSistema' -Detalle $detalle -Metodo $metodo
    }
    finally {
        # Revertir SIEMPRE el ajuste temporal de la frecuencia
        if ($ajuste -and $ajuste.Entrada) {
            try {
                Restore-RegistroEntrada -Entrada $ajuste.Entrada
                $ajuste.Entrada['Restaurada'] = $true
                Save-Journal
            }
            catch {
                Write-Log -Nivel ERROR -Mensaje "No se pudo revertir $nombreFrecuencia (queda en 0): $($_.Exception.Message). 'Deshacer última sesión' lo intentará de nuevo."
            }
        }
    }
}

function Enable-ProteccionSistema {
    <#
    .SYNOPSIS
        Activa la Protección del sistema en una unidad. Úsala SOLO tras preguntar al usuario:
        la protección usa espacio en disco.
    .DESCRIPTION
        Deja una nota en el journal (no es reversible desde él). SystemRestore.Enable devuelve sin
        esperar, así que se vuelve a comprobar el estado unos segundos. Puede que haga falta asignar
        espacio manualmente (Propiedades del sistema > Protección del sistema > Configurar).
    .OUTPUTS
        Objeto con Activada (bool), Motivo y Detalle.
    .EXAMPLE
        Enable-ProteccionSistema
    #>
    param(
        [string]$Unidad = ($env:SystemDrive + '\')
    )

    Assert-JournalListo
    [void](Add-JournalEntrada -Entrada ([ordered]@{
                Tipo        = 'Nota'
                Descripcion = "Protección del sistema activada en $Unidad (no reversible desde el journal)."
            }))

    try {
        $r = Invoke-CimMethod -Namespace 'root/default' -ClassName SystemRestore -MethodName Enable -Arguments @{ Drive = $Unidad } -ErrorAction Stop
        if ([int64]$r.ReturnValue -ne 0) {
            $detalle = "SystemRestore.Enable devolvió el código $($r.ReturnValue)."
            Write-Log -Nivel ERROR -Mensaje "No se pudo activar la Protección del sistema: $detalle"
            return [pscustomobject]@{ Activada = $false; Motivo = 'ErrorDeSistema'; Detalle = $detalle }
        }
    }
    catch {
        Write-Log -Nivel ERROR -Mensaje "No se pudo activar la Protección del sistema: $($_.Exception.Message)"
        return [pscustomobject]@{ Activada = $false; Motivo = 'ErrorDeSistema'; Detalle = $_.Exception.Message }
    }

    $estado = $null
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 1
        $estado = Get-EstadoProteccionSistema
        if ($estado.Motivo -eq 'Activa') { break }
    }
    if ($estado.Motivo -eq 'Activa') {
        Write-Log -Nivel OK -Mensaje "Protección del sistema activada en $Unidad."
        return [pscustomobject]@{ Activada = $true; Motivo = 'Activa'; Detalle = $estado.Detalle }
    }
    Write-Log -Nivel WARN -Mensaje "Se pidió activar la Protección del sistema pero sigue sin estar activa: $($estado.Detalle)"
    return [pscustomobject]@{ Activada = $false; Motivo = $estado.Motivo; Detalle = $estado.Detalle }
}
