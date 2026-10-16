# Core/Admin.ps1
# Verificación de administrador, relanzado elevado y detección de escritorio de otro usuario.

function Test-EsAdministrador {
    $identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identidad)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-RelanzarComoAdministrador {
    <#
    .SYNOPSIS
        Relanza el script elevado con UAC. Devuelve $true si el proceso elevado se inició,
        $false si el usuario canceló o falló.
    .DESCRIPTION
        Usa el ejecutable del mismo PowerShell ($PSHOME), no el del host (ISE, VS Code).
        Si Windows PowerShell corre en 32 bits sobre un Windows de 64, relanza la versión de
        64 bits (Sysnative).
        Se usa Process.Start con ShellExecute y no Start-Process: en Windows PowerShell 5.1,
        Start-Process lanza un InvalidOperationException nuevo, sin InnerException, y se
        pierde el código de error 1223 (UAC cancelado). Process.Start lanza el Win32Exception
        (PowerShell lo entrega dentro de un MethodInvocationException).
    #>
    param(
        [Parameter(Mandatory)][string]$RutaScript,
        [string[]]$Argumentos = @(),
        [switch]$Oculto
    )

    if ($PSVersionTable.PSEdition -eq 'Core') {
        $exe = Join-Path $PSHOME 'pwsh.exe'
    }
    elseif ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $exe = Join-Path $env:windir 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    }
    else {
        $exe = Join-Path $PSHOME 'powershell.exe'
    }

    # Una sola cadena de argumentos, con comillas en lo que tenga espacios (rutas con espacios y acentos).
    $partes = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $RutaScript) + $Argumentos
    $cadena = ($partes | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }) -join ' '

    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName         = $exe
        $info.Arguments        = $cadena
        $info.UseShellExecute  = $true
        $info.Verb             = 'runas'
        # Modo interfaz: la consola del proceso elevado va oculta (-MostrarConsola la deja visible)
        if ($Oculto) { $info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden }
        $info.WorkingDirectory = Split-Path -Parent $RutaScript
        [void][System.Diagnostics.Process]::Start($info)
        return $true
    }
    catch {
        if (Test-EsCancelacionUAC -Excepcion $_.Exception) {
            Write-Log -Nivel WARN -Mensaje 'Se canceló la solicitud de permisos. OptiLow necesita ser administrador para continuar.'
        }
        else {
            Write-Log -Nivel ERROR -Mensaje "No se pudo relanzar como administrador: $($_.Exception.Message)"
        }
        return $false
    }
}

function Test-EsCancelacionUAC {
    <#
    .SYNOPSIS
        Indica si la excepción corresponde a que el usuario canceló el cuadro de UAC
        (Win32Exception con código 1223). Start-Process la envuelve en otra excepción,
        por eso se recorre la cadena de InnerException.
    #>
    param(
        [Parameter(Mandatory)][System.Exception]$Excepcion
    )

    $actual = $Excepcion
    while ($actual) {
        if (($actual -is [System.ComponentModel.Win32Exception]) -and ($actual.NativeErrorCode -eq 1223)) {
            return $true
        }
        $actual = $actual.InnerException
    }
    return $false
}

function Test-EscritorioDeOtroUsuario {
    <#
    .SYNOPSIS
        Detecta si el escritorio (explorer.exe de esta sesión) pertenece a un usuario distinto
        del que ejecuta el script (elevación con credenciales de otra cuenta).
    .OUTPUTS
        Objeto con Distinto, UsuarioProceso y UsuarioEscritorio; o $null si no se pudo determinar.
    #>
    try {
        $sesion = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $yo = [Security.Principal.WindowsIdentity]::GetCurrent().Name

        $procesos = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe' AND SessionId=$sesion" -ErrorAction Stop)
        foreach ($p in $procesos) {
            $dueno = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
            if ($dueno.ReturnValue -eq 0) {
                $usuarioEscritorio = '{0}\{1}' -f $dueno.Domain, $dueno.User
                return [pscustomobject]@{
                    Distinto          = ($usuarioEscritorio -ne $yo)
                    UsuarioProceso    = $yo
                    UsuarioEscritorio = $usuarioEscritorio
                }
            }
        }
        return $null
    }
    catch {
        return $null
    }
}
