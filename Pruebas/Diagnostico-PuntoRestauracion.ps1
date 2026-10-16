<#
.SYNOPSIS
    Diagnóstico: ¿por qué CreateRestorePoint por CIM no crea el punto y Checkpoint-Computer sí?
.DESCRIPTION
    SOLO PARA UNA MÁQUINA VIRTUAL: crea varios puntos de restauración reales. Con
    SystemRestorePointCreationFrequency = 0 prueba, una detrás de otra, estas variantes y dice cuáles
    crearon un punto (comparando SequenceNumber antes y después), cuánto tardó cada una y qué devolvió:
      1. Invoke-CimMethod (CIM), tipo MODIFY_SETTINGS (12) y evento BEGIN_SYSTEM_CHANGE (100)
      2. Invoke-CimMethod, tipo APPLICATION_INSTALL (0)
      3. Invoke-WmiMethod (WMI clásico, solo Windows PowerShell 5.1)
      4. Checkpoint-Computer (solo Windows PowerShell 5.1)
      5. Invoke-CimMethod otra vez, justo después de Checkpoint-Computer
    Al terminar restaura el valor original de la frecuencia (aunque falle). Los puntos creados quedan
    con la descripción "OptiLow diag N"; puedes borrarlos con la limpieza de disco de Windows.
    Ejecutar COMO ADMINISTRADOR en Windows PowerShell 5.1:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pruebas\Diagnostico-PuntoRestauracion.ps1
#>
$ErrorActionPreference = 'Stop'

Write-Host '=== Diagnóstico del punto de restauración ===' -ForegroundColor Cyan
Write-Host 'ESTE SCRIPT ES PARA UNA MÁQUINA VIRTUAL: crea varios puntos de restauración reales.' -ForegroundColor Yellow
if ((Read-Host 'Escribe SI (en mayúsculas) para continuar') -cne 'SI') { Write-Host 'Cancelado.'; exit 0 }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Ejecuta este script como administrador.' -ForegroundColor Red
    exit 1
}

$clave = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$nombre = 'SystemRestorePointCreationFrequency'
$existia = $null -ne (Get-ItemProperty -Path $clave -Name $nombre -ErrorAction SilentlyContinue)
$original = $null
if ($existia) { $original = (Get-ItemProperty -Path $clave -Name $nombre).$nombre }
Write-Host "Frecuencia original: $(if ($existia) { $original } else { '(no existe)' })"

function Get-Secuencias {
    return @(Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore | ForEach-Object { [int64]$_.SequenceNumber })
}

$resultados = New-Object System.Collections.ArrayList
function Probar {
    param([string]$Titulo, [scriptblock]$Accion)
    $antes = @(Get-Secuencias)
    $max = -1
    if ($antes.Count -gt 0) { $max = ($antes | Measure-Object -Maximum).Maximum }
    $devuelto = ''
    $error1 = ''
    $reloj = [System.Diagnostics.Stopwatch]::StartNew()
    try { $devuelto = & $Accion } catch { $error1 = $_.Exception.Message }
    $reloj.Stop()
    Start-Sleep -Seconds 2
    $nuevos = @(Get-Secuencias | Where-Object { $_ -gt $max })
    $fila = [pscustomobject]@{
        Variante  = $Titulo
        Creado    = ($nuevos.Count -gt 0)
        Segundos  = [math]::Round($reloj.Elapsed.TotalSeconds, 1)
        Devuelto  = "$devuelto"
        Error     = $error1
    }
    [void]$resultados.Add($fila)
    $color = if ($fila.Creado) { 'Green' } else { 'Yellow' }
    Write-Host ("  {0}: creado={1}, {2}s, devuelto='{3}' {4}" -f $Titulo, $fila.Creado, $fila.Segundos, $fila.Devuelto, $fila.Error) -ForegroundColor $color
}

try {
    New-ItemProperty -Path $clave -Name $nombre -PropertyType DWord -Value 0 -Force | Out-Null
    Write-Host "Frecuencia ajustada a 0. Puntos existentes: $((Get-Secuencias) -join ', ')"

    Probar '1. CIM tipo 12 / evento 100' {
        $r = Invoke-CimMethod -Namespace 'root/default' -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{ Description = 'OptiLow diag 1'; RestorePointType = [uint32]12; EventType = [uint32]100 }
        "ReturnValue=$($r.ReturnValue)"
    }
    Probar '2. CIM tipo 0 / evento 100' {
        $r = Invoke-CimMethod -Namespace 'root/default' -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{ Description = 'OptiLow diag 2'; RestorePointType = [uint32]0; EventType = [uint32]100 }
        "ReturnValue=$($r.ReturnValue)"
    }
    if (Get-Command Invoke-WmiMethod -ErrorAction SilentlyContinue) {
        Probar '3. WMI clásico (Invoke-WmiMethod)' {
            # Invoke-WmiMethod pasa los argumentos en el orden que devuelve WMI (Description, EventType, RestorePointType),
            # no en el de la documentación: por eso el evento (100) va antes que el tipo (12).
            $r = Invoke-WmiMethod -Namespace 'root\default' -Class SystemRestore -Name CreateRestorePoint -ArgumentList 'OptiLow diag 3', 100, 12
            "ReturnValue=$($r.ReturnValue)"
        }
    }
    else { Write-Host '  3. Invoke-WmiMethod no existe aquí; se omite.' }
    if (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue) {
        Probar '4. Checkpoint-Computer' {
            Checkpoint-Computer -Description 'OptiLow diag 4' -RestorePointType MODIFY_SETTINGS -WarningAction SilentlyContinue -WarningVariable av -ErrorAction Stop
            "avisos=" + (@($av) -join ' | ')
        }
        Probar '5. CIM otra vez, justo después de Checkpoint-Computer' {
            $r = Invoke-CimMethod -Namespace 'root/default' -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{ Description = 'OptiLow diag 5'; RestorePointType = [uint32]12; EventType = [uint32]100 }
            "ReturnValue=$($r.ReturnValue)"
        }
    }
    else { Write-Host '  4-5. Checkpoint-Computer no existe aquí; se omiten.' }
}
finally {
    if ($existia) { New-ItemProperty -Path $clave -Name $nombre -PropertyType DWord -Value $original -Force | Out-Null }
    else { Remove-ItemProperty -Path $clave -Name $nombre -ErrorAction SilentlyContinue }
    Write-Host 'Frecuencia restaurada a su valor original.'
}

Write-Host ''
Write-Host '=== Resumen (copia y pega esto) ===' -ForegroundColor Cyan
$resultados | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host 'Puntos que existen ahora:'
Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore | Select-Object SequenceNumber, Description, CreationTime | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
