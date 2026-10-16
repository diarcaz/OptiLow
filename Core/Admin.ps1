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
    #>
    param(
        [Parameter(Mandatory)][string]$RutaScript,
        [string[]]$Argumentos = @()
    )

    if ($PSVersionTable.PSEdition -eq 'Core') {
        $exe = Join-Path $PSHOME 'pwsh.exe'
    }
    else {
        $exe = Join-Path $PSHOME 'powershell.exe'
    }

    $lista = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $RutaScript)) + $Argumentos

    try {
        Start-Process -FilePath $exe -ArgumentList $lista -Verb RunAs -ErrorAction Stop
        return $true
    }
    catch {
        # Código 1223 = el usuario canceló el cuadro de UAC
        if ($_.Exception.NativeErrorCode -eq 1223) {
            Write-Host '[AVISO] Se canceló la solicitud de permisos de administrador.' -ForegroundColor Yellow
        }
        else {
            Write-Host "[ERROR] No se pudo relanzar como administrador: $($_.Exception.Message)" -ForegroundColor Red
        }
        return $false
    }
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
