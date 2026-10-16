# Core/Journal.ps1
# Journal de respaldo: antes de cada cambio se guarda el estado original en un JSON
# (un archivo por sesión) en la carpeta protegida de respaldos, para poder deshacerlo.
#
# Las funciones de escritura de Core/ (registro, servicios, tareas, archivos, energía) llaman a
# Assert-JournalListo: sin journal no se aplica ningún cambio.

function Assert-JournalListo {
    <#
    .SYNOPSIS
        Lanza un error con una explicación clara si no se puede garantizar el journal.
    .PARAMETER Completo
        Además verifica los permisos de la carpeta de respaldos (se hace al iniciar la sesión
        del journal y antes de deshacer).
    .EXAMPLE
        Assert-JournalListo -Completo
    #>
    param(
        [switch]$Completo
    )

    $e = $global:OptiLow
    if (-not (Test-EsAdministrador)) {
        throw 'Se necesitan permisos de administrador para aplicar o deshacer cambios (el journal de respaldo es obligatorio). No se aplicará nada.'
    }
    if ((-not $e) -or (-not $e.DirRespaldos)) {
        throw 'No hay una carpeta de respaldos segura (journal), y sin ella no se podrían deshacer los cambios. No se aplicará nada. Ejecuta Initialize-CarpetaRespaldos como administrador.'
    }
    if ($Completo) {
        $verif = Test-AclRespaldos -Ruta $e.DirRespaldos
        if (-not $verif.Valido) {
            throw "La carpeta de respaldos '$($e.DirRespaldos)' no tiene los permisos esperados (solo Administradores y SYSTEM): $($verif.Motivos -join ' ') No se aplicará ni se restaurará nada."
        }
    }
}

function Write-JournalJson {
    # Auxiliar interna: escribe un objeto como JSON (UTF-8 sin BOM) de forma atómica (temporal + reemplazo).
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [Parameter(Mandatory)]$Objeto
    )

    $json = ConvertTo-Json -InputObject $Objeto -Depth 100
    $temporal = $Ruta + '.tmp'
    [System.IO.File]::WriteAllText($temporal, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Ruta) {
        # [NullString]::Value: con $null PowerShell pasaría una cadena vacía y Replace lo rechazaría
        [System.IO.File]::Replace($temporal, $Ruta, [NullString]::Value)
    }
    else {
        [System.IO.File]::Move($temporal, $Ruta)
    }
}

function Start-JournalSesion {
    <#
    .SYNOPSIS
        Inicia la sesión del journal (si no hay una activa). El archivo se crea al guardar la primera entrada.
    .PARAMETER Nueva
        Cierra la sesión activa y empieza otra.
    .OUTPUTS
        El Id de la sesión.
    .EXAMPLE
        Start-JournalSesion
    #>
    param(
        [switch]$Nueva
    )

    Assert-JournalListo -Completo
    $e = $global:OptiLow
    if ($e.Journal -and (-not $Nueva)) { return $e.Journal.Id }

    $id = '{0:yyyyMMdd-HHmmssfff}-{1}' -f (Get-Date), $PID
    $e.Journal = @{
        Id    = $id
        Ruta  = Join-Path $e.DirRespaldos ($id + '.json')
        Datos = [ordered]@{
            Version  = 1
            Id       = $id
            Inicio   = (Get-Date).ToString('s')
            Equipo   = $env:COMPUTERNAME
            Usuario  = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            Estado   = 'Activo'
            Entradas = New-Object System.Collections.ArrayList
        }
    }
    Write-Log -Nivel DEBUG -Mensaje "Sesión de journal iniciada: $id"
    return $id
}

function Save-Journal {
    # Auxiliar interna: guarda la sesión activa en disco.
    $s = $global:OptiLow.Journal
    if (-not $s) { return }
    Write-JournalJson -Ruta $s.Ruta -Objeto $s.Datos
}

function Add-JournalEntrada {
    <#
    .SYNOPSIS
        Agrega una entrada a la sesión activa (la inicia si hace falta) y guarda el archivo.
    .DESCRIPTION
        Se llama ANTES de hacer el cambio. La entrada queda en estado 'Pendiente'; la función de
        escritura la pasa a 'Aplicada' o 'Fallida' con Set-JournalEntradaEstado.
    .OUTPUTS
        La entrada (referencia: si se modifica, se guarda con Save-Journal).
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Entrada
    )

    [void](Start-JournalSesion)
    $s = $global:OptiLow.Journal
    $registro = [ordered]@{
        Indice = $s.Datos.Entradas.Count + 1
        Hora   = (Get-Date).ToString('s')
        Estado = 'Pendiente'
    }
    # Si la entrada la genera un tweak, se guarda su Id (permite deshacer un solo tweak más adelante)
    $registro['TweakId'] = $global:OptiLow.TweakActual
    foreach ($clave in $Entrada.Keys) { $registro[$clave] = $Entrada[$clave] }

    [void]$s.Datos.Entradas.Add($registro)
    Save-Journal
    return $registro
}

function Get-JournalProximoIndice {
    # Auxiliar interna: índice que tendrá la próxima entrada (sirve para nombrar copias de respaldo).
    [void](Start-JournalSesion)
    return ($global:OptiLow.Journal.Datos.Entradas.Count + 1)
}

function Set-JournalEntradaEstado {
    # Auxiliar interna: cambia el estado de una entrada y guarda.
    param(
        [Parameter(Mandatory)]$Entrada,
        [Parameter(Mandatory)][ValidateSet('Pendiente', 'Aplicada', 'Fallida')][string]$Estado,
        [string]$Detalle
    )

    $Entrada['Estado'] = $Estado
    if ($Detalle) { $Entrada['Detalle'] = $Detalle }
    Save-Journal
}

function Remove-JournalEntrada {
    <#
    .SYNOPSIS
        Quita del journal la última entrada cuando el cambio falló SIN modificar nada del sistema.
    .DESCRIPTION
        Un cambio que falla sin haber tocado nada no debe quedar en el journal (el deshacer intentaría
        "restaurarlo"). Solo se puede quitar la última entrada de la sesión activa. Si el cambio pudo
        quedar a medias, NO se usa: la entrada se marca Fallida y el deshacer la revierte.
        Si la sesión se queda sin entradas, se borra su archivo.
    #>
    param(
        [Parameter(Mandatory)]$Entrada
    )

    $s = $global:OptiLow.Journal
    if ((-not $s) -or ($s.Datos.Entradas.Count -eq 0)) { return }
    $ultima = $s.Datos.Entradas[$s.Datos.Entradas.Count - 1]
    if (-not [object]::ReferenceEquals($ultima, $Entrada)) {
        # No es la última (no debería pasar): se conserva como Fallida
        Set-JournalEntradaEstado -Entrada $Entrada -Estado Fallida
        return
    }
    $s.Datos.Entradas.RemoveAt($s.Datos.Entradas.Count - 1)
    if ($s.Datos.Entradas.Count -eq 0) {
        if (Test-Path -LiteralPath $s.Ruta) { Remove-Item -LiteralPath $s.Ruta -Force }
    }
    else {
        Save-Journal
    }
}

function Get-JournalSesiones {
    <#
    .SYNOPSIS
        Lista las sesiones guardadas (más recientes primero) con su estado y número de entradas.
    .EXAMPLE
        Get-JournalSesiones | Format-Table Id, Estado, Entradas
    #>
    $e = $global:OptiLow
    if ((-not $e) -or (-not $e.DirRespaldos)) { return @() }

    $lista = New-Object System.Collections.ArrayList
    $archivos = Get-ChildItem -LiteralPath $e.DirRespaldos -Filter '*.json' -File | Sort-Object Name -Descending
    foreach ($archivo in $archivos) {
        try {
            $datos = [System.IO.File]::ReadAllText($archivo.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            [void]$lista.Add([pscustomobject]@{
                    Id       = $datos.Id
                    Inicio   = $datos.Inicio
                    Estado   = $datos.Estado
                    Entradas = @($datos.Entradas).Count
                    Tweaks   = @(@($datos.Entradas) | ForEach-Object { $_.TweakId } | Where-Object { $_ } | Select-Object -Unique)
                    Ruta     = $archivo.FullName
                })
        }
        catch {
            Write-Log -Nivel WARN -Mensaje "No se pudo leer el journal '$($archivo.Name)': $($_.Exception.Message)"
        }
    }
    return @($lista)
}

function Undo-JournalSesion {
    <#
    .SYNOPSIS
        Deshace una sesión del journal recorriendo sus entradas en orden inverso.
    .DESCRIPTION
        Sin parámetros deshace la última sesión que no esté ya restaurada. Si alguna entrada falla,
        sigue con las demás y deja el archivo como 'RestauradoParcial' con la lista de fallidas
        (volver a ejecutarlo reintenta solo las pendientes). La restauración no se registra a sí
        misma en un journal nuevo. Antes de leer el archivo verifica los permisos de la carpeta.
    .PARAMETER Id
        Id de la sesión (ver Get-JournalSesiones).
    .OUTPUTS
        Objeto con Estado, Restauradas y Fallidas.
    .EXAMPLE
        Undo-JournalSesion
    .EXAMPLE
        Undo-JournalSesion -Id '20261016-023000123-4567'
    #>
    param(
        [string]$Id
    )

    Assert-JournalListo -Completo
    $e = $global:OptiLow

    if ($Id) {
        $sesion = Get-JournalSesiones | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    }
    else {
        $sesion = Get-JournalSesiones | Where-Object { ($_.Estado -ne 'Restaurado') -and ($_.Entradas -gt 0) } | Select-Object -First 1
    }
    if (-not $sesion) {
        Write-Log -Nivel INFO -Mensaje 'No hay ninguna sesión del journal para deshacer.'
        return $null
    }

    $verifArchivo = Test-AclRespaldos -Ruta $sesion.Ruta -Archivo
    if (-not $verifArchivo.Valido) {
        throw "El journal '$($sesion.Ruta)' no tiene los permisos esperados y no es de fiar: $($verifArchivo.Motivos -join ' ') No se restaurará nada."
    }

    $datos = [System.IO.File]::ReadAllText($sesion.Ruta, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($datos.Estado -eq 'Restaurado') {
        Write-Log -Nivel INFO -Mensaje "La sesión $($datos.Id) ya estaba restaurada."
        return [pscustomobject]@{ Estado = 'Restaurado'; Restauradas = 0; Fallidas = @() }
    }

    $entradas = @($datos.Entradas)
    $yaRevertidas = @($entradas | Where-Object { $_.Restaurada -eq $true }).Count
    if ($yaRevertidas -gt 0) {
        Write-Log -Mensaje "Deshaciendo la sesión $($datos.Id): $($entradas.Count) entradas, de las cuales $yaRevertidas ya estaban revertidas (por ejemplo, el ajuste temporal de la frecuencia de puntos de restauración, que se revierte en el momento) y se omiten."
    }
    else {
        Write-Log -Mensaje "Deshaciendo la sesión $($datos.Id) ($($entradas.Count) entradas)..."
    }
    $fallidas = New-Object System.Collections.ArrayList
    $restauradas = 0

    for ($i = $entradas.Count - 1; $i -ge 0; $i--) {
        $entrada = $entradas[$i]
        if ($entrada.Restaurada -eq $true) {
            Write-Log -Nivel DEBUG -Mensaje "Entrada $($entrada.Indice) ($($entrada.Descripcion)): ya revertida; se omite."
            continue
        }
        try {
            switch ($entrada.Tipo) {
                'Registro'    { Restore-RegistroEntrada -Entrada $entrada }
                'Servicio'    { Restore-ServicioEntrada -Entrada $entrada }
                'Tarea'       { Restore-TareaEntrada -Entrada $entrada }
                'Archivo'     { Restore-ArchivoEntrada -Entrada $entrada }
                'Json'        { Restore-JsonEntrada -Entrada $entrada }
                'PlanEnergia' { Restore-PlanEnergiaEntrada -Entrada $entrada }
                'Nota'        { Write-Log -Mensaje "Nota (no reversible): $($entrada.Descripcion)" }
                default       { throw "Tipo de entrada desconocido: '$($entrada.Tipo)'." }
            }
            Add-Member -InputObject $entrada -NotePropertyName 'Restaurada' -NotePropertyValue $true -Force
            $restauradas++
        }
        catch {
            Write-Log -Nivel ERROR -Mensaje "No se pudo restaurar la entrada $($entrada.Indice) ($($entrada.Tipo): $($entrada.Descripcion)): $($_.Exception.Message)"
            [void]$fallidas.Add([pscustomobject]@{
                    Indice      = $entrada.Indice
                    Tipo        = $entrada.Tipo
                    Descripcion = $entrada.Descripcion
                    Error       = $_.Exception.Message
                })
        }
        $datos.Estado = 'Restaurando'
        Write-JournalJson -Ruta $sesion.Ruta -Objeto $datos
    }

    if ($fallidas.Count -eq 0) {
        $datos.Estado = 'Restaurado'
        Add-Member -InputObject $datos -NotePropertyName 'Fallidas' -NotePropertyValue @() -Force
    }
    else {
        $datos.Estado = 'RestauradoParcial'
        Add-Member -InputObject $datos -NotePropertyName 'Fallidas' -NotePropertyValue @($fallidas) -Force
    }
    Add-Member -InputObject $datos -NotePropertyName 'FinRestauracion' -NotePropertyValue ((Get-Date).ToString('s')) -Force
    Write-JournalJson -Ruta $sesion.Ruta -Objeto $datos

    # Si se deshizo la sesión activa de este proceso, la siguiente escritura empieza una nueva.
    if ($e.Journal -and ($e.Journal.Id -eq $datos.Id)) { $e.Journal = $null }

    if ($fallidas.Count -eq 0) {
        if ($yaRevertidas -gt 0) {
            Write-Log -Nivel OK -Mensaje "Sesión $($datos.Id) restaurada por completo: $restauradas entradas restauradas ahora y $yaRevertidas que ya estaban revertidas."
        }
        else {
            Write-Log -Nivel OK -Mensaje "Sesión $($datos.Id) restaurada por completo ($restauradas entradas)."
        }
    }
    else {
        Write-Log -Nivel WARN -Mensaje "Restauración PARCIAL de la sesión $($datos.Id): $restauradas restauradas, $($fallidas.Count) fallidas."
    }
    return [pscustomobject]@{ Estado = $datos.Estado; Restauradas = $restauradas; Fallidas = @($fallidas) }
}
