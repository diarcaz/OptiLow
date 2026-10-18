# Modules/ProgramasInicio.ps1
# Programas de inicio: listar, deshabilitar y habilitar SIN borrar nada, igual que el Administrador de tareas.
#
# Mecanismo (observado en un Windows 11 real; Microsoft no lo documenta):
#   - Las entradas viven en Run (HKCU, HKLM y HKLM\...\WOW6432Node) y en las carpetas de Inicio (usuario y común).
#   - El Administrador de tareas NO las borra: escribe un valor binario de 12 bytes con el MISMO nombre en
#     ...\Explorer\StartupApproved\<Run | Run32 | StartupFolder> (HKCU o HKLM, según el origen).
#       Run (HKCU)        -> HKCU\...\StartupApproved\Run
#       Run (HKLM)        -> HKLM\...\StartupApproved\Run
#       Run (WOW6432Node) -> HKLM\...\StartupApproved\Run32
#       Carpeta usuario   -> HKCU\...\StartupApproved\StartupFolder   (nombre = archivo, p. ej. «AnyDesk.lnk»)
#       Carpeta común     -> HKLM\...\StartupApproved\StartupFolder
#   - Primer byte: bit 0 activado (03, 07...) = deshabilitado; 02 (y 06, 00) = habilitado. Los bytes 4-11 son la fecha
#     (FILETIME) en que se deshabilitó. Sin valor = habilitado.
#   - Deshabilitar escribe 03 00 00 00 + FILETIME; habilitar escribe 02 y 11 ceros (lo mismo que el Administrador de tareas).
#
# Las escrituras pasan por Set-RegistroValor (journal), con TweakActual = 'programas-inicio'.
# Listar solo lee.

# (Sin variables $script: las funciones se promueven al ámbito global y no las verían.)
function Get-InicioProtegidos {
    # Entradas que OptiLow se niega a deshabilitar (CLAUDE.md: no desactivar Windows Defender / seguridad)
    return @('SecurityHealth', 'SecurityHealthSystray', 'WindowsDefender', 'Windows Defender', 'Windows Defender Notifications', 'MsMpEng')
}

function Get-InicioFuentes {
    # Auxiliar interna: las cinco fuentes y dónde guarda cada una su estado.
    $aprob = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\'
    return @(
        @{ Id = 'hkcu-run'; Tipo = 'Run'; Hive = 'HKCU'; Ruta = 'Software\Microsoft\Windows\CurrentVersion\Run'; Aprob = ($aprob + 'Run'); Origen = 'Usuario (Run)'; Admin = $false }
        @{ Id = 'hklm-run'; Tipo = 'Run'; Hive = 'HKLM'; Ruta = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Aprob = ($aprob + 'Run'); Origen = 'Equipo (Run)'; Admin = $true }
        @{ Id = 'hklm-run32'; Tipo = 'Run'; Hive = 'HKLM'; Ruta = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Aprob = ($aprob + 'Run32'); Origen = 'Equipo, 32 bits (Run)'; Admin = $true }
        @{ Id = 'carpeta-usuario'; Tipo = 'Carpeta'; Hive = 'HKCU'; Carpeta = [Environment]::GetFolderPath('Startup'); Aprob = ($aprob + 'StartupFolder'); Origen = 'Carpeta Inicio del usuario'; Admin = $false }
        @{ Id = 'carpeta-comun'; Tipo = 'Carpeta'; Hive = 'HKLM'; Carpeta = [Environment]::GetFolderPath('CommonStartup'); Aprob = ($aprob + 'StartupFolder'); Origen = 'Carpeta Inicio común'; Admin = $true }
    )
}

function Test-InicioBytesDeshabilitado {
    <#
    .SYNOPSIS
        ¿Estos bytes de StartupApproved significan «deshabilitado»? Bit 0 del primer byte (03, 07...). Sin datos = habilitado.
    #>
    param(
        [AllowNull()]$Bytes
    )
    if (($Bytes -is [byte[]]) -and ($Bytes.Length -gt 0)) { return (($Bytes[0] -band 1) -eq 1) }
    return $false
}

function New-InicioBytes {
    <#
    .SYNOPSIS
        Los 12 bytes que escribe el Administrador de tareas: 02 + ceros (habilitado) o 03 + ceros + FILETIME (deshabilitado).
    #>
    param(
        [Parameter(Mandatory)][bool]$Habilitado
    )
    $b = New-Object byte[] 12
    if ($Habilitado) { $b[0] = 2; return , $b }
    $b[0] = 3
    $ft = [BitConverter]::GetBytes([int64][DateTime]::UtcNow.ToFileTimeUtc())
    [Array]::Copy($ft, 0, $b, 4, 8)
    return , $b
}

function Get-InicioComandoAtajo {
    # Auxiliar interna: destino de un acceso directo (.lnk); si no se puede leer devuelve el nombre del archivo.
    param(
        [Parameter(Mandatory)][string]$Ruta
    )
    try {
        if ($Ruta -like '*.lnk') {
            $sh = New-Object -ComObject WScript.Shell
            try {
                $a = $sh.CreateShortcut($Ruta)
                $t = ('{0} {1}' -f $a.TargetPath, $a.Arguments).Trim()
                if ($t) { return $t }
            }
            finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) }
        }
    }
    catch { }
    return $Ruta
}

function Get-ProgramasInicio {
    <#
    .SYNOPSIS
        Lista los programas de inicio (Run y carpetas de Inicio) con su estado. Solo lee.
    .DESCRIPTION
        Devuelve objetos con Id (único: «fuente|nombre»), Nombre, Origen, Comando, Habilitado, Protegido y RequiereAdmin.
        Las apps de la Store que arrancan solas NO están aquí: ver Get-ProgramasInicioStore.
    #>
    $lista = New-Object System.Collections.ArrayList
    $protegidos = Get-InicioProtegidos
    foreach ($f in (Get-InicioFuentes)) {
        $hive = $(if ($f.Hive -eq 'HKCU') { [Microsoft.Win32.RegistryHive]::CurrentUser } else { [Microsoft.Win32.RegistryHive]::LocalMachine })
        $nombres = New-Object System.Collections.ArrayList
        $comandos = @{}
        if ($f.Tipo -eq 'Run') {
            $base = Open-RegistroBase -Hive $hive
            try {
                $k = $base.OpenSubKey($f.Ruta, $false)
                if ($k) {
                    try {
                        foreach ($n in $k.GetValueNames()) {
                            if (-not $n) { continue }
                            [void]$nombres.Add($n)
                            $comandos[$n] = [string]$k.GetValue($n, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                        }
                    }
                    finally { $k.Dispose() }
                }
            }
            finally { $base.Dispose() }
        }
        else {
            if ((-not $f.Carpeta) -or (-not (Test-Path -LiteralPath $f.Carpeta))) { continue }
            foreach ($item in (Get-ChildItem -LiteralPath $f.Carpeta -File -Force -ErrorAction SilentlyContinue)) {
                if ($item.Name -ieq 'desktop.ini') { continue }
                [void]$nombres.Add($item.Name)
                $comandos[$item.Name] = Get-InicioComandoAtajo -Ruta $item.FullName
            }
        }
        foreach ($n in $nombres) {
            $est = Get-RegistroEstado -Ruta ('{0}:\{1}' -f $f.Hive, $f.Aprob) -Nombre $n
            $off = $false
            if ($est.ValorExiste -and ($est.Tipo -eq 'Binary')) { $off = Test-InicioBytesDeshabilitado -Bytes $est.Dato }
            $base0 = [System.IO.Path]::GetFileNameWithoutExtension($n)
            $prot = (@($protegidos) -contains $n) -or (@($protegidos) -contains $base0)
            [void]$lista.Add([pscustomobject]@{
                    Id            = ('{0}|{1}' -f $f.Id, $n)
                    Fuente        = $f.Id
                    Nombre        = $n
                    Origen        = $f.Origen
                    Comando       = [string]$comandos[$n]
                    Habilitado    = (-not $off)
                    Protegido     = $prot
                    RequiereAdmin = [bool]$f.Admin
                })
        }
    }
    return @($lista)
}

function Get-ProgramasInicioStore {
    <#
    .SYNOPSIS
        Apps de la Store que declaran una tarea de inicio (solo lee). OptiLow NO las gestiona: se cambian en
        Configuración > Aplicaciones > Inicio. No se afirma si están habilitadas (el significado de los valores
        del registro no está documentado).
    #>
    $res = New-Object System.Collections.ArrayList
    $r = 'Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
    $base = Open-RegistroBase -Hive ([Microsoft.Win32.RegistryHive]::CurrentUser)
    try {
        $k = $base.OpenSubKey($r, $false)
        if (-not $k) { return @() }
        try {
            foreach ($pkg in $k.GetSubKeyNames()) {
                $kp = $k.OpenSubKey($pkg, $false)
                if (-not $kp) { continue }
                try {
                    foreach ($tarea in $kp.GetSubKeyNames()) {
                        $kt = $kp.OpenSubKey($tarea, $false)
                        if (-not $kt) { continue }
                        try {
                            if (@($kt.GetValueNames()) -contains 'UserEnabledStartupOnce') {
                                [void]$res.Add([pscustomobject]@{ Paquete = $pkg; Nombre = ($pkg -split '_')[0]; Tarea = $tarea })
                            }
                        }
                        finally { $kt.Dispose() }
                    }
                }
                finally { $kp.Dispose() }
            }
        }
        finally { $k.Dispose() }
    }
    finally { $base.Dispose() }
    return @($res)
}

function Set-ProgramaInicio {
    <#
    .SYNOPSIS
        Habilita o deshabilita UN programa de inicio escribiendo su valor en StartupApproved (journal). Nunca borra.
    .OUTPUTS
        'Cambiado', 'SinCambios', 'NoAplica' (ya no existe o es un elemento protegido) o 'Fallido'.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][bool]$Habilitado
    )

    $p = Get-ProgramasInicio | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $p) { Write-Log -Nivel WARN -Mensaje "Inicio: '$Id' ya no existe."; return 'NoAplica' }
    if ($p.Habilitado -eq $Habilitado) { Write-Log -Nivel DEBUG -Mensaje "Inicio: '$($p.Nombre)' ya estaba $(if ($Habilitado) { 'habilitado' } else { 'deshabilitado' })."; return 'SinCambios' }
    if ((-not $Habilitado) -and $p.Protegido) {
        Write-Log -Nivel WARN -Mensaje "Inicio: '$($p.Nombre)' es un componente de seguridad de Windows y OptiLow no lo deshabilita."
        return 'NoAplica'
    }
    $f = Get-InicioFuentes | Where-Object { $_.Id -eq $p.Fuente } | Select-Object -First 1
    $res = Set-RegistroValor -Ruta ('{0}:\{1}' -f $f.Hive, $f.Aprob) -Nombre $p.Nombre -Valor (New-InicioBytes -Habilitado $Habilitado) -Tipo Binary
    if ($res -eq 'Cambiado') { Write-Log -Nivel OK -Mensaje "Inicio: '$($p.Nombre)' [$($p.Origen)] ahora está $(if ($Habilitado) { 'habilitado' } else { 'deshabilitado' })." }
    return $res
}

function Invoke-ProgramasInicioCambio {
    <#
    .SYNOPSIS
        Habilita o deshabilita varios programas de inicio en UNA sesión nueva del journal.
    .OUTPUTS
        Objeto con Cambiados, SinCambios, NoAplica, Fallidos (listas de nombres) y Sesion.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Ids,
        [Parameter(Mandatory)][bool]$Habilitar
    )

    $sesion = Start-JournalSesion -Nueva
    $r = [ordered]@{ Sesion = $sesion; Cambiados = @(); SinCambios = @(); NoAplica = @(); Fallidos = @() }
    $global:OptiLow.TweakActual = 'programas-inicio'
    try {
        foreach ($id in $Ids) {
            $nombre = ($id -split '\|', 2)[-1]
            $est = 'Fallido'
            try { $est = Set-ProgramaInicio -Id $id -Habilitado $Habilitar }
            catch { Write-Log -Nivel ERROR -Mensaje "Inicio: no se pudo cambiar '$nombre': $($_.Exception.Message)" }
            switch ($est) {
                'Cambiado' { $r.Cambiados += $nombre }
                'SinCambios' { $r.SinCambios += $nombre }
                'NoAplica' { $r.NoAplica += $nombre }
                default { $r.Fallidos += $nombre }
            }
        }
    }
    finally { $global:OptiLow.TweakActual = $null }
    return [pscustomobject]$r
}
