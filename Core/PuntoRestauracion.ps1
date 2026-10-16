# Core/PuntoRestauracion.ps1
# Punto de restauración de Windows mediante la clase CIM SystemRestore (root\default), no con
# Checkpoint-Computer (que no existe en PowerShell 7).
#
# Datos verificados en Microsoft Learn (CreateRestorePoint, clase SystemRestore):
#   - CreateRestorePoint(String Description, uint32 RestorePointType, uint32 EventType)
#     MODIFY_SETTINGS = 12, BEGIN_SYSTEM_CHANGE = 100.
#   - Por defecto Windows OMITE el punto (y devuelve S_OK) si hubo otro en las últimas 24 h.
#     Se evita con el DWORD SystemRestorePointCreationFrequency = 0 en
#     HKLM\Software\Microsoft\Windows NT\CurrentVersion\SystemRestore. Por eso se comprueba el éxito
#     comparando los SequenceNumber antes y después, no con el valor devuelto.
#   - SystemRestore.Enable(String Drive) activa la protección; devuelve sin esperar.
#
# Core/ NO activa la Protección del sistema por su cuenta: devuelve un motivo claro y la consola o la
# interfaz preguntan al usuario antes de llamar a Enable-ProteccionSistema (usa espacio en disco).
#
# Detección de "protección desactivada / sin espacio" (HEURÍSTICA, por validar en VM): política
# DisableSR=1, o ausencia de Win32_ShadowStorage para la unidad del sistema, o MaxSpace = 0.

function Get-NumerosPuntosRestauracion {
    # Auxiliar interna: SequenceNumber de los puntos existentes.
    $lista = @(Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore -ErrorAction Stop)
    return @($lista | ForEach-Object { [int64]$_.SequenceNumber })
}

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

function New-ResultadoPunto {
    # Auxiliar interna: objeto de resultado de New-PuntoRestauracion.
    param(
        [bool]$Creado,
        [string]$Motivo,
        [string]$Detalle,
        $Secuencia = $null
    )
    return [pscustomobject]@{ Creado = $Creado; Motivo = $Motivo; Detalle = $Detalle; SequenceNumber = $Secuencia }
}

function New-PuntoRestauracion {
    <#
    .SYNOPSIS
        Crea un punto de restauración. No pregunta nada ni activa la protección: devuelve un motivo.
    .DESCRIPTION
        Ajusta temporalmente SystemRestorePointCreationFrequency = 0 (a través del journal, para
        sobrevivir a un cierre brusco) y lo revierte SIEMPRE en un bloque finally.
    .OUTPUTS
        Objeto con Creado (bool), Motivo, Detalle y SequenceNumber. Motivos:
        Creado, BloqueadaPorDirectiva, Desactivada, SinEspacioAsignado, NoSeCreo (Windows lo omitió),
        ErrorDeSistema.
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

    $rutaFrecuencia = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $nombreFrecuencia = 'SystemRestorePointCreationFrequency'
    $ajuste = $null
    try {
        $ajuste = Set-RegistroValorInterno -Ruta $rutaFrecuencia -Nombre $nombreFrecuencia -Valor 0 -Tipo DWord
        if ($ajuste.Estado -eq 'Fallido') {
            Write-Log -Nivel WARN -Mensaje 'No se pudo ajustar la frecuencia de puntos de restauración; si ya hay un punto de las últimas 24 h, Windows omitirá este.'
        }

        $antes = @(Get-NumerosPuntosRestauracion)
        $maxAntes = -1
        if ($antes.Count -gt 0) { $maxAntes = ($antes | Measure-Object -Maximum).Maximum }

        Write-Log -Mensaje "Creando punto de restauración: '$Descripcion'..."
        $r = Invoke-CimMethod -Namespace 'root/default' -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{
            Description      = $Descripcion
            RestorePointType = [uint32]12
            EventType        = [uint32]100
        } -ErrorAction Stop

        if ([int64]$r.ReturnValue -ne 0) {
            $detalle = "CreateRestorePoint devolvió el código $($r.ReturnValue)."
            Write-Log -Nivel WARN -Mensaje "Punto de restauración no creado: $detalle"
            return New-ResultadoPunto -Creado $false -Motivo 'ErrorDeSistema' -Detalle $detalle
        }

        $despues = @(Get-NumerosPuntosRestauracion)
        $nuevos = @($despues | Where-Object { $_ -gt $maxAntes })
        if ($nuevos.Count -gt 0) {
            $numero = ($nuevos | Measure-Object -Maximum).Maximum
            Write-Log -Nivel OK -Mensaje "Punto de restauración creado (número $numero)."
            return New-ResultadoPunto -Creado $true -Motivo 'Creado' -Detalle "Punto número $numero." -Secuencia $numero
        }
        $detalle = 'Windows no creó el punto (lo omitió sin error; puede ser el límite de frecuencia u otra causa).'
        Write-Log -Nivel WARN -Mensaje "Punto de restauración no creado: $detalle"
        return New-ResultadoPunto -Creado $false -Motivo 'NoSeCreo' -Detalle $detalle
    }
    catch {
        $detalle = $_.Exception.Message
        Write-Log -Nivel ERROR -Mensaje "Punto de restauración no creado: $detalle"
        return New-ResultadoPunto -Creado $false -Motivo 'ErrorDeSistema' -Detalle $detalle
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
