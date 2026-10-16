<#
.SYNOPSIS
    Autopruebas de la Fase 2 (journal, registro, JSON, archivos, servicios, tareas, energía, punto de restauración).
.DESCRIPTION
    SOLO PARA UNA MÁQUINA VIRTUAL. Crea y borra un servicio ficticio ('OptiLowPrueba'), una tarea
    programada ficticia, claves en HKLM\SOFTWARE\OptiLowPrueba* y HKCU\Software\OptiLowPrueba*, y
    archivos temporales; cambia el plan de energía; y (opcional) crea puntos de restauración reales.
    Cada prueba hace: aplicar -> comprobar -> deshacer con el journal -> verificar que quedó como estaba.
    Este script NUNCA lo carga el cargador (está fuera de Core/, Modules/ y Tweaks/).
    Ejecutar en una consola de Windows PowerShell 5.1 abierta COMO ADMINISTRADOR:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pruebas\Probar-Fase2.ps1
#>
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

Write-Host ''
Write-Host '=== Autopruebas de la Fase 2 de OptiLow ===' -ForegroundColor Cyan
Write-Host 'ESTE SCRIPT ES PARA UNA MÁQUINA VIRTUAL.' -ForegroundColor Yellow
Write-Host 'Crea y borra un servicio ficticio (OptiLowPrueba), una tarea programada ficticia, claves de registro'
Write-Host 'de prueba en HKLM y HKCU, cambia el plan de energía y puede crear puntos de restauración reales.'
Write-Host 'Hazlo en una VM con un snapshot reciente, nunca en tu equipo principal.'
Write-Host ''
$resp = Read-Host 'Escribe SI (en mayúsculas) para continuar'
if ($resp -cne 'SI') {
    Write-Host 'Cancelado. No se hizo ningún cambio.'
    exit 0
}

. (Join-Path $raiz 'Core\Loader.ps1')
Import-OptiLowCore -Raiz $raiz
if (-not (Test-EsAdministrador)) {
    Write-Host 'Ejecuta este script desde una consola abierta como administrador.' -ForegroundColor Red
    exit 1
}
Initialize-OptiLowRutas -Raiz $raiz
Initialize-OptiLowLog -Destino Consola
$global:OptiLow.Depurar = $true
if (-not (Initialize-CarpetaRespaldos)) {
    Write-Host 'No se pudo preparar la carpeta de respaldos; no se puede continuar.' -ForegroundColor Red
    exit 1
}

$script:bien = 0
$script:mal = 0
function T {
    param([string]$Nombre, [bool]$Condicion)
    if ($Condicion) { $script:bien++; Write-Host "  OK     $Nombre" -ForegroundColor Green }
    else { $script:mal++; Write-Host "  FALLA  $Nombre" -ForegroundColor Red }
}
function Info { param([string]$Texto) Write-Host "  (info) $Texto" -ForegroundColor DarkGray }
function Seccion { param([string]$Texto) Write-Host ''; Write-Host "== $Texto ==" -ForegroundColor Cyan }

$claveHklm = 'HKLM:\SOFTWARE\OptiLowPrueba'
$claveHklm64 = 'HKLM:\SOFTWARE\OptiLowPrueba64'
$claveHkcu = 'HKCU:\Software\OptiLowPrueba'
$nombreSvc = 'OptiLowPrueba'
$nombreTarea = 'OptiLowPrueba'
$dirTmp = Join-Path $env:TEMP ('OptiLowPrueba_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $dirTmp | Out-Null

function Remove-ClavePrueba {
    # Borra una clave de prueba (vista de 64 bits). Solo se usa con las claves OptiLowPrueba*.
    param([string]$Ruta)
    $sub = $Ruta -replace '^(HKLM|HKCU):\\', ''
    $hive = 'CurrentUser'
    if ($Ruta.StartsWith('HKLM')) { $hive = 'LocalMachine' }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, 'Registry64')
    try { $base.DeleteSubKeyTree($sub, $false) } finally { $base.Dispose() }
}

function Undo-Actual {
    # Deshace exactamente la sesión activa de este script (no "la última", que podría ser otra).
    $id = $global:OptiLow.Journal.Id
    return (Undo-JournalSesion -Id $id)
}

function Test-RegQuery {
    # Devuelve $true si 'reg query' encuentra la clave. Se ejecuta con cmd para no mezclar stderr en 5.1.
    param([string]$Clave, [string]$Vista)
    & cmd.exe /c "reg.exe query ""$Clave"" /reg:$Vista >nul 2>nul"
    return ($LASTEXITCODE -eq 0)
}

try {
    # ---------------------------------------------------------------------------------------
    Seccion '1. Carpeta de respaldos protegida'
    $ruta = $global:OptiLow.DirRespaldos
    $v = Test-AclRespaldos -Ruta $ruta
    T 'Test-AclRespaldos válido' $v.Valido
    $acl = Get-Acl -LiteralPath $ruta
    T 'Propietario = Administradores (S-1-5-32-544)' ($acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544')
    T 'No hereda de ProgramData' $acl.AreAccessRulesProtected
    Info 'Permisos (debe verse solo Administradores y SYSTEM):'
    & icacls.exe $ruta | ForEach-Object { Info $_ }

    # ---------------------------------------------------------------------------------------
    Seccion '2. Registro: seis tipos, idempotencia y deshacer (HKLM)'
    Remove-ClavePrueba -Ruta $claveHklm
    [void](Start-JournalSesion -Nueva)
    T 'DWord'        ((Set-RegistroValor -Ruta "$claveHklm\Sub" -Nombre 'd' -Valor 4000000000 -Tipo DWord) -eq 'Cambiado')
    T 'QWord'        ((Set-RegistroValor -Ruta "$claveHklm\Sub" -Nombre 'q' -Valor '18446744073709551615' -Tipo QWord) -eq 'Cambiado')
    T 'String'       ((Set-RegistroValor -Ruta "$claveHklm\Sub" -Nombre 's' -Valor 'hola ñandú' -Tipo String) -eq 'Cambiado')
    T 'ExpandString' ((Set-RegistroValor -Ruta "$claveHklm\Sub" -Nombre 'x' -Valor '%SystemRoot%\x' -Tipo ExpandString) -eq 'Cambiado')
    T 'MultiString'  ((Set-RegistroValor -Ruta "$claveHklm\Sub" -Nombre 'm' -Valor @('a', 'b') -Tipo MultiString) -eq 'Cambiado')
    T 'Binary'       ((Set-RegistroValor -Ruta "$claveHklm\Sub" -Nombre 'b' -Valor ([byte[]](1, 2, 255)) -Tipo Binary) -eq 'Cambiado')
    T 'Idempotente (sin cambios)' ((Set-RegistroValor -Ruta "$claveHklm\Sub" -Nombre 'd' -Valor 4000000000 -Tipo DWord) -eq 'SinCambios')
    $e = Get-RegistroEstado -Ruta "$claveHklm\Sub" -Nombre 'x'
    T 'ExpandString guardado sin expandir' ($e.Dato -ceq '%SystemRoot%\x')
    $r = Undo-Actual
    T 'Deshacer completo' ($r.Estado -eq 'Restaurado')
    T 'Las claves creadas por nosotros ya no existen' (-not (Get-RegistroEstado -Ruta $claveHklm -Nombre 'd').ClaveExiste)

    Seccion '3. Registro: valores previos con otro tipo se restauran'
    [void](Set-RegistroValor -Ruta $claveHklm -Nombre 'previo' -Valor '%SystemRoot%\orig' -Tipo ExpandString)   # preparación (queda en una sesión que se deshace al final)
    $sesionPrep = $global:OptiLow.Journal.Id
    [void](Start-JournalSesion -Nueva)
    [void](Set-RegistroValor -Ruta $claveHklm -Nombre 'previo' -Valor 'otro' -Tipo String)
    [void](Undo-Actual)
    $e = Get-RegistroEstado -Ruta $claveHklm -Nombre 'previo'
    T 'ExpandString original recuperado' ($e.Tipo -eq 'ExpandString' -and $e.Dato -ceq '%SystemRoot%\orig')
    [void](Undo-JournalSesion -Id $sesionPrep)
    T 'Clave de preparación eliminada' (-not (Get-RegistroEstado -Ruta $claveHklm -Nombre 'previo').ClaveExiste)

    # ---------------------------------------------------------------------------------------
    Seccion '4. Registro de 64 bits (sin redirección a WOW6432Node)'
    Remove-ClavePrueba -Ruta $claveHklm64
    [void](Start-JournalSesion -Nueva)
    [void](Set-RegistroValor -Ruta $claveHklm64 -Nombre 'v' -Valor 1 -Tipo DWord)
    T 'Visible en la vista de 64 bits' (Test-RegQuery -Clave 'HKLM\SOFTWARE\OptiLowPrueba64' -Vista 64)
    T 'NO está en WOW6432Node' (-not (Test-RegQuery -Clave 'HKLM\SOFTWARE\WOW6432Node\OptiLowPrueba64' -Vista 64))
    $ps32 = Join-Path $env:windir 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $ps32) {
        $cmd = ". '$raiz\Core\Loader.ps1'; Import-OptiLowCore -Raiz '$raiz'; " +
        "$([char]36)e = Get-RegistroEstado -Ruta '$claveHklm64' -Nombre 'v'; " +
        "'64bits=' + [Environment]::Is64BitProcess + ';existe=' + $([char]36)e.ValorExiste + ';dato=' + $([char]36)e.Dato"
        $salida = (& $ps32 -NoProfile -ExecutionPolicy Bypass -Command $cmd) -join ' '
        Info "PowerShell de 32 bits dice: $salida"
        T 'Desde PowerShell de 32 bits también lo lee en la vista de 64' ($salida -match '64bits=False' -and $salida -match 'existe=True' -and $salida -match 'dato=1')
    }
    else { Info 'No hay PowerShell de 32 bits (SysWOW64); se omite esa comprobación.' }
    [void](Undo-Actual)
    T 'Deshacer limpia la clave' (-not (Get-RegistroEstado -Ruta $claveHklm64 -Nombre 'v').ClaveExiste)

    # ---------------------------------------------------------------------------------------
    Seccion '5. JSON: restaurar solo la clave que cambiamos'
    $j = Join-Path $dirTmp 'settings.json'
    [IO.File]::WriteAllText($j, '{"a":1,"enableHardwareAcceleration":true,"anidado":{"x":"y"}}', (New-Object Text.UTF8Encoding($false)))
    [void](Start-JournalSesion -Nueva)
    T 'Cambiar clave existente' ((Set-JsonValor -Ruta $j -Clave 'enableHardwareAcceleration' -Valor $false) -eq 'Cambiado')
    T 'Idempotente' ((Set-JsonValor -Ruta $j -Clave 'enableHardwareAcceleration' -Valor $false) -eq 'SinCambios')
    T 'Clave nueva anidada' ((Set-JsonValor -Ruta $j -Clave 'n1', 'n2' -Valor 'v') -eq 'Cambiado')
    T 'Archivo inexistente = NoAplica' ((Set-JsonValor -Ruta (Join-Path $dirTmp 'no.json') -Clave 'k' -Valor 1) -eq 'NoAplica')
    $o = [IO.File]::ReadAllText($j) | ConvertFrom-Json
    $o.a = 99
    Add-Member -InputObject $o -NotePropertyName extra -NotePropertyValue 'del usuario'
    [IO.File]::WriteAllText($j, ($o | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))   # el "usuario" cambia otras cosas
    [void](Undo-Actual)
    $o = [IO.File]::ReadAllText($j) | ConvertFrom-Json
    T 'Clave restaurada a true' ($o.enableHardwareAcceleration -eq $true)
    T 'Cambios posteriores del usuario conservados' ($o.a -eq 99 -and $o.extra -eq 'del usuario')
    T 'Objetos intermedios que creamos eliminados' (-not $o.PSObject.Properties['n1'])

    Seccion '6. Archivos: copia de respaldo, hash y deshacer'
    $f = Join-Path $dirTmp 'a.txt'; Set-Content -Path $f -Value 'original' -Encoding UTF8
    $f2 = Join-Path $dirTmp 'nuevo.txt'
    [void](Start-JournalSesion -Nueva)
    T 'Reescribir' ((Write-ArchivoTexto -Ruta $f -Contenido 'cambiado ñ') -eq 'Cambiado')
    T 'Idempotente' ((Write-ArchivoTexto -Ruta $f -Contenido 'cambiado ñ') -eq 'SinCambios')
    T 'Crear archivo nuevo' ((Write-ArchivoTexto -Ruta $f2 -Contenido 'x') -eq 'Cambiado')
    [void](Undo-Actual)
    T 'Contenido original restaurado' ((Get-Content -Path $f -Raw).Trim() -eq 'original')
    T 'Archivo creado por nosotros eliminado' (-not (Test-Path $f2))
    [void](Start-JournalSesion -Nueva)
    [void](Write-ArchivoTexto -Ruta $f2 -Contenido 'x')
    Set-Content -Path $f2 -Value 'cambiado por el usuario'
    [void](Undo-Actual)
    T 'No se borra un archivo creado por nosotros si cambió después' (Test-Path $f2)

    # ---------------------------------------------------------------------------------------
    Seccion '7. Servicios (servicio ficticio OptiLowPrueba)'
    & sc.exe delete $nombreSvc | Out-Null
    & sc.exe create $nombreSvc binPath= 'C:\Windows\System32\cmd.exe' start= delayed-auto | Out-Null
    T 'Servicio ficticio creado' ($LASTEXITCODE -eq 0)
    T 'Estado inicial AutomaticDelayed' ((Get-ServicioEstado -Nombre $nombreSvc).Inicio -eq 'AutomaticDelayed')
    [void](Start-JournalSesion -Nueva)
    T 'A Disabled' ((Set-ServicioInicio -Nombre $nombreSvc -Inicio Disabled) -eq 'Cambiado')
    T 'Queda Disabled' ((Get-ServicioEstado -Nombre $nombreSvc).Inicio -eq 'Disabled')
    T 'Idempotente' ((Set-ServicioInicio -Nombre $nombreSvc -Inicio Disabled) -eq 'SinCambios')
    T 'A Manual' ((Set-ServicioInicio -Nombre $nombreSvc -Inicio Manual) -eq 'Cambiado')
    $res = Set-ServicioInicio -Nombre $nombreSvc -Inicio Automatic
    T 'A Automatic (limpia el inicio retrasado)' ($res -eq 'Cambiado' -and (Get-ServicioEstado -Nombre $nombreSvc).Inicio -eq 'Automatic')
    $res = Set-ServicioInicio -Nombre $nombreSvc -Inicio AutomaticDelayed
    T 'A AutomaticDelayed' ($res -eq 'Cambiado' -and (Get-ServicioEstado -Nombre $nombreSvc).Inicio -eq 'AutomaticDelayed')
    [void](Set-ServicioInicio -Nombre $nombreSvc -Inicio Disabled)
    $r = Undo-Actual
    $est = Get-ServicioEstado -Nombre $nombreSvc
    T 'Deshacer completo' ($r.Estado -eq 'Restaurado')
    T 'Vuelve a AutomaticDelayed (Start y DelayedAutostart originales)' ($est.Inicio -eq 'AutomaticDelayed')
    T 'Servicio inexistente = NoAplica' ((Set-ServicioInicio -Nombre 'OptiLowNoExiste' -Inicio Disabled) -eq 'NoAplica')
    Info 'Intento sobre un servicio protegido (el resultado depende de la versión de Windows; no es un fallo si cambia):'
    $prot = Get-ServicioEstado -Nombre 'WaaSMedicSvc'
    if ($prot.Existe) {
        [void](Start-JournalSesion -Nueva)
        $res = Set-ServicioInicio -Nombre 'WaaSMedicSvc' -Inicio Disabled
        Info "WaaSMedicSvc -> $res (si es 'Fallido' debe verse un error claro con el nombre; la prueba sigue)"
        [void](Undo-Actual)
    }
    else { Info 'WaaSMedicSvc no existe en esta versión de Windows.' }
    & sc.exe delete $nombreSvc | Out-Null

    # ---------------------------------------------------------------------------------------
    Seccion '8. Tareas programadas (tarea ficticia) y restauración parcial'
    Unregister-ScheduledTask -TaskName $nombreTarea -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $nombreTarea -Action (New-ScheduledTaskAction -Execute 'cmd.exe') -Trigger (New-ScheduledTaskTrigger -Daily -At 3am) | Out-Null
    [void](Start-JournalSesion -Nueva)
    T 'Desactivar' ((Disable-TareaProgramada -Ruta '\' -Nombre $nombreTarea) -eq 'Cambiado')
    T 'Otra vez = SinCambios' ((Disable-TareaProgramada -Ruta '\' -Nombre $nombreTarea) -eq 'SinCambios')
    T 'Tarea que no existe = NoAplica (sin error)' ((Disable-TareaProgramada -Ruta '\Microsoft\Windows\NoExiste\' -Nombre 'Nada') -eq 'NoAplica')
    [void](Undo-Actual)
    T 'Vuelve a estar habilitada' ((Get-TareaEstado -Ruta '\' -Nombre $nombreTarea).Habilitada)
    Info 'Restauración parcial: se aplican una tarea y un valor de registro y se borra la tarea antes de deshacer.'
    [void](Start-JournalSesion -Nueva)
    [void](Disable-TareaProgramada -Ruta '\' -Nombre $nombreTarea)
    [void](Set-RegistroValor -Ruta $claveHkcu -Nombre 'p' -Valor 1 -Tipo DWord)
    Unregister-ScheduledTask -TaskName $nombreTarea -Confirm:$false
    $idParcial = $global:OptiLow.Journal.Id
    $r = Undo-Actual
    T 'Estado RestauradoParcial' ($r.Estado -eq 'RestauradoParcial')
    T 'Indica la entrada fallida (la tarea)' (@($r.Fallidas).Count -eq 1 -and $r.Fallidas[0].Tipo -eq 'Tarea')
    T 'El resto sí se restauró (clave HKCU eliminada)' (-not (Get-RegistroEstado -Ruta $claveHkcu -Nombre 'p').ClaveExiste)
    $s = Get-JournalSesiones | Where-Object { $_.Id -eq $idParcial }
    T 'El archivo del journal quedó marcado RestauradoParcial' ($s.Estado -eq 'RestauradoParcial')

    # ---------------------------------------------------------------------------------------
    Seccion '9. Plan de energía'
    $planes = @(Get-PlanesEnergia)
    $activo = Get-PlanEnergiaActivo
    Info "Planes: $(($planes | ForEach-Object { $_.Nombre }) -join ', ') | activo: $($activo.Nombre)"
    T 'Plan activo ya activo = SinCambios' ((Set-PlanEnergia -Guid $activo.Guid) -eq 'SinCambios')
    T 'Plan inexistente = NoAplica (con aviso)' ((Set-PlanEnergia -Guid '00000000-1111-2222-3333-444444444444') -eq 'NoAplica')
    $otro = $planes | Where-Object { -not $_.Activo } | Select-Object -First 1
    if ($otro) {
        [void](Start-JournalSesion -Nueva)
        T "Cambiar a '$($otro.Nombre)'" ((Set-PlanEnergia -Guid $otro.Guid) -eq 'Cambiado')
        [void](Undo-Actual)
        T 'Vuelve al plan original' ((Get-PlanEnergiaActivo).Guid -eq $activo.Guid)
    }
    else { Info 'Solo hay un plan de energía: se omite el cambio.' }

    # ---------------------------------------------------------------------------------------
    Seccion '10. Punto de restauración (opcional: crea puntos reales)'
    $estPr = Get-EstadoProteccionSistema
    Info "Protección del sistema: $($estPr.Motivo) - $($estPr.Detalle)"
    $resp = Read-Host 'Escribe SI para probar la creación de puntos de restauración reales (otra cosa = omitir)'
    if ($resp -ceq 'SI') {
        if ($estPr.Motivo -ne 'Activa') {
            $sn = Read-Host "La protección no está activa ($($estPr.Motivo)). Activarla usa espacio en disco. Escribe SI para activarla"
            if ($sn -ceq 'SI') { $act = Enable-ProteccionSistema; Info "Enable-ProteccionSistema -> Activada=$($act.Activada) ($($act.Motivo))" }
        }
        $antesFrec = Get-RegistroEstado -Ruta 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Nombre 'SystemRestorePointCreationFrequency'
        [void](Start-JournalSesion -Nueva)
        $p1 = New-PuntoRestauracion -Descripcion 'OptiLow prueba 1'
        Info "Punto 1: Creado=$($p1.Creado) Motivo=$($p1.Motivo) $($p1.Detalle)"
        $p2 = New-PuntoRestauracion -Descripcion 'OptiLow prueba 2'
        Info "Punto 2 (seguido, sin esperar 24 h): Creado=$($p2.Creado) Motivo=$($p2.Motivo) $($p2.Detalle)"
        T 'Ambos puntos se crearon (la frecuencia se ajustó a 0)' ($p1.Creado -and $p2.Creado)
        $despFrec = Get-RegistroEstado -Ruta 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Nombre 'SystemRestorePointCreationFrequency'
        T 'SystemRestorePointCreationFrequency quedó como estaba' (($antesFrec.ValorExiste -eq $despFrec.ValorExiste) -and ((-not $antesFrec.ValorExiste) -or ($antesFrec.Dato -eq $despFrec.Dato)))
        Info 'Comprueba a mano que aparecen en rstrui.exe ("Restaurar sistema").'
        [void](Undo-Actual)
    }
    else { Info 'Omitido.' }
}
finally {
    # Limpieza de todo lo ficticio, pase lo que pase
    & sc.exe delete $nombreSvc | Out-Null
    Unregister-ScheduledTask -TaskName $nombreTarea -Confirm:$false -ErrorAction SilentlyContinue
    Remove-ClavePrueba -Ruta $claveHklm
    Remove-ClavePrueba -Ruta $claveHklm64
    Remove-ClavePrueba -Ruta $claveHkcu
    Remove-Item -LiteralPath $dirTmp -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------------------------
# Esta sección va al final porque pone en cuarentena los journals de las pruebas anteriores
Seccion '11. Seguridad: permisos manipulados y cuarentena'
$ruta = $global:OptiLow.DirRespaldos
[void](Start-JournalSesion -Nueva)
[void](Set-RegistroValor -Ruta 'HKCU:\Software\OptiLowPrueba' -Nombre 'z' -Valor 1 -Tipo DWord)
& icacls.exe $ruta /grant '*S-1-5-32-545:(OI)(CI)R' | Out-Null     # Usuarios: lectura
$v = Test-AclRespaldos -Ruta $ruta
T 'Test-AclRespaldos detecta que "Usuarios" tiene acceso' (-not $v.Valido)
Info ($v.Motivos -join ' ')
$msg = $null
try { [void](Undo-JournalSesion) } catch { $msg = $_.Exception.Message }
T 'Deshacer se niega con los permisos manipulados' ([bool]$msg)
Info "Mensaje: $msg"
$msg = $null
try { [void](Start-JournalSesion -Nueva) } catch { $msg = $_.Exception.Message }
T 'Iniciar una sesión nueva del journal también se niega' ([bool]$msg)
$global:OptiLow.Journal = $null
$ok = Initialize-CarpetaRespaldos
T 'Initialize-CarpetaRespaldos recupera la situación (cuarentena + carpeta nueva)' ($ok -and (Test-AclRespaldos -Ruta $global:OptiLow.DirRespaldos).Valido)
$cuarentenas = @(Get-ChildItem -LiteralPath $global:OptiLow.DirDatos -Directory -Filter 'backups.sin-verificar-*')
T 'La carpeta en cuarentena existe y no se borró' ($cuarentenas.Count -ge 1)
$cuarentenas | ForEach-Object { Info "Cuarentena: $($_.FullName)" }
Remove-ClavePrueba -Ruta 'HKCU:\Software\OptiLowPrueba'

Write-Host ''
$color = if ($script:mal -eq 0) { 'Green' } else { 'Red' }
Write-Host "Resultado: $($script:bien) bien, $($script:mal) con fallos." -ForegroundColor $color
Write-Host 'Revisa también el log y borra a mano las carpetas backups.sin-verificar-* cuando ya no las necesites.'
exit $(if ($script:mal -eq 0) { 0 } else { 1 })
