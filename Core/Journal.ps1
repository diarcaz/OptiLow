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
    # Bloqueo estricto: con un perfil de hardware simulado (-PerfilSimulado) no se puede aplicar ni deshacer nada.
    if ($e -and $e.ContainsKey('SimulacionActiva') -and $e.SimulacionActiva) {
        throw 'Hay un perfil de hardware SIMULADO activo (-PerfilSimulado): solo sirve para ver el diagnóstico. No se puede aplicar ni deshacer nada.'
    }
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
                    # Cambios reales (los de optimizaciones, sin notas) y cuántos ya se deshicieron uno a uno
                    Cambios          = @(@($datos.Entradas) | Where-Object { $_.TweakId -and ($_.Tipo -ne 'Nota') }).Count
                    CambiosDeshechos = @(@($datos.Entradas) | Where-Object { $_.TweakId -and ($_.Tipo -ne 'Nota') -and ($_.Restaurada -eq $true) }).Count
                    Detalle          = @(Get-JournalResumenTweaks -Entradas @($datos.Entradas))
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
        Write-Log -Mensaje "Deshaciendo la sesión $($datos.Id): $($entradas.Count) entradas, de las cuales $yaRevertidas ya estaban revertidas (por ejemplo, deshechas una a una desde su fila o el ajuste temporal de la frecuencia de puntos de restauración, que se revierte en el momento) y se omiten."
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
            Restore-JournalEntrada -Entrada $entrada
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

function Get-JournalResumenTweaks {
    # Auxiliar interna: por cada optimización de una lista de entradas, cuántos cambios hizo y cuántos ya se deshicieron.
    param(
        [object[]]$Entradas
    )
    $res = New-Object System.Collections.ArrayList
    $ids = @(@($Entradas) | ForEach-Object { $_.TweakId } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($id in $ids) {
        $propias = @(@($Entradas) | Where-Object { ($_.TweakId -eq $id) -and ($_.Tipo -ne 'Nota') })
        [void]$res.Add([pscustomobject]@{
                TweakId   = $id
                Cambios   = $propias.Count
                Deshechos = @($propias | Where-Object { $_.Restaurada -eq $true }).Count
            })
    }
    return @($res)
}

function Restore-JournalEntrada {
    # Auxiliar interna: restaura UNA entrada según su tipo. Lanza una excepción si falla. No escribe en el journal.
    param(
        [Parameter(Mandatory)]$Entrada
    )
    switch ($Entrada.Tipo) {
        'Registro'    { Restore-RegistroEntrada -Entrada $Entrada }
        'Servicio'    { Restore-ServicioEntrada -Entrada $Entrada }
        'Tarea'       { Restore-TareaEntrada -Entrada $Entrada }
        'Archivo'     { Restore-ArchivoEntrada -Entrada $Entrada }
        'Json'        { Restore-JsonEntrada -Entrada $Entrada }
        'PlanEnergia' { Restore-PlanEnergiaEntrada -Entrada $Entrada }
        'Nota'        { Write-Log -Mensaje "Nota (no reversible): $($Entrada.Descripcion)" }
        default       { throw "Tipo de entrada desconocido: '$($Entrada.Tipo)'." }
    }
}

# ---------------------------------------------------------------------------------------------
# Deshacer UNA optimización (TweakId) con detección de conflictos
# ---------------------------------------------------------------------------------------------

function Get-JournalEntradaObjetivo {
    # Auxiliar interna: qué elemento del sistema toca una entrada (para saber si dos entradas chocan).
    # Devuelve Clave (texto en minúsculas) y Archivo (ruta en minúsculas si toca un archivo), o $null si no toca nada.
    param(
        [Parameter(Mandatory)]$Entrada
    )
    switch ($Entrada.Tipo) {
        'Registro'    { return [pscustomobject]@{ Clave = ('reg|' + ([string]$Entrada.Ruta).TrimEnd('\').ToLowerInvariant() + '|' + ([string]$Entrada.Nombre).ToLowerInvariant()); Archivo = $null } }
        'Servicio'    { return [pscustomobject]@{ Clave = ('svc|' + ([string]$Entrada.Nombre).ToLowerInvariant()); Archivo = $null } }
        'Tarea'       { return [pscustomobject]@{ Clave = ('tarea|' + ([string]$Entrada.Ruta).TrimEnd('\').ToLowerInvariant() + '\' + ([string]$Entrada.Nombre).ToLowerInvariant()); Archivo = $null } }
        'PlanEnergia' { return [pscustomobject]@{ Clave = 'energia|planactivo'; Archivo = $null } }
        'Archivo'     { return [pscustomobject]@{ Clave = ('archivo|' + ([string]$Entrada.Ruta).ToLowerInvariant()); Archivo = ([string]$Entrada.Ruta).ToLowerInvariant() } }
        'Json'        { return [pscustomobject]@{ Clave = ('json|' + ([string]$Entrada.Ruta).ToLowerInvariant() + '|' + ((@($Entrada.Clave) | ForEach-Object { ([string]$_).ToLowerInvariant() }) -join '/')); Archivo = ([string]$Entrada.Ruta).ToLowerInvariant() } }
        default       { return $null }
    }
}

function Test-JournalObjetivosChocan {
    # Auxiliar interna: dos entradas chocan si tocan lo mismo; un archivo entero choca con cualquier clave JSON de ese archivo.
    param(
        [Parameter(Mandatory)]$A,
        [Parameter(Mandatory)]$B
    )
    if ($A.Clave -ceq $B.Clave) { return $true }
    if ($A.Archivo -and $B.Archivo -and ($A.Archivo -ceq $B.Archivo)) {
        # Un archivo entero choca con cualquier clave JSON de él; dos claves JSON distintas no chocan
        if ($A.Clave.StartsWith('archivo|') -or $B.Clave.StartsWith('archivo|')) { return $true }
    }
    return $false
}

function Get-JournalNombreTweak {
    # Auxiliar interna: nombre legible de una optimización (o su Id si ya no está registrada).
    param(
        [AllowNull()][AllowEmptyString()][string]$TweakId
    )
    if (-not $TweakId) { return 'un cambio sin optimización asociada' }
    if ($TweakId -eq 'programas-inicio') { return 'Programas de inicio' }
    $def = $null
    if (Get-Command Get-Tweak -ErrorAction SilentlyContinue) { $def = Get-Tweak -Id $TweakId | Select-Object -First 1 }
    if ($def) { return [string]$def.Nombre }
    return $TweakId
}

function Read-JournalSesionArchivo {
    # Auxiliar interna: lee un archivo de sesión tras verificar sus permisos.
    param(
        [Parameter(Mandatory)][string]$Ruta
    )
    $verif = Test-AclRespaldos -Ruta $Ruta -Archivo
    if (-not $verif.Valido) {
        throw "El journal '$Ruta' no tiene los permisos esperados y no es de fiar: $($verif.Motivos -join ' ') No se restaurará nada."
    }
    return ([System.IO.File]::ReadAllText($Ruta, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Test-EntradaPendienteDeshacer {
    # Auxiliar interna: una entrada con cambio real que aún no se revirtió.
    param(
        [Parameter(Mandatory)]$Entrada
    )
    return (($Entrada.Restaurada -ne $true) -and ($Entrada.Tipo -ne 'Nota'))
}

function Get-JournalTweaksDeshacibles {
    <#
    .SYNOPSIS
        Optimizaciones que tienen cambios del journal pendientes de deshacer.
    .OUTPUTS
        Tabla hash: TweakId -> objeto con Sesiones (Ids) y Cambios pendientes.
    #>
    $tabla = @{}
    foreach ($s in @(Get-JournalSesiones)) {
        if ($s.Estado -eq 'Restaurado') { continue }
        try { $datos = Read-JournalSesionArchivo -Ruta $s.Ruta } catch { continue }
        foreach ($en in @($datos.Entradas)) {
            if ((-not $en.TweakId) -or (-not (Test-EntradaPendienteDeshacer -Entrada $en))) { continue }
            if (-not $tabla.ContainsKey($en.TweakId)) {
                $tabla[$en.TweakId] = [pscustomobject]@{ Sesiones = (New-Object System.Collections.ArrayList); Cambios = 0 }
            }
            if ($tabla[$en.TweakId].Sesiones -notcontains $datos.Id) { [void]$tabla[$en.TweakId].Sesiones.Add($datos.Id) }
            $tabla[$en.TweakId].Cambios++
        }
    }
    return $tabla
}

function Test-JournalEntradaConservaNuevo {
    # Auxiliar interna: ¿el sistema sigue como lo dejamos nosotros? $true / $false / $null (no se puede saber).
    param(
        [Parameter(Mandatory)]$Entrada
    )
    if ($Entrada.Estado -eq 'Fallida') { return $null }
    try {
        switch ($Entrada.Tipo) {
            'Registro' {
                $act = Get-RegistroEstado -Ruta $Entrada.Ruta -Nombre ([string]$Entrada.Nombre)
                if ($Entrada.Accion -eq 'Eliminar') { return (-not $act.ValorExiste) }
                if ((-not $act.ValorExiste) -or ($act.Tipo -ne $Entrada.TipoNuevo)) { return $false }
                $nuevo = ConvertFrom-RegistroDatoJson -Tipo $Entrada.TipoNuevo -Dato $Entrada.DatoNuevo
                return [bool](Test-RegistroDatoIgual -Tipo $Entrada.TipoNuevo -A $act.Dato -B $nuevo)
            }
            'Servicio' {
                $act = Get-ServicioEstado -Nombre ([string]$Entrada.Nombre)
                return [bool]($act.Existe -and ($act.Inicio -eq $Entrada.InicioNuevo))
            }
            'Tarea' {
                $act = Get-TareaEstado -Ruta ([string]$Entrada.Ruta) -Nombre ([string]$Entrada.Nombre)
                return [bool]($act.Existe -and (-not $act.Habilitada))
            }
            'PlanEnergia' {
                return ((Get-PlanEnergiaActivo).Guid -eq $Entrada.GuidNuevo)
            }
            'Archivo' {
                if (-not $Entrada.HashNuevo) { return $null }
                if (-not (Test-Path -LiteralPath $Entrada.Ruta -PathType Leaf)) { return $false }
                return ((Get-FileHash -LiteralPath $Entrada.Ruta -Algorithm SHA256).Hash -eq $Entrada.HashNuevo)
            }
            'Json' {
                $act = Get-JsonValor -Ruta ([string]$Entrada.Ruta) -Clave ([string[]]@($Entrada.Clave))
                if ((-not $act.ArchivoExiste) -or (-not $act.ClaveExiste)) { return $false }
                $a = ConvertTo-Json -InputObject $act.Valor -Depth 100 -Compress
                $b = ConvertTo-Json -InputObject $Entrada.ValorNuevo -Depth 100 -Compress
                return ($a -ceq $b)
            }
            default { return $null }
        }
    }
    catch {
        Write-Log -Nivel DEBUG -Mensaje "No se pudo comprobar si '$($Entrada.Descripcion)' sigue como lo dejamos: $($_.Exception.Message)"
        return $null
    }
}

function Get-JournalTweakAnalisis {
    <#
    .SYNOPSIS
        Qué pasaría al deshacer una optimización: cambios que revertir, conflictos con cambios posteriores y
        valores que ya no son los que dejamos. Solo lee.
    .OUTPUTS
        Sesiones (Ids, de más reciente a más antigua), Pendientes (cambios a revertir), Conflictos y Divergencias
        (cada uno con un Texto en español).
    #>
    param(
        [Parameter(Mandatory)][string]$TweakId
    )

    $todas = @(Get-JournalSesiones | Where-Object { $_.Estado -ne 'Restaurado' })   # más reciente primero
    $datosPorId = @{}
    foreach ($s in $todas) { $datosPorId[$s.Id] = Read-JournalSesionArchivo -Ruta $s.Ruta }

    $conflictos = New-Object System.Collections.ArrayList
    $divergencias = New-Object System.Collections.ArrayList
    $sesiones = New-Object System.Collections.ArrayList
    $pendientes = 0
    $nombre = Get-JournalNombreTweak -TweakId $TweakId

    foreach ($s in $todas) {
        $datos = $datosPorId[$s.Id]
        $propias = @(@($datos.Entradas) | Where-Object { ($_.TweakId -eq $TweakId) -and (Test-EntradaPendienteDeshacer -Entrada $_) })
        if ($propias.Count -eq 0) { continue }
        [void]$sesiones.Add($datos.Id)
        $pendientes += $propias.Count

        foreach ($mia in $propias) {
            $obj = Get-JournalEntradaObjetivo -Entrada $mia
            if (-not $obj) { continue }
            $conflictosAntes = $conflictos.Count

            # Entradas posteriores (misma sesión con índice mayor, o sesiones más recientes) de OTRA optimización, sin revertir
            foreach ($t in $todas) {
                if ([string]::CompareOrdinal([string]$t.Id, [string]$datos.Id) -lt 0) { continue }   # los Id empiezan por la fecha: orden de texto
                foreach ($otra in @($datosPorId[$t.Id].Entradas)) {
                    if (-not (Test-EntradaPendienteDeshacer -Entrada $otra)) { continue }
                    if ($otra.TweakId -eq $TweakId) { continue }
                    if (($t.Id -eq $datos.Id) -and ([int]$otra.Indice -le [int]$mia.Indice)) { continue }
                    $objOtra = Get-JournalEntradaObjetivo -Entrada $otra
                    if ((-not $objOtra) -or (-not (Test-JournalObjetivosChocan -A $obj -B $objOtra))) { continue }
                    $quien = Get-JournalNombreTweak -TweakId $otra.TweakId
                    [void]$conflictos.Add([pscustomobject]@{
                            TweakId         = $TweakId
                            Entrada         = $mia.Descripcion
                            OtraSesion      = $t.Id
                            OtraInicio      = $datosPorId[$t.Id].Inicio
                            OtroTweakId     = $otra.TweakId
                            OtraDescripcion = $otra.Descripcion
                            Texto           = "«$($mia.Descripcion)» fue modificado después por «$quien» (sesión del $($datosPorId[$t.Id].Inicio)) y ese cambio no está deshecho: restaurar el valor original de «$nombre» borraría ese cambio posterior."
                        })
                }
            }

            # Si ya hay un conflicto con esta entrada, el aviso de "valor distinto" sería repetir lo mismo
            $conserva = $null
            if ($conflictos.Count -eq $conflictosAntes) { $conserva = Test-JournalEntradaConservaNuevo -Entrada $mia }
            if ($conserva -eq $false) {
                [void]$divergencias.Add([pscustomobject]@{
                        TweakId = $TweakId
                        Entrada = $mia.Descripcion
                        Texto   = "«$($mia.Descripcion)» se cambió fuera de OptiLow (por ti, por Windows o por otro programa) y ya no tiene el valor que dejó «$nombre»: restaurar el original lo sobrescribiría."
                    })
            }
        }
    }
    return [pscustomobject]@{
        TweakId      = $TweakId
        Sesiones     = @($sesiones)
        Pendientes   = $pendientes
        Conflictos   = @($conflictos)
        Divergencias = @($divergencias)
    }
}

function Undo-JournalTweak {
    <#
    .SYNOPSIS
        Deshace los cambios de UNA optimización (su TweakId) en el journal, sin tocar las demás.
    .DESCRIPTION
        Antes de deshacer comprueba (1) si una sesión posterior sin deshacer, u otra optimización posterior de
        la misma sesión, modificó lo mismo, y (2) si el valor actual ya no es el que dejamos nosotros. Si hay
        algo de eso NO deshace y devuelve Estado = 'RequiereConfirmacion' con la lista; para continuar hay que
        repetir la llamada con -Forzar tras la confirmación explícita del usuario. Revierte en orden inverso,
        de la sesión más reciente a la más antigua. Cada entrada revertida se marca Restaurada; la sesión pasa a
        Restaurado solo cuando ya no queda ningún cambio por revertir. No se registra a sí misma en el journal.
    .PARAMETER TweakId
        Id de la optimización.
    .PARAMETER Forzar
        Continúa aunque haya conflictos o valores cambiados (tras la confirmación del usuario).
    .OUTPUTS
        Estado (Restaurado, RestauradoParcial, RequiereConfirmacion, NadaQueDeshacer), Restauradas, Fallidas,
        Conflictos y Divergencias.
    .EXAMPLE
        Undo-JournalTweak -TweakId 'efectos-transparencia-off'
    #>
    param(
        [Parameter(Mandatory)][string]$TweakId,
        [switch]$Forzar
    )

    Assert-JournalListo -Completo
    $e = $global:OptiLow

    $analisis = Get-JournalTweakAnalisis -TweakId $TweakId
    if ($analisis.Pendientes -eq 0) {
        Write-Log -Nivel INFO -Mensaje "Deshacer '$TweakId': no hay cambios pendientes de deshacer en el journal."
        return [pscustomobject]@{ Estado = 'NadaQueDeshacer'; Restauradas = 0; Fallidas = @(); Conflictos = @(); Divergencias = @() }
    }
    $hayAvisos = (@($analisis.Conflictos).Count -gt 0) -or (@($analisis.Divergencias).Count -gt 0)
    if ($hayAvisos -and (-not $Forzar)) {
        foreach ($c in (@($analisis.Conflictos) + @($analisis.Divergencias))) { Write-Log -Nivel WARN -Mensaje "Deshacer '$TweakId': $($c.Texto)" }
        Write-Log -Nivel WARN -Mensaje "Deshacer '$TweakId': NO se deshizo nada; hace falta confirmación explícita."
        return [pscustomobject]@{ Estado = 'RequiereConfirmacion'; Restauradas = 0; Fallidas = @(); Conflictos = @($analisis.Conflictos); Divergencias = @($analisis.Divergencias) }
    }
    if ($hayAvisos) { Write-Log -Nivel WARN -Mensaje "Deshacer '$TweakId': el usuario confirmó continuar a pesar de los avisos." }

    $fallidas = New-Object System.Collections.ArrayList
    $restauradas = 0
    foreach ($idSesion in @($analisis.Sesiones)) {
        $sesion = Get-JournalSesiones | Where-Object { $_.Id -eq $idSesion } | Select-Object -First 1
        if (-not $sesion) { continue }
        $datos = Read-JournalSesionArchivo -Ruta $sesion.Ruta
        $entradas = @($datos.Entradas)
        Write-Log -Mensaje "Deshaciendo '$TweakId' en la sesión $($datos.Id)..."
        for ($i = $entradas.Count - 1; $i -ge 0; $i--) {
            $entrada = $entradas[$i]
            if (($entrada.TweakId -ne $TweakId) -or ($entrada.Restaurada -eq $true)) { continue }
            try {
                Restore-JournalEntrada -Entrada $entrada
                Add-Member -InputObject $entrada -NotePropertyName 'Restaurada' -NotePropertyValue $true -Force
                $restauradas++
            }
            catch {
                Write-Log -Nivel ERROR -Mensaje "No se pudo restaurar la entrada $($entrada.Indice) ($($entrada.Tipo): $($entrada.Descripcion)): $($_.Exception.Message)"
                [void]$fallidas.Add([pscustomobject]@{ Indice = $entrada.Indice; Tipo = $entrada.Tipo; Descripcion = $entrada.Descripcion; Error = $_.Exception.Message })
            }
            Write-JournalJson -Ruta $sesion.Ruta -Objeto $datos
        }
        # La sesión queda Restaurada solo si ya no queda ningún cambio por revertir (las notas no se pueden revertir)
        $quedan = @($entradas | Where-Object { Test-EntradaPendienteDeshacer -Entrada $_ })
        if ($quedan.Count -eq 0) {
            $datos.Estado = 'Restaurado'
            Add-Member -InputObject $datos -NotePropertyName 'FinRestauracion' -NotePropertyValue ((Get-Date).ToString('s')) -Force
            Write-JournalJson -Ruta $sesion.Ruta -Objeto $datos
        }
        # El journal en memoria de esta sesión quedó desfasado: la siguiente escritura empieza una sesión nueva.
        if ($e.Journal -and ($e.Journal.Id -eq $datos.Id)) { $e.Journal = $null }
    }

    if ($fallidas.Count -eq 0) {
        Write-Log -Nivel OK -Mensaje "Optimización '$TweakId' deshecha ($restauradas cambio(s) restaurados)."
        $estado = 'Restaurado'
    }
    else {
        Write-Log -Nivel WARN -Mensaje "Deshacer '$TweakId' PARCIAL: $restauradas restaurados, $($fallidas.Count) fallidos (se puede reintentar)."
        $estado = 'RestauradoParcial'
    }
    return [pscustomobject]@{ Estado = $estado; Restauradas = $restauradas; Fallidas = @($fallidas); Conflictos = @(); Divergencias = @() }
}
