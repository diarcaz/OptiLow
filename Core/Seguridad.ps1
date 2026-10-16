# Core/Seguridad.ps1
# Carpeta de respaldos (journal) protegida: solo Administradores y SYSTEM.
# Todo se identifica por SID (no por nombre) para que funcione en cualquier idioma de Windows.

$global:OptiLowSidAdministradores = 'S-1-5-32-544'
$global:OptiLowSidSystem          = 'S-1-5-18'

function Test-AclRespaldos {
    <#
    .SYNOPSIS
        Verifica que una carpeta (o archivo) de respaldos solo sea accesible para Administradores y SYSTEM.
    .DESCRIPTION
        Comprueba: que exista, que el propietario sea Administradores o SYSTEM, que (en carpetas) no
        herede permisos de la carpeta superior, que ninguna otra cuenta tenga reglas de acceso y que
        Administradores tenga al menos una regla de permitir.
    .OUTPUTS
        Objeto con Valido (bool) y Motivos (lista de textos).
    .EXAMPLE
        Test-AclRespaldos -Ruta 'C:\ProgramData\OptiLow\backups'
    #>
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [switch]$Archivo
    )

    $motivos = New-Object System.Collections.ArrayList
    try {
        if (-not (Test-Path -LiteralPath $Ruta)) {
            [void]$motivos.Add("No existe '$Ruta'.")
            return [pscustomobject]@{ Valido = $false; Motivos = @($motivos) }
        }

        $permitidos = @($global:OptiLowSidAdministradores, $global:OptiLowSidSystem)
        $acl = Get-Acl -LiteralPath $Ruta
        $sidTipo = [System.Security.Principal.SecurityIdentifier]

        $sidDueno = $acl.GetOwner($sidTipo).Value
        if ($permitidos -notcontains $sidDueno) {
            [void]$motivos.Add("El propietario es '$sidDueno' y debe ser Administradores o SYSTEM.")
        }

        if ((-not $Archivo) -and (-not $acl.AreAccessRulesProtected)) {
            [void]$motivos.Add('La carpeta hereda permisos de la carpeta superior.')
        }

        $adminPermitido = $false
        foreach ($regla in $acl.GetAccessRules($true, $true, $sidTipo)) {
            $sid = $regla.IdentityReference.Value
            if ($permitidos -notcontains $sid) {
                [void]$motivos.Add("La cuenta '$sid' tiene una regla de acceso ($($regla.AccessControlType): $($regla.FileSystemRights)).")
            }
            elseif (($sid -eq $global:OptiLowSidAdministradores) -and ($regla.AccessControlType -eq 'Allow')) {
                $adminPermitido = $true
            }
        }
        if (-not $adminPermitido) {
            [void]$motivos.Add('Administradores no tiene ninguna regla de acceso permitido.')
        }
    }
    catch {
        [void]$motivos.Add("No se pudieron leer los permisos de '$Ruta': $($_.Exception.Message)")
    }

    return [pscustomobject]@{ Valido = ($motivos.Count -eq 0); Motivos = @($motivos) }
}

function Set-AclRespaldos {
    # Auxiliar interna: fija propietario Administradores, sin herencia, Control total solo para Administradores y SYSTEM.
    param(
        [Parameter(Mandatory)][string]$Ruta
    )

    $admins = New-Object System.Security.Principal.SecurityIdentifier($global:OptiLowSidAdministradores)
    $system = New-Object System.Security.Principal.SecurityIdentifier($global:OptiLowSidSystem)

    $seguridad = New-Object System.Security.AccessControl.DirectorySecurity
    $seguridad.SetAccessRuleProtection($true, $false)   # no heredar de ProgramData, no copiar lo heredado
    $seguridad.SetOwner($admins)
    foreach ($sid in @($admins, $system)) {
        $regla = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $seguridad.AddAccessRule($regla)
    }
    Set-Acl -LiteralPath $Ruta -AclObject $seguridad
}

function Initialize-CarpetaRespaldos {
    <#
    .SYNOPSIS
        Crea y protege la carpeta de respaldos. Solo funciona elevado.
    .DESCRIPTION
        Deja $global:OptiLow.DirRespaldos con la ruta si todo es correcto, o en $null si no.
        - Sin administrador (-SinElevar): no se crea nada.
        - Si ya existe con permisos correctos: se usa tal cual.
        - Si existe con permisos incorrectos y está vacía: se corrigen los permisos.
        - Si existe con permisos incorrectos y tiene contenido: se renombra a
          'backups.sin-verificar-<fecha>' (nunca se usa para deshacer ni se borra) y se crea una nueva.
    .OUTPUTS
        $true si quedó lista, $false si no.
    .EXAMPLE
        Initialize-CarpetaRespaldos
    #>
    $e = $global:OptiLow
    $e.DirRespaldos = $null

    if (-not (Test-EsAdministrador)) {
        Write-Log -Nivel WARN -Mensaje 'Sin permisos de administrador: no se crea la carpeta de respaldos. No se podrá aplicar ningún cambio.'
        return $false
    }

    $ruta = $e.RutaRespaldos
    try {
        if (Test-Path -LiteralPath $ruta) {
            $verif = Test-AclRespaldos -Ruta $ruta
            if ($verif.Valido) {
                $e.DirRespaldos = $ruta
                return $true
            }

            $contenido = @(Get-ChildItem -LiteralPath $ruta -Force)
            if ($contenido.Count -eq 0) {
                Write-Log -Nivel WARN -Mensaje "La carpeta de respaldos existía vacía con permisos incorrectos; se corrigen. Motivos: $($verif.Motivos -join ' ')"
                Set-AclRespaldos -Ruta $ruta
            }
            else {
                $nombreCuarentena = 'backups.sin-verificar-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
                $rutaCuarentena = [System.IO.Path]::Combine($e.DirDatos, $nombreCuarentena)
                Rename-Item -LiteralPath $ruta -NewName $nombreCuarentena -ErrorAction Stop
                Write-Log -Nivel WARN -Mensaje "La carpeta de respaldos tenía permisos incorrectos y contenido que no se puede verificar. Se movió a '$rutaCuarentena'. Nunca se usará para deshacer ni se borrará. Motivos: $($verif.Motivos -join ' ')"
                New-Item -ItemType Directory -Path $ruta -ErrorAction Stop | Out-Null
                Set-AclRespaldos -Ruta $ruta
            }
        }
        else {
            New-Item -ItemType Directory -Path $ruta -ErrorAction Stop | Out-Null
            Set-AclRespaldos -Ruta $ruta
        }

        $verif = Test-AclRespaldos -Ruta $ruta
        if (-not $verif.Valido) {
            Write-Log -Nivel ERROR -Mensaje "No se pudo proteger la carpeta de respaldos: $($verif.Motivos -join ' ')"
            return $false
        }
        $e.DirRespaldos = $ruta
        Write-Log -Nivel INFO -Mensaje "Carpeta de respaldos lista y protegida: $ruta"
        return $true
    }
    catch {
        Write-Log -Nivel ERROR -Mensaje "No se pudo preparar la carpeta de respaldos: $($_.Exception.Message)"
        return $false
    }
}
