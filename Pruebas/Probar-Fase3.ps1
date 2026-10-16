<#
.SYNOPSIS
    Autopruebas de la Fase 3 (motor de optimizaciones y modo consola) con los tweaks reales.
.DESCRIPTION
    SOLO PARA UNA MÁQUINA VIRTUAL. Aplica y deshace de verdad las tres optimizaciones registradas
    (transparencias, servicios de telemetría y tareas de telemetría) y ejecuta OptiLow.ps1 como proceso
    hijo para comprobar parámetros y códigos de salida. Cada prueba hace: aplicar -> comprobar ->
    aplicar otra vez (sin cambios) -> deshacer con el journal -> verificar que quedó como estaba.
    Este script NUNCA lo carga el cargador (está fuera de Core/, Modules/ y Tweaks/).
    Ejecutar en Windows PowerShell 5.1 abierta COMO ADMINISTRADOR:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pruebas\Probar-Fase3.ps1
#>
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

Write-Host ''
Write-Host '=== Autopruebas de la Fase 3 de OptiLow ===' -ForegroundColor Cyan
Write-Host 'ESTE SCRIPT ES PARA UNA MÁQUINA VIRTUAL.' -ForegroundColor Yellow
Write-Host 'Cambia de verdad (y luego deshace) las transparencias de Windows, el inicio de los servicios DiagTrack y'
Write-Host 'dmwappushservice y las tareas programadas de telemetría. Haz antes un snapshot de la VM.'
if ((Read-Host 'Escribe SI (en mayúsculas) para continuar') -cne 'SI') { Write-Host 'Cancelado. No se hizo ningún cambio.'; exit 0 }

. (Join-Path $raiz 'Core\Loader.ps1')
Import-OptiLowCore -Raiz $raiz
if (-not (Test-EsAdministrador)) { Write-Host 'Ejecuta este script desde una consola abierta como administrador.' -ForegroundColor Red; exit 1 }
Initialize-OptiLowRutas -Raiz $raiz
Initialize-OptiLowLog -Destino Consola
if (-not (Initialize-CarpetaRespaldos)) { Write-Host 'No se pudo preparar la carpeta de respaldos.' -ForegroundColor Red; exit 1 }
$extras = Import-OptiLowExtras -Raiz $raiz

$script:bien = 0
$script:mal = 0
function T { param([string]$Nombre, [bool]$Condicion)
    if ($Condicion) { $script:bien++; Write-Host "  OK     $Nombre" -ForegroundColor Green }
    else { $script:mal++; Write-Host "  FALLA  $Nombre" -ForegroundColor Red } }
function Info { param([string]$Texto) Write-Host "  (info) $Texto" -ForegroundColor DarkGray }
function Seccion { param([string]$Texto) Write-Host ''; Write-Host "== $Texto ==" -ForegroundColor Cyan }
function Codigo { param($Salida) return [int](@($Salida)[-1]) }

$tareas = @(
    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
    @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
    @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector')
)

function Add-VolcadoClave {
    # Vuelca TODOS los valores (nombre, tipo y dato completo) de una clave y de sus subclaves, ordenados.
    param($Clave, [string]$Ruta, $Lineas)
    foreach ($n in @($Clave.GetValueNames() | Sort-Object)) {
        $tipo = $Clave.GetValueKind($n)
        $v = $Clave.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($v -is [byte[]]) { $repr = 'bytes:' + [Convert]::ToBase64String($v) }
        elseif ($v -is [string[]]) { $repr = 'multi:' + ($v -join '|') }
        else { $repr = [string]$v }
        [void]$Lineas.Add("registro $Ruta | $n ($tipo) = $repr")
    }
    foreach ($sub in @($Clave.GetSubKeyNames() | Sort-Object)) {
        $k = $Clave.OpenSubKey($sub)
        if ($k) { try { Add-VolcadoClave -Clave $k -Ruta "$Ruta\$sub" -Lineas $Lineas } finally { $k.Dispose() } }
    }
}

function Test-IgualInstantanea {
    # Compara dos instantáneas y, si difieren, imprime las líneas que cambian (qué propiedad, antes y después)
    param([string]$Esperado, [string]$Actual, [string]$Nombre)
    if ($Esperado -ceq $Actual) { T $Nombre $true; return }
    T $Nombre $false
    $dif = Compare-Object -ReferenceObject ($Esperado -split "`n") -DifferenceObject ($Actual -split "`n") -CaseSensitive
    foreach ($d in $dif) {
        $lado = 'DESPUÉS'; if ($d.SideIndicator -eq '<=') { $lado = 'ANTES  ' }
        $txt = [string]$d.InputObject
        if ($txt.Length -gt 230) { $txt = $txt.Substring(0, 230) + '...' }
        Write-Host "         $lado : $txt" -ForegroundColor Yellow
    }
}

function Get-Instantanea {
    # Configuración cruda de todo lo que tocan los tres tweaks (para comparar antes y después).
    # NO incluye el estado en ejecución de los servicios (Running/Stopped): los tweaks no lo cambian ni lo restauran.
    $partes = New-Object System.Collections.ArrayList
    $v = Get-RegistroEstado -Ruta 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Nombre 'EnableTransparency'
    [void]$partes.Add("transparencia: clave=$($v.ClaveExiste) valor=$($v.ValorExiste) tipo=$($v.Tipo) dato=$($v.Dato)")
    foreach ($n in 'DiagTrack', 'dmwappushservice') {
        $s = Get-ServicioEstado -Nombre $n
        [void]$partes.Add("servicio ${n}: existe=$($s.Existe) start=$($s.Start) retrasado=$(if ($null -eq $s.Delayed) { '(no existe el valor)' } else { $s.Delayed })")
        # Volcado completo de la clave del servicio (valores y subclaves: TriggerInfo, Security, Parameters...)
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
        try {
            $k = $base.OpenSubKey("SYSTEM\CurrentControlSet\Services\$n")
            if ($k) { try { Add-VolcadoClave -Clave $k -Ruta "Services\$n" -Lineas $partes } finally { $k.Dispose() } }
        }
        finally { $base.Dispose() }
    }
    foreach ($t in $tareas) {
        $e = Get-TareaEstado -Ruta $t[0] -Nombre $t[1]
        [void]$partes.Add("tarea $($t[1]): existe=$($e.Existe) habilitada=$($e.Habilitada)")
    }
    return ($partes -join "`n")
}

function Get-NumSesiones { return @(Get-JournalSesiones).Count }

$original = Get-Instantanea
function Show-EstadoEjecucion { param([string]$Cuando) foreach ($n in 'DiagTrack', 'dmwappushservice') { $sv = Get-Service -Name $n -ErrorAction SilentlyContinue; if ($sv) { Info ("$Cuando - $n en ejecución: $($sv.Status) (solo informativo: el tweak no lo cambia ni lo restaura)") } } }
Show-EstadoEjecucion -Cuando 'Al empezar'

Seccion '1. Registro de optimizaciones'
T 'Se cargaron los dos archivos de Tweaks/ sin errores' ($extras.Cargados -eq 2 -and $extras.Fallidos -eq 0)
T 'Hay 3 optimizaciones registradas' (@(Get-Tweak).Count -eq 3)
T 'La plantilla no se cargó' (-not (Get-Tweak -Id 'ejemplo-id-del-tweak'))
Info 'Tareas de telemetría que existen en ESTA versión de Windows (rutas por verificar):'
foreach ($t in $tareas) {
    $e = Get-TareaEstado -Ruta $t[0] -Nombre $t[1]
    Info ("  {0}{1}: {2}" -f $t[0], $t[1], $(if ($e.Existe) { "existe, habilitada=$($e.Habilitada)" } else { 'NO existe' }))
}
Info 'Estados iniciales:'
foreach ($d in Get-Tweak) { Info ("  {0}: {1}" -f $d.Id, (Get-TweakEstado -Id $d.Id).Estado) }

# ---------------------------------------------------------------------------------------------
foreach ($id in 'efectos-transparencia-off', 'telemetria-servicios-off', 'telemetria-tareas-off') {
    Seccion "2. Ciclo completo: $id"
    $antes = Get-Instantanea
    $estadoPrevio = (Get-TweakEstado -Id $id).Estado
    Info "Estado previo: $estadoPrevio"
    $sesionesAntes = Get-NumSesiones

    $c = Codigo (Invoke-AplicarConsola -Ids $id -SinPreguntar -SinPuntoRestauracion)
    T 'Aplicar termina con código 0' ($c -eq 0)
    $estado = (Get-TweakEstado -Id $id).Estado
    if ($estadoPrevio -eq 'NoAplica') { T 'No aplica en esta versión: sigue NoAplica y no creó sesión' ($estado -eq 'NoAplica' -and (Get-NumSesiones) -eq $sesionesAntes) }
    else {
        T 'Comprobar dice Aplicado' ($estado -eq 'Aplicado')
        T 'Se creó una sola sesión nueva en el journal' ((Get-NumSesiones) -eq ($sesionesAntes + 1))
        $sesion = Get-JournalSesiones | Select-Object -First 1
        T 'Las entradas guardan el Id del tweak' (@($sesion.Tweaks) -contains $id)

        $n = Get-NumSesiones
        $c = Codigo (Invoke-AplicarConsola -Ids $id -SinPreguntar -SinPuntoRestauracion)
        T 'Aplicar otra vez: código 0 y no crea otra sesión (no hay nada que aplicar)' ($c -eq 0 -and (Get-NumSesiones) -eq $n)

        $c = Codigo (Invoke-DeshacerConsola -SinPreguntar)
        T 'Deshacer termina con código 0' ($c -eq 0)
    }
    T 'Comprobar vuelve al estado previo' ((Get-TweakEstado -Id $id).Estado -eq $estadoPrevio)
    Test-IgualInstantanea -Esperado $antes -Actual (Get-Instantanea) -Nombre 'La configuración quedó exactamente como estaba'
}

# ---------------------------------------------------------------------------------------------
Seccion '3. Las tres juntas: una sola sesión y aviso de reinicio'
$n0 = Get-NumSesiones
[void](Start-JournalSesion -Nueva)
$lote = Invoke-TweaksLote -Ids 'efectos-transparencia-off', 'telemetria-servicios-off', 'telemetria-tareas-off'
Info ("Resultados: " + (($lote.Resultados | ForEach-Object { "$($_.Id)=$($_.Estado)" }) -join ' | '))
T 'Ninguna falló' (@($lote.Resultados | Where-Object { @('Fallido', 'Parcial') -contains $_.Estado }).Count -eq 0)
T 'El resumen pide REINICIAR (por los servicios)' ($lote.Requiere -eq 'Reiniciar' -and (@($lote.TweaksQueRequieren).Id -contains 'telemetria-servicios-off'))
T 'Una sola sesión nueva' ((Get-NumSesiones) -eq ($n0 + 1))
$sesion = Get-JournalSesiones | Select-Object -First 1
T 'La sesión lista los tres tweaks' (@($sesion.Tweaks).Count -ge 2)
Show-ResumenConsola -Lote $lote
Show-EstadoEjecucion -Cuando 'Tras aplicar'
$c = Codigo (Invoke-DeshacerConsola -SinPreguntar)
T 'Deshacer la sesión: código 0' ($c -eq 0)
Test-IgualInstantanea -Esperado $original -Actual (Get-Instantanea) -Nombre 'Todo quedó como al principio'

# ---------------------------------------------------------------------------------------------
Seccion '4. OptiLow.ps1 como proceso hijo (parámetros y códigos de salida)'
$ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script = Join-Path $raiz 'OptiLow.ps1'
function Invoke-Hijo {
    param([string[]]$Argumentos)
    $salida = & $ps -NoProfile -STA -ExecutionPolicy Bypass -File $script @Argumentos 2>$null
    return [pscustomobject]@{ Codigo = $LASTEXITCODE; Salida = (@($salida) -join "`n") }
}
$h = Invoke-Hijo @('-Listar')
T '-Listar: código 0 y muestra los tres Ids' ($h.Codigo -eq 0 -and $h.Salida -match 'efectos-transparencia-off' -and $h.Salida -match 'telemetria-servicios-off' -and $h.Salida -match 'telemetria-tareas-off')
$h = Invoke-Hijo @('-ListarSesiones')
T '-ListarSesiones: código 0' ($h.Codigo -eq 0)
$h = Invoke-Hijo @('-Aplicar', 'no-existe', '-SinPreguntar')
T '-Aplicar con un Id inexistente: código 1 y no aplica nada' ($h.Codigo -eq 1)
$h = Invoke-Hijo @('-Aplicar', 'recomendados', '-SinPreguntar')
T '-Aplicar recomendados: código 1 (llega en la fase 4)' ($h.Codigo -eq 1 -and $h.Salida -match 'fase 4')
$h = Invoke-Hijo @('-Sesion', 'x')
T '-Sesion sin -Deshacer: código 1' ($h.Codigo -eq 1)
$h = Invoke-Hijo @('-Deshacer', '-Sesion', 'no-existe', '-SinPreguntar')
T '-Deshacer con una sesión inexistente: código 1' ($h.Codigo -eq 1)
$h = Invoke-Hijo @('-Aplicar', 'efectos-transparencia-off,telemetria-tareas-off', '-SinPreguntar', '-SinPuntoRestauracion')
T '-Aplicar con varios Ids separados por comas, sin preguntar: código 0' ($h.Codigo -eq 0)
T 'Quedó aplicado' ((Get-TweakEstado -Id 'efectos-transparencia-off').Estado -eq 'Aplicado')
$h = Invoke-Hijo @('-Deshacer', '-SinPreguntar')
T '-Deshacer sin Id: deshace la última sesión (código 0)' ($h.Codigo -eq 0)
Test-IgualInstantanea -Esperado $original -Actual (Get-Instantanea) -Nombre 'Todo quedó como al principio'

# ---------------------------------------------------------------------------------------------
Seccion '5. Con punto de restauración real (opcional)'
if ((Read-Host 'Escribe SI para probar -Aplicar con punto de restauración real (otra cosa = omitir)') -ceq 'SI') {
    $h = Invoke-Hijo @('-Aplicar', 'efectos-transparencia-off', '-SinPreguntar')
    Info "Código de salida: $($h.Codigo) (0 = punto creado y aplicado; 2 = el punto no se pudo crear y se canceló, que es lo correcto con -SinPreguntar)"
    Info (($h.Salida -split "`n" | Where-Object { $_ -match 'restauración' } | Select-Object -First 4) -join ' | ')
    T 'El resultado es 0 o 2 (nunca aplica sin punto con -SinPreguntar)' (@(0, 2) -contains $h.Codigo)
    if ($h.Codigo -eq 2) { T 'Si se canceló, no se aplicó nada' ((Get-TweakEstado -Id 'efectos-transparencia-off').Estado -eq 'Pendiente') }
    else { [void](Invoke-Hijo @('-Deshacer', '-SinPreguntar')) }
    Test-IgualInstantanea -Esperado $original -Actual (Get-Instantanea) -Nombre 'Todo quedó como al principio'
}
else { Info 'Omitido.' }

Write-Host ''
$color = 'Green'; if ($script:mal -gt 0) { $color = 'Red' }
Write-Host "Resultado: $($script:bien) bien, $($script:mal) con fallos." -ForegroundColor $color
exit $(if ($script:mal -eq 0) { 0 } else { 1 })
