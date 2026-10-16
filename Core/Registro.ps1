# Core/Registro.ps1
# Escritura del registro con respaldo automático (journal).
#
# - Soporta DWord, QWord, String, ExpandString, MultiString y Binary.
# - HKLM y HKCU se abren SIEMPRE con RegistryView.Registry64, para evitar la redirección a
#   WOW6432Node si PowerShell corre en 32 bits.
# - ExpandString se guarda sin expandir las variables de entorno.
# - Si la clave o el valor no existían, el deshacer los elimina (solo lo que creamos nosotros;
#   una clave solo si queda vacía).
# - Si el valor ya es el deseado (mismo tipo y mismo dato), no se escribe ni se anota en el journal.
#
# Las funciones de escritura devuelven: Cambiado, SinCambios o Fallido.

function ConvertTo-RegistroRutaInfo {
    # Auxiliar interna: separa 'HKLM:\SOFTWARE\X' en hive y subclave. Solo HKLM y HKCU.
    param(
        [Parameter(Mandatory)][string]$Ruta
    )

    if (-not ($Ruta -match '^(HKLM|HKCU|HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER):?\\(.+)$')) {
        throw "Ruta de registro no válida o no soportada: '$Ruta'. Use HKLM:\... o HKCU:\..."
    }
    $hive = $Matches[1].ToUpper()
    $sub = $Matches[2].Trim('\')

    if (($hive -eq 'HKLM') -or ($hive -eq 'HKEY_LOCAL_MACHINE')) {
        $enum = [Microsoft.Win32.RegistryHive]::LocalMachine
        $corto = 'HKLM'
    }
    else {
        $enum = [Microsoft.Win32.RegistryHive]::CurrentUser
        $corto = 'HKCU'
    }
    return [pscustomobject]@{ Hive = $enum; Corto = $corto; SubClave = $sub; RutaCompleta = ($corto + ':\' + $sub) }
}

function Open-RegistroBase {
    # Auxiliar interna: abre la raíz del hive en la vista de 64 bits. El que llama debe hacer Dispose().
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryHive]$Hive
    )
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
}

function Test-RegistroClaveExiste {
    # Auxiliar interna.
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryHive]$Hive,
        [Parameter(Mandatory)][string]$SubClave
    )

    $base = Open-RegistroBase -Hive $Hive
    try {
        $k = $base.OpenSubKey($SubClave, $false)
        if ($k) { $k.Dispose(); return $true }
        return $false
    }
    finally { $base.Dispose() }
}

function ConvertTo-RegistroDatoNormal {
    # Auxiliar interna: lleva el dato a su forma canónica: DWord=uint32, QWord=uint64, Binary=byte[],
    # MultiString=string[], String/ExpandString=string. Acepta valores con signo (como los devuelve .NET).
    param(
        [Parameter(Mandatory)][string]$Tipo,
        $Valor
    )

    switch ($Tipo) {
        'DWord' {
            if ($Valor -is [uint32]) { return $Valor }
            $n = [int64]$Valor
            if ($n -lt 0) { $n = $n + 4294967296 }
            return [uint32]$n
        }
        'QWord' {
            if ($Valor -is [uint64]) { return $Valor }
            if ($Valor -is [string]) { return [uint64]::Parse($Valor, [System.Globalization.CultureInfo]::InvariantCulture) }
            $n = [int64]$Valor
            if ($n -lt 0) { return [BitConverter]::ToUInt64([BitConverter]::GetBytes($n), 0) }
            return [uint64]$n
        }
        'Binary' {
            if ($Valor -is [string]) { return , [Convert]::FromBase64String($Valor) }
            return , ([byte[]]@($Valor))
        }
        'MultiString' { return , ([string[]]@($Valor | Where-Object { $null -ne $_ })) }
        'String' { return [string]$Valor }
        'ExpandString' { return [string]$Valor }
        default { throw "Tipo de registro desconocido: '$Tipo'." }
    }
}

function ConvertTo-RegistroEscribible {
    # Auxiliar interna: dato canónico -> objeto que acepta RegistryKey.SetValue.
    param(
        [Parameter(Mandatory)][string]$Tipo,
        [AllowNull()][AllowEmptyString()][AllowEmptyCollection()]$Normal
    )

    switch ($Tipo) {
        'DWord' { return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$Normal), 0) }
        'QWord' { return [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$Normal), 0) }
        default { return , $Normal }
    }
}

function ConvertTo-RegistroDatoJson {
    # Auxiliar interna: dato canónico -> forma que se guarda en el JSON del journal.
    param(
        [Parameter(Mandatory)][string]$Tipo,
        [AllowNull()][AllowEmptyString()][AllowEmptyCollection()]$Normal
    )

    switch ($Tipo) {
        'DWord' { return [int64]$Normal }
        'QWord' { return $Normal.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
        'Binary' { return [Convert]::ToBase64String([byte[]]$Normal) }
        'MultiString' { return , @([string[]]$Normal) }
        default { return [string]$Normal }
    }
}

function Format-RegistroDato {
    # Auxiliar interna: texto corto del dato para el log.
    param(
        [string]$Tipo,
        $Normal
    )

    if (-not $Tipo) { return '(no existía)' }
    switch ($Tipo) {
        'Binary' {
            $bytes = [byte[]]$Normal
            $hex = ($bytes | Select-Object -First 16 | ForEach-Object { $_.ToString('X2') }) -join ' '
            if ($bytes.Length -gt 16) { $hex += ' ...' }
            return "[$hex] (Binary)"
        }
        'MultiString' { return ('[' + (([string[]]$Normal) -join ' | ') + '] (MultiString)') }
        default { return "$Normal ($Tipo)" }
    }
}

function Test-RegistroDatoIgual {
    # Auxiliar interna: compara dos datos canónicos del mismo tipo.
    param(
        [Parameter(Mandatory)][string]$Tipo,
        $A,
        $B
    )

    switch ($Tipo) {
        'Binary' { return ([Convert]::ToBase64String([byte[]]$A) -ceq [Convert]::ToBase64String([byte[]]$B)) }
        'MultiString' { return ((([string[]]$A) -join "`0") -ceq (([string[]]$B) -join "`0")) }
        'String' { return ([string]$A -ceq [string]$B) }
        'ExpandString' { return ([string]$A -ceq [string]$B) }
        default { return ($A -eq $B) }
    }
}

function Get-RegistroEstado {
    <#
    .SYNOPSIS
        Lee el estado de un valor del registro (vista de 64 bits) sin modificar nada.
    .DESCRIPTION
        Devuelve ClaveExiste, ValorExiste, Tipo (DWord, QWord, String, ExpandString, MultiString,
        Binary...) y Dato en forma canónica (ExpandString sin expandir). Nombre vacío = valor predeterminado.
    .EXAMPLE
        Get-RegistroEstado -Ruta 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Nombre 'EnableTransparency'
    #>
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [string]$Nombre = ''
    )

    $info = ConvertTo-RegistroRutaInfo -Ruta $Ruta
    $base = Open-RegistroBase -Hive $info.Hive
    try {
        $k = $base.OpenSubKey($info.SubClave, $false)
        if (-not $k) {
            return [pscustomobject]@{ ClaveExiste = $false; ValorExiste = $false; Tipo = $null; Dato = $null }
        }
        try {
            if (@($k.GetValueNames()) -notcontains $Nombre) {
                return [pscustomobject]@{ ClaveExiste = $true; ValorExiste = $false; Tipo = $null; Dato = $null }
            }
            $tipo = $k.GetValueKind($Nombre).ToString()
            $crudo = $k.GetValue($Nombre, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $dato = $crudo
            if (@('DWord', 'QWord', 'Binary', 'MultiString', 'String', 'ExpandString') -contains $tipo) {
                $dato = ConvertTo-RegistroDatoNormal -Tipo $tipo -Valor $crudo
            }
            return [pscustomobject]@{ ClaveExiste = $true; ValorExiste = $true; Tipo = $tipo; Dato = $dato }
        }
        finally { $k.Dispose() }
    }
    finally { $base.Dispose() }
}

function Set-RegistroValorInterno {
    # Auxiliar interna: hace el trabajo de Set-RegistroValor / Remove-RegistroValor y devuelve también
    # la entrada del journal (la usa el punto de restauración para revertir su ajuste temporal).
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [string]$Nombre = '',
        $Valor,
        [string]$Tipo,
        [switch]$Eliminar
    )

    Assert-JournalListo

    $info = ConvertTo-RegistroRutaInfo -Ruta $Ruta
    $etiqueta = '{0}\{1}' -f $info.RutaCompleta, $(if ($Nombre) { $Nombre } else { '(predeterminado)' })
    $actual = Get-RegistroEstado -Ruta $info.RutaCompleta -Nombre $Nombre

    if ($Eliminar) {
        if (-not $actual.ValorExiste) {
            Write-Log -Nivel DEBUG -Mensaje "Registro: $etiqueta ya no existe; nada que eliminar."
            return [pscustomobject]@{ Estado = 'SinCambios'; Entrada = $null }
        }
        $nuevo = $null
    }
    else {
        $nuevo = ConvertTo-RegistroDatoNormal -Tipo $Tipo -Valor $Valor
        if ($actual.ValorExiste -and ($actual.Tipo -eq $Tipo) -and (Test-RegistroDatoIgual -Tipo $Tipo -A $actual.Dato -B $nuevo)) {
            Write-Log -Nivel DEBUG -Mensaje "Registro: $etiqueta ya tiene el valor deseado."
            return [pscustomobject]@{ Estado = 'SinCambios'; Entrada = $null }
        }
    }

    # Claves que no existen y vamos a crear (de la más externa a la más interna)
    $creadas = New-Object System.Collections.ArrayList
    if ((-not $Eliminar) -and (-not $actual.ClaveExiste)) {
        $acumulada = ''
        foreach ($parte in $info.SubClave.Split('\')) {
            if ($acumulada) { $acumulada = $acumulada + '\' + $parte } else { $acumulada = $parte }
            if (-not (Test-RegistroClaveExiste -Hive $info.Hive -SubClave $acumulada)) { [void]$creadas.Add($acumulada) }
        }
    }

    $entrada = [ordered]@{
        Tipo          = 'Registro'
        Descripcion   = $etiqueta
        Ruta          = $info.RutaCompleta
        Nombre        = $Nombre
        Accion        = $(if ($Eliminar) { 'Eliminar' } else { 'Escribir' })
        ClaveExistia  = $actual.ClaveExiste
        ClavesCreadas = @($creadas)
        ValorExistia  = $actual.ValorExiste
        TipoOriginal  = $actual.Tipo
        DatoOriginal  = $(if ($actual.ValorExiste) { ConvertTo-RegistroDatoJson -Tipo $actual.Tipo -Normal $actual.Dato } else { $null })
        TipoNuevo     = $(if ($Eliminar) { $null } else { $Tipo })
        DatoNuevo     = $(if ($Eliminar) { $null } else { ConvertTo-RegistroDatoJson -Tipo $Tipo -Normal $nuevo })
    }
    $registro = Add-JournalEntrada -Entrada $entrada

    $base = Open-RegistroBase -Hive $info.Hive
    try {
        if ($Eliminar) {
            $k = $base.OpenSubKey($info.SubClave, $true)
            try { $k.DeleteValue($Nombre, $true) } finally { $k.Dispose() }
        }
        else {
            $k = $base.CreateSubKey($info.SubClave)
            try {
                $k.SetValue($Nombre, (ConvertTo-RegistroEscribible -Tipo $Tipo -Normal $nuevo), [Microsoft.Win32.RegistryValueKind]::$Tipo)
            }
            finally { $k.Dispose() }
        }
        Set-JournalEntradaEstado -Entrada $registro -Estado Aplicada

        $antes = Format-RegistroDato -Tipo $actual.Tipo -Normal $actual.Dato
        $despues = if ($Eliminar) { '(eliminado)' } else { Format-RegistroDato -Tipo $Tipo -Normal $nuevo }
        Write-Log -Nivel OK -Mensaje "Registro: $etiqueta : $antes -> $despues"
        return [pscustomobject]@{ Estado = 'Cambiado'; Entrada = $registro }
    }
    catch {
        $mensajeError = $_.Exception.Message
        Write-Log -Nivel ERROR -Mensaje "Registro: no se pudo cambiar $etiqueta : $mensajeError"

        # Si el fallo no tocó nada, la entrada no debe quedar en el journal; si pudo quedar algo a medias
        # (p. ej. se creó la clave pero no el valor), se conserva como Fallida para que el deshacer lo limpie.
        $despuesFallo = Get-RegistroEstado -Ruta $info.RutaCompleta -Nombre $Nombre
        $igual = ($despuesFallo.ClaveExiste -eq $actual.ClaveExiste) -and ($despuesFallo.ValorExiste -eq $actual.ValorExiste)
        if ($igual -and $actual.ValorExiste) {
            $igual = ($despuesFallo.Tipo -eq $actual.Tipo) -and (Test-RegistroDatoIgual -Tipo $actual.Tipo -A $despuesFallo.Dato -B $actual.Dato)
        }
        if ($igual) {
            Remove-JournalEntrada -Entrada $registro
            return [pscustomobject]@{ Estado = 'Fallido'; Entrada = $null }
        }
        Set-JournalEntradaEstado -Entrada $registro -Estado Fallida -Detalle $mensajeError
        return [pscustomobject]@{ Estado = 'Fallido'; Entrada = $registro }
    }
    finally { $base.Dispose() }
}

function Set-RegistroValor {
    <#
    .SYNOPSIS
        Escribe un valor del registro con respaldo automático en el journal.
    .PARAMETER Tipo
        DWord, QWord, String, ExpandString, MultiString o Binary.
    .OUTPUTS
        'Cambiado', 'SinCambios' (ya tenía el valor) o 'Fallido'.
    .EXAMPLE
        Set-RegistroValor -Ruta 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Nombre 'EnableTransparency' -Valor 0 -Tipo DWord
    .EXAMPLE
        Set-RegistroValor -Ruta 'HKLM:\SOFTWARE\Policies\Google\Chrome' -Nombre 'HardwareAccelerationModeEnabled' -Valor 0 -Tipo DWord
    .EXAMPLE
        Set-RegistroValor -Ruta 'HKCU:\Software\Prueba' -Nombre 'Lista' -Valor @('a', 'b') -Tipo MultiString
    #>
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()]$Valor,
        [Parameter(Mandatory)][ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary')][string]$Tipo
    )

    return (Set-RegistroValorInterno -Ruta $Ruta -Nombre $Nombre -Valor $Valor -Tipo $Tipo).Estado
}

function Remove-RegistroValor {
    <#
    .SYNOPSIS
        Elimina un valor del registro; queda en el journal y el deshacer lo vuelve a crear.
    .OUTPUTS
        'Cambiado', 'SinCambios' (no existía) o 'Fallido'.
    .EXAMPLE
        Remove-RegistroValor -Ruta 'HKCU:\Software\Prueba' -Nombre 'Valor'
    #>
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [Parameter(Mandatory)][string]$Nombre
    )

    return (Set-RegistroValorInterno -Ruta $Ruta -Nombre $Nombre -Eliminar).Estado
}

function Restore-RegistroEntrada {
    # Restaura una entrada de tipo Registro (usada por Undo-JournalSesion y por el punto de restauración).
    # No escribe en el journal. Lanza una excepción si falla.
    param(
        [Parameter(Mandatory)]$Entrada
    )

    $info = ConvertTo-RegistroRutaInfo -Ruta $Entrada.Ruta
    $nombre = [string]$Entrada.Nombre
    $base = Open-RegistroBase -Hive $info.Hive
    try {
        if ($Entrada.ValorExistia -eq $true) {
            $normal = ConvertFrom-RegistroDatoJson -Tipo $Entrada.TipoOriginal -Dato $Entrada.DatoOriginal
            $k = $base.CreateSubKey($info.SubClave)
            try {
                $k.SetValue($nombre, (ConvertTo-RegistroEscribible -Tipo $Entrada.TipoOriginal -Normal $normal), [Microsoft.Win32.RegistryValueKind]::($Entrada.TipoOriginal))
            }
            finally { $k.Dispose() }
            Write-Log -Nivel OK -Mensaje "Restaurado: $($Entrada.Descripcion) -> $(Format-RegistroDato -Tipo $Entrada.TipoOriginal -Normal $normal)"
        }
        else {
            # No existía: se elimina lo que creamos nosotros (el valor y las claves vacías que creamos)
            $k = $base.OpenSubKey($info.SubClave, $true)
            if ($k) {
                try {
                    if (@($k.GetValueNames()) -contains $nombre) { $k.DeleteValue($nombre, $false) }
                }
                finally { $k.Dispose() }
            }
            $claves = @($Entrada.ClavesCreadas | Where-Object { $_ })
            [array]::Reverse($claves)
            foreach ($clave in $claves) {
                $k = $base.OpenSubKey($clave, $false)
                if (-not $k) { continue }
                $vacia = ($k.ValueCount -eq 0) -and ($k.SubKeyCount -eq 0)
                $k.Dispose()
                if ($vacia) {
                    $base.DeleteSubKey($clave, $false)
                }
                else {
                    Write-Log -Nivel WARN -Mensaje "No se elimina la clave '$($info.Corto):\$clave' porque ya no está vacía (tiene contenido que no es nuestro)."
                }
            }
            Write-Log -Nivel OK -Mensaje "Restaurado: $($Entrada.Descripcion) -> (no existía)"
        }
    }
    finally { $base.Dispose() }
}

function ConvertFrom-RegistroDatoJson {
    # Auxiliar interna: dato del JSON del journal -> forma canónica.
    param(
        [Parameter(Mandatory)][string]$Tipo,
        [AllowNull()][AllowEmptyString()][AllowEmptyCollection()]$Dato
    )
    return , (ConvertTo-RegistroDatoNormal -Tipo $Tipo -Valor $Dato)
}
