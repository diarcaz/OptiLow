# Core/Archivos.ps1
# Escritura de archivos con respaldo automático (journal):
#   - Write-ArchivoTexto: reemplaza el contenido completo de un archivo (copia de respaldo con hash).
#   - Set-JsonValor: cambia UNA sola clave de un JSON y, al deshacer, restaura solo esa clave
#     (no pisa otros cambios que el usuario haya hecho después). La copia completa del archivo queda
#     solo como respaldo de emergencia.
# No borran archivos del usuario. Devuelven: Cambiado, SinCambios, NoAplica o Fallido.

function Get-JournalDirArchivos {
    # Auxiliar interna: carpeta de copias de respaldo de la sesión activa (dentro de la carpeta protegida).
    [void](Start-JournalSesion)
    $dir = Join-Path (Join-Path $global:OptiLow.DirRespaldos $global:OptiLow.Journal.Id) 'archivos'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function New-CopiaRespaldoArchivo {
    # Auxiliar interna: copia el archivo a la carpeta de respaldos de la sesión y calcula su hash SHA256.
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [Parameter(Mandatory)][int]$Indice
    )

    $dir = Get-JournalDirArchivos
    $destino = Join-Path $dir ('{0:D3}_{1}' -f $Indice, (Split-Path -Leaf $Ruta))
    Copy-Item -LiteralPath $Ruta -Destination $destino -Force -ErrorAction Stop
    $hash = (Get-FileHash -LiteralPath $destino -Algorithm SHA256).Hash
    return [pscustomobject]@{ Ruta = $destino; Hash = $hash }
}

function Get-HashBytes {
    # Auxiliar interna: SHA256 (hex) de un arreglo de bytes.
    param(
        [Parameter(Mandatory)][byte[]]$Bytes
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('X2') }) -join '') }
    finally { $sha.Dispose() }
}

function Write-ArchivoTexto {
    <#
    .SYNOPSIS
        Reemplaza el contenido de un archivo de texto, con copia de respaldo y entrada en el journal.
    .DESCRIPTION
        La carpeta del archivo debe existir (no se crean carpetas). Si el archivo no existía, el
        deshacer lo borra solo si sigue con el contenido que escribimos.
    .PARAMETER Codificacion
        UTF8SinBom (por defecto) o UTF8ConBom.
    .OUTPUTS
        'Cambiado', 'SinCambios', 'NoAplica' (la carpeta no existe) o 'Fallido'.
    .EXAMPLE
        Write-ArchivoTexto -Ruta "$env:TEMP\prueba.txt" -Contenido 'hola'
    #>
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Contenido,
        [ValidateSet('UTF8SinBom', 'UTF8ConBom')][string]$Codificacion = 'UTF8SinBom'
    )

    Assert-JournalListo

    $dirPadre = Split-Path -Parent $Ruta
    if (-not (Test-Path -LiteralPath $dirPadre -PathType Container)) {
        Write-Log -Nivel INFO -Mensaje "Archivo: la carpeta '$dirPadre' no existe; no se escribe '$Ruta'."
        return 'NoAplica'
    }

    $enc = New-Object System.Text.UTF8Encoding($Codificacion -eq 'UTF8ConBom')
    $bytes = [byte[]]($enc.GetPreamble() + $enc.GetBytes($Contenido))
    $hashNuevo = Get-HashBytes -Bytes $bytes

    $existe = Test-Path -LiteralPath $Ruta -PathType Leaf
    $hashOriginal = $null
    if ($existe) {
        $hashOriginal = (Get-FileHash -LiteralPath $Ruta -Algorithm SHA256).Hash
        if ($hashOriginal -eq $hashNuevo) {
            Write-Log -Nivel DEBUG -Mensaje "Archivo: '$Ruta' ya tiene el contenido deseado."
            return 'SinCambios'
        }
    }

    try {
        $copia = $null
        if ($existe) { $copia = New-CopiaRespaldoArchivo -Ruta $Ruta -Indice (Get-JournalProximoIndice) }

        $entrada = [ordered]@{
            Tipo           = 'Archivo'
            Descripcion    = "Archivo $Ruta"
            Ruta           = $Ruta
            Existia        = $existe
            CopiaRespaldo  = $(if ($copia) { $copia.Ruta } else { $null })
            HashOriginal   = $hashOriginal
            HashNuevo      = $hashNuevo
        }
        $registro = Add-JournalEntrada -Entrada $entrada
    }
    catch {
        Write-Log -Nivel ERROR -Mensaje "Archivo: no se pudo respaldar '$Ruta': $($_.Exception.Message)"
        return 'Fallido'
    }

    try {
        [System.IO.File]::WriteAllBytes($Ruta, $bytes)
        Set-JournalEntradaEstado -Entrada $registro -Estado Aplicada
        if ($existe) {
            Write-Log -Nivel OK -Mensaje "Archivo: '$Ruta' reescrito (copia en '$($copia.Ruta)')."
        }
        else {
            Write-Log -Nivel OK -Mensaje "Archivo: '$Ruta' creado."
        }
        return 'Cambiado'
    }
    catch {
        Set-JournalEntradaEstado -Entrada $registro -Estado Fallida -Detalle $_.Exception.Message
        Write-Log -Nivel ERROR -Mensaje "Archivo: no se pudo escribir '$Ruta': $($_.Exception.Message)"
        return 'Fallido'
    }
}

function Restore-ArchivoEntrada {
    # Restaura una entrada de tipo Archivo. Lanza una excepción si falla. No escribe en el journal.
    param(
        [Parameter(Mandatory)]$Entrada
    )

    $ruta = [string]$Entrada.Ruta
    if ($Entrada.Existia -eq $true) {
        if ((-not $Entrada.CopiaRespaldo) -or (-not (Test-Path -LiteralPath $Entrada.CopiaRespaldo))) {
            throw "Falta la copia de respaldo '$($Entrada.CopiaRespaldo)'."
        }
        $hashCopia = (Get-FileHash -LiteralPath $Entrada.CopiaRespaldo -Algorithm SHA256).Hash
        if ($hashCopia -ne $Entrada.HashOriginal) {
            throw "La copia de respaldo '$($Entrada.CopiaRespaldo)' no coincide con su hash original; no se usa."
        }
        if (Test-Path -LiteralPath $ruta -PathType Leaf) {
            $hashActual = (Get-FileHash -LiteralPath $ruta -Algorithm SHA256).Hash
            if (($hashActual -ne $Entrada.HashNuevo) -and ($hashActual -ne $Entrada.HashOriginal)) {
                Write-Log -Nivel WARN -Mensaje "El archivo '$ruta' cambió después de nuestra modificación; se restaura igualmente el contenido original."
            }
        }
        Copy-Item -LiteralPath $Entrada.CopiaRespaldo -Destination $ruta -Force -ErrorAction Stop
        Write-Log -Nivel OK -Mensaje "Restaurado: $($Entrada.Descripcion)"
    }
    else {
        if (Test-Path -LiteralPath $ruta -PathType Leaf) {
            $hashActual = (Get-FileHash -LiteralPath $ruta -Algorithm SHA256).Hash
            if ($hashActual -eq $Entrada.HashNuevo) {
                Remove-Item -LiteralPath $ruta -Force -ErrorAction Stop
                Write-Log -Nivel OK -Mensaje "Restaurado: '$ruta' eliminado (lo habíamos creado nosotros)."
            }
            else {
                Write-Log -Nivel WARN -Mensaje "No se elimina '$ruta': lo creamos nosotros pero su contenido cambió después (podría tener datos del usuario)."
            }
        }
    }
}

# ---------------------------------------------------------------------------------------------
# JSON: cambiar una sola clave
# ---------------------------------------------------------------------------------------------

function Read-JsonArchivo {
    # Auxiliar interna: lee y analiza un JSON. Lanza una excepción con mensaje claro si no es válido.
    param(
        [Parameter(Mandatory)][string]$Ruta
    )

    $texto = [System.IO.File]::ReadAllText($Ruta, [System.Text.Encoding]::UTF8)
    try {
        $raiz = ConvertFrom-Json -InputObject $texto
    }
    catch {
        throw "El archivo '$Ruta' no es un JSON válido: $($_.Exception.Message)"
    }
    if ($raiz -isnot [pscustomobject]) {
        throw "El archivo '$Ruta' no contiene un objeto JSON en la raíz."
    }
    return $raiz
}

function Write-JsonArchivo {
    # Auxiliar interna: escribe el objeto como JSON, UTF-8 sin BOM.
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [Parameter(Mandatory)]$Raiz
    )

    $json = ConvertTo-Json -InputObject $Raiz -Depth 100
    [System.IO.File]::WriteAllText($Ruta, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Resolve-JsonPadre {
    # Auxiliar interna: devuelve el objeto que contiene la clave final. Con -Crear crea los intermedios
    # que falten; sin él devuelve $null si falta alguno.
    param(
        [Parameter(Mandatory)]$Raiz,
        [Parameter(Mandatory)][string[]]$Clave,
        [switch]$Crear
    )

    $actual = $Raiz
    for ($i = 0; $i -lt ($Clave.Count - 1); $i++) {
        $p = $actual.PSObject.Properties[$Clave[$i]]
        if ($p) {
            if ($p.Value -isnot [pscustomobject]) {
                throw "La clave intermedia '$($Clave[$i])' no es un objeto JSON."
            }
            $actual = $p.Value
        }
        elseif ($Crear) {
            $nuevo = New-Object psobject
            Add-Member -InputObject $actual -NotePropertyName $Clave[$i] -NotePropertyValue $nuevo
            $actual = $nuevo
        }
        else {
            return $null
        }
    }
    return $actual
}

function Get-JsonValor {
    <#
    .SYNOPSIS
        Lee una clave de un JSON sin modificar nada.
    .OUTPUTS
        Objeto con ArchivoExiste, ClaveExiste y Valor.
    .EXAMPLE
        Get-JsonValor -Ruta "$env:APPDATA\discord\settings.json" -Clave 'enableHardwareAcceleration'
    #>
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [Parameter(Mandatory)][string[]]$Clave
    )

    if (-not (Test-Path -LiteralPath $Ruta -PathType Leaf)) {
        return [pscustomobject]@{ ArchivoExiste = $false; ClaveExiste = $false; Valor = $null }
    }
    $raiz = Read-JsonArchivo -Ruta $Ruta
    $padre = Resolve-JsonPadre -Raiz $raiz -Clave $Clave
    if ($padre) {
        $p = $padre.PSObject.Properties[$Clave[$Clave.Count - 1]]
        if ($p) { return [pscustomobject]@{ ArchivoExiste = $true; ClaveExiste = $true; Valor = $p.Value } }
    }
    return [pscustomobject]@{ ArchivoExiste = $true; ClaveExiste = $false; Valor = $null }
}

function Set-JsonValor {
    <#
    .SYNOPSIS
        Cambia una sola clave de un archivo JSON, con respaldo de esa clave en el journal.
    .DESCRIPTION
        Guarda el valor original de la clave (o que no existía). Al deshacer restaura SOLO esa clave,
        sin tocar el resto del archivo, así no se pierden cambios que el usuario haga después.
        Además deja una copia completa del archivo como respaldo de emergencia (una por sesión).
        El archivo se reescribe entero (UTF-8 sin BOM): puede cambiar el formato (sangría) pero no
        el contenido. Si el archivo no existe devuelve NoAplica (no lo crea).
        Nota: algunos programas (p. ej. Discord) reescriben el archivo al cerrarse; cerrar el programa
        antes de llamar a esta función es responsabilidad del tweak.
    .PARAMETER Clave
        Ruta de la clave como lista de nombres. Ej.: 'enableHardwareAcceleration' o 'a','b','c'.
    .OUTPUTS
        'Cambiado', 'SinCambios', 'NoAplica' o 'Fallido'.
    .EXAMPLE
        Set-JsonValor -Ruta "$env:APPDATA\discord\settings.json" -Clave 'enableHardwareAcceleration' -Valor $false
    #>
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [Parameter(Mandatory)][string[]]$Clave,
        [Parameter(Mandatory)][AllowNull()]$Valor
    )

    Assert-JournalListo

    if (-not (Test-Path -LiteralPath $Ruta -PathType Leaf)) {
        Write-Log -Nivel INFO -Mensaje "JSON: '$Ruta' no existe; no aplica."
        return 'NoAplica'
    }

    $etiqueta = '{0} : {1}' -f $Ruta, ($Clave -join '.')
    try {
        $raiz = Read-JsonArchivo -Ruta $Ruta
        $padre = Resolve-JsonPadre -Raiz $raiz -Clave $Clave
    }
    catch {
        Write-Log -Nivel ERROR -Mensaje "JSON: $etiqueta : $($_.Exception.Message)"
        return 'Fallido'
    }

    $hoja = $Clave[$Clave.Count - 1]
    $propiedad = $null
    if ($padre) { $propiedad = $padre.PSObject.Properties[$hoja] }

    if ($propiedad) {
        $a = ConvertTo-Json -InputObject $propiedad.Value -Compress -Depth 20
        $b = ConvertTo-Json -InputObject $Valor -Compress -Depth 20
        if ($a -ceq $b) {
            Write-Log -Nivel DEBUG -Mensaje "JSON: $etiqueta ya tiene el valor deseado."
            return 'SinCambios'
        }
    }

    # Texto del valor anterior para el log (se calcula ahora: $propiedad apunta al valor vivo y cambiará)
    $antesTexto = '(no existía)'
    if ($propiedad) { $antesTexto = ConvertTo-Json -InputObject $propiedad.Value -Compress -Depth 20 }

    # Intermedios que no existen y vamos a crear
    $intermedios = New-Object System.Collections.ArrayList
    if (-not $padre) {
        $actual = $raiz
        for ($i = 0; $i -lt ($Clave.Count - 1); $i++) {
            $p = $actual.PSObject.Properties[$Clave[$i]]
            if ($p) { $actual = $p.Value } else { [void]$intermedios.Add($Clave[$i]) }
        }
    }

    try {
        # Copia completa de emergencia: una por archivo y sesión
        [void](Start-JournalSesion)
        $copias = $global:OptiLow.Journal
        if (-not $copias.ContainsKey('Copias')) { $copias['Copias'] = @{} }
        $clavePath = $Ruta.ToLowerInvariant()
        if (-not $copias.Copias.ContainsKey($clavePath)) {
            $copias.Copias[$clavePath] = New-CopiaRespaldoArchivo -Ruta $Ruta -Indice (Get-JournalProximoIndice)
        }
        $copia = $copias.Copias[$clavePath]

        $entrada = [ordered]@{
            Tipo               = 'Json'
            Descripcion        = "JSON $etiqueta"
            Ruta               = $Ruta
            Clave              = @($Clave)
            ClaveExistia       = [bool]$propiedad
            ValorOriginal      = $(if ($propiedad) { $propiedad.Value } else { $null })
            IntermediosCreados = @($intermedios)
            ValorNuevo         = $Valor
            CopiaEmergencia    = $copia.Ruta
        }
        $registro = Add-JournalEntrada -Entrada $entrada
    }
    catch {
        Write-Log -Nivel ERROR -Mensaje "JSON: no se pudo respaldar $etiqueta : $($_.Exception.Message)"
        return 'Fallido'
    }

    try {
        $padreEscritura = Resolve-JsonPadre -Raiz $raiz -Clave $Clave -Crear
        $existente = $padreEscritura.PSObject.Properties[$hoja]
        if ($existente) {
            $existente.Value = $Valor
        }
        else {
            Add-Member -InputObject $padreEscritura -NotePropertyName $hoja -NotePropertyValue $Valor
        }
        Write-JsonArchivo -Ruta $Ruta -Raiz $raiz
        Set-JournalEntradaEstado -Entrada $registro -Estado Aplicada

        $despues = ConvertTo-Json -InputObject $Valor -Compress -Depth 20
        Write-Log -Nivel OK -Mensaje "JSON: $etiqueta : $antesTexto -> $despues"
        return 'Cambiado'
    }
    catch {
        Set-JournalEntradaEstado -Entrada $registro -Estado Fallida -Detalle $_.Exception.Message
        Write-Log -Nivel ERROR -Mensaje "JSON: no se pudo cambiar $etiqueta : $($_.Exception.Message)"
        return 'Fallido'
    }
}

function Restore-JsonEntrada {
    # Restaura SOLO la clave de una entrada Json. Lanza una excepción si falla. No escribe en el journal.
    param(
        [Parameter(Mandatory)]$Entrada
    )

    $ruta = [string]$Entrada.Ruta
    if (-not (Test-Path -LiteralPath $ruta -PathType Leaf)) {
        throw "El archivo '$ruta' ya no existe (copia de emergencia: '$($Entrada.CopiaEmergencia)')."
    }

    try { $raiz = Read-JsonArchivo -Ruta $ruta }
    catch { throw "$($_.Exception.Message) (copia de emergencia: '$($Entrada.CopiaEmergencia)')." }

    $clave = [string[]]@($Entrada.Clave)
    $hoja = $clave[$clave.Count - 1]

    if ($Entrada.ClaveExistia -eq $true) {
        $padre = Resolve-JsonPadre -Raiz $raiz -Clave $clave -Crear
        $p = $padre.PSObject.Properties[$hoja]
        if ($p) { $p.Value = $Entrada.ValorOriginal }
        else { Add-Member -InputObject $padre -NotePropertyName $hoja -NotePropertyValue $Entrada.ValorOriginal }
    }
    else {
        $padre = Resolve-JsonPadre -Raiz $raiz -Clave $clave
        if ($padre -and $padre.PSObject.Properties[$hoja]) {
            [void]$padre.PSObject.Properties.Remove($hoja)
        }
        # Quitar los objetos intermedios que creamos nosotros, del más interno al más externo, si quedaron vacíos
        $creados = @($Entrada.IntermediosCreados | Where-Object { $_ })
        if ($creados.Count -gt 0) {
            $primero = $clave.Count - 1 - $creados.Count
            for ($n = $clave.Count - 2; $n -ge $primero; $n--) {
                # Resolve-JsonPadre devuelve el contenedor del último nombre de la lista: aquí, el de $clave[$n]
                $subRuta = [string[]]@($clave[0..$n])
                $contenedor = Resolve-JsonPadre -Raiz $raiz -Clave $subRuta
                if (-not $contenedor) { continue }
                $quitar = $contenedor.PSObject.Properties[$clave[$n]]
                if ($quitar -and ($quitar.Value -is [pscustomobject]) -and (@($quitar.Value.PSObject.Properties).Count -eq 0)) {
                    [void]$contenedor.PSObject.Properties.Remove($clave[$n])
                }
            }
        }
    }

    Write-JsonArchivo -Ruta $ruta -Raiz $raiz
    Write-Log -Nivel OK -Mensaje "Restaurado: $($Entrada.Descripcion)"
}
