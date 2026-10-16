<#
.SYNOPSIS
    Pruebas de Core/ (journal, registro, JSON, archivos, tareas, servicios, energía) sin administrador.
.DESCRIPTION
    Comprueba los seis tipos de registro, JSON profundo de 5 niveles, archivos con hash, tareas, restauración parcial y que un cambio que falla no queda en el journal.
    Se ejecuta SIN administrador a propósito: anula en memoria Assert-JournalListo y Test-AclRespaldos (solo en este
    proceso) y usa una carpeta de respaldos temporal, así prueba la lógica sin necesitar la carpeta protegida.
    Se NIEGA a correr elevado (algunas comprobaciones intentan escribir en HKLM y cambiar un servicio, y deben fallar
    por falta de permisos). Crea y borra una clave HKCU\Software\OptiLowPrueba* y una tarea programada ficticia del
    usuario: ejecútalo en una VM, no en el equipo principal.
    Ejecutar en Windows PowerShell 5.1 normal (no elevada):
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pruebas\Probar-Core-SinAdmin.ps1
#>
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

Write-Host 'Pruebas sin administrador: crean claves HKCU de prueba y una tarea ficticia (se borran al terminar).' -ForegroundColor Yellow
if ((Read-Host 'Escribe SI (en mayúsculas) para continuar') -cne 'SI') { Write-Host 'Cancelado.'; exit 0 }
if ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Esta prueba debe ejecutarse SIN administrador (consola normal).' -ForegroundColor Red
    exit 1
}
$tmp = Join-Path $env:TEMP ('ol_h_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
$env:ProgramData = $tmp
. (Join-Path $raiz 'Core\Loader.ps1')
Import-OptiLowCore -Raiz $raiz
Initialize-OptiLowRutas -Raiz $raiz
Initialize-OptiLowLog
$global:OptiLow.DirRespaldos = Join-Path $tmp 'bk'; New-Item -ItemType Directory $global:OptiLow.DirRespaldos | Out-Null
# --- solo para el arnés (sin admin): se anula la verificación de administrador/ACL ---
function global:Assert-JournalListo { param([switch]$Completo) }
function global:Test-AclRespaldos { param($Ruta, [switch]$Archivo) [pscustomobject]@{ Valido = $true; Motivos = @() } }

$script:ok = 0; $script:mal = 0
function Seccion($x) { "== $x ==" }
function Undo-Actual { $id=$global:OptiLow.Journal.Id; Undo-JournalSesion -Id $id }
function T($nombre, $cond) { if ($cond) { $script:ok++; "  OK   $nombre" } else { $script:mal++; "  FALLA $nombre" } }

$clave = 'HKCU:\Software\OptiLowPruebaHarness'
if (Test-Path "Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaHarness") { Remove-Item "Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaHarness" -Recurse -Force }

"== Registro: seis tipos en clave inexistente =="
[void](Start-JournalSesion -Nueva)
T 'DWord'        ((Set-RegistroValor -Ruta "$clave\Sub" -Nombre 'd' -Valor 4000000000 -Tipo DWord) -eq 'Cambiado')
T 'QWord'        ((Set-RegistroValor -Ruta "$clave\Sub" -Nombre 'q' -Valor '18446744073709551615' -Tipo QWord) -eq 'Cambiado')
T 'String'       ((Set-RegistroValor -Ruta "$clave\Sub" -Nombre 's' -Valor 'hola ñandú' -Tipo String) -eq 'Cambiado')
T 'ExpandString' ((Set-RegistroValor -Ruta "$clave\Sub" -Nombre 'x' -Valor '%SystemRoot%\x' -Tipo ExpandString) -eq 'Cambiado')
T 'MultiString'  ((Set-RegistroValor -Ruta "$clave\Sub" -Nombre 'm' -Valor @('a', 'b') -Tipo MultiString) -eq 'Cambiado')
T 'Binary'       ((Set-RegistroValor -Ruta "$clave\Sub" -Nombre 'b' -Valor ([byte[]](1, 2, 255)) -Tipo Binary) -eq 'Cambiado')
T 'String vacío' ((Set-RegistroValor -Ruta "$clave\Sub" -Nombre 'v' -Valor '' -Tipo String) -eq 'Cambiado')
$e = Get-RegistroEstado -Ruta "$clave\Sub" -Nombre 'd'; T 'DWord leído 4000000000' ($e.Dato -eq 4000000000 -and $e.Tipo -eq 'DWord')
$e = Get-RegistroEstado -Ruta "$clave\Sub" -Nombre 'q'; T 'QWord leído max' ($e.Dato -eq [uint64]::MaxValue)
$e = Get-RegistroEstado -Ruta "$clave\Sub" -Nombre 'x'; T 'ExpandString sin expandir' ($e.Dato -ceq '%SystemRoot%\x')
$e = Get-RegistroEstado -Ruta "$clave\Sub" -Nombre 'm'; T 'MultiString leído' (($e.Dato -join ',') -eq 'a,b')
T 'Idempotente (sin cambios)' ((Set-RegistroValor -Ruta "$clave\Sub" -Nombre 'd' -Valor 4000000000 -Tipo DWord) -eq 'SinCambios')
T 'Journal tiene 7 entradas' (@($global:OptiLow.Journal.Datos.Entradas).Count -eq 7)
"== Registro: sobrescribir valor existente (cambia de tipo) =="
T 'String->DWord' ((Set-RegistroValor -Ruta "$clave\Sub" -Nombre 's' -Valor 7 -Tipo DWord) -eq 'Cambiado')
T 'Remove valor' ((Remove-RegistroValor -Ruta "$clave\Sub" -Nombre 'v') -eq 'Cambiado')
T 'Remove otra vez = SinCambios' ((Remove-RegistroValor -Ruta "$clave\Sub" -Nombre 'v') -eq 'SinCambios')
$r = Undo-JournalSesion
T 'Undo completo' ($r.Estado -eq 'Restaurado')
T 'La clave creada por nosotros ya no existe' (-not (Test-Path "Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaHarness"))

"== Registro: valores previos y tipos originales se restauran =="
New-Item "Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaHarness" -Force | Out-Null
$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\OptiLowPruebaHarness', $true)
$k.SetValue('x', '%SystemRoot%\orig', 'ExpandString'); $k.SetValue('m', [string[]]@('uno', 'dos'), 'MultiString'); $k.SetValue('b', [byte[]](9, 8), 'Binary'); $k.SetValue('d', -5, 'DWord'); $k.Dispose()
[void](Start-JournalSesion -Nueva)
[void](Set-RegistroValor -Ruta $clave -Nombre 'x' -Valor 'otro' -Tipo String)
[void](Set-RegistroValor -Ruta $clave -Nombre 'm' -Valor 'ya no lista' -Tipo String)
[void](Set-RegistroValor -Ruta $clave -Nombre 'b' -Valor 1 -Tipo DWord)
[void](Set-RegistroValor -Ruta $clave -Nombre 'd' -Valor 5 -Tipo DWord)
[void](Undo-JournalSesion)
$e = Get-RegistroEstado -Ruta $clave -Nombre 'x'; T 'ExpandString original' ($e.Tipo -eq 'ExpandString' -and $e.Dato -ceq '%SystemRoot%\orig')
$e = Get-RegistroEstado -Ruta $clave -Nombre 'm'; T 'MultiString original' ($e.Tipo -eq 'MultiString' -and ($e.Dato -join ',') -eq 'uno,dos')
$e = Get-RegistroEstado -Ruta $clave -Nombre 'b'; T 'Binary original' ($e.Tipo -eq 'Binary' -and ($e.Dato -join ',') -eq '9,8')
$e = Get-RegistroEstado -Ruta $clave -Nombre 'd'; T 'DWord original (4294967291)' ($e.Tipo -eq 'DWord' -and $e.Dato -eq 4294967291)
Remove-Item "Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaHarness" -Recurse -Force

"== JSON: restaurar solo la clave =="
$j = Join-Path $tmp 'settings.json'
[IO.File]::WriteAllText($j, '{"a":1,"enableHardwareAcceleration":true,"anidado":{"x":"y"}}', (New-Object Text.UTF8Encoding($false)))
[void](Start-JournalSesion -Nueva)
T 'Set clave existente' ((Set-JsonValor -Ruta $j -Clave 'enableHardwareAcceleration' -Valor $false) -eq 'Cambiado')
T 'Idempotente' ((Set-JsonValor -Ruta $j -Clave 'enableHardwareAcceleration' -Valor $false) -eq 'SinCambios')
T 'Clave nueva anidada' ((Set-JsonValor -Ruta $j -Clave 'n1', 'n2', 'n3' -Valor 'v') -eq 'Cambiado')
T 'Archivo inexistente = NoAplica' ((Set-JsonValor -Ruta (Join-Path $tmp 'no.json') -Clave 'k' -Valor 1) -eq 'NoAplica')
# el "usuario" cambia otra clave después
$o = [IO.File]::ReadAllText($j) | ConvertFrom-Json; $o.a = 99; $o | Add-Member -NotePropertyName extra -NotePropertyValue 'nuevo'
[IO.File]::WriteAllText($j, ($o | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
$r = Undo-JournalSesion
$o = [IO.File]::ReadAllText($j) | ConvertFrom-Json
T 'Undo completo' ($r.Estado -eq 'Restaurado')
T 'Clave restaurada a true' ($o.enableHardwareAcceleration -eq $true)
T 'Cambio del usuario (a=99) se conserva' ($o.a -eq 99)
T 'Clave extra del usuario se conserva' ($o.extra -eq 'nuevo')
T 'Intermedios creados por nosotros eliminados' (-not $o.PSObject.Properties['n1'])
T 'Anidado original intacto' ($o.anidado.x -eq 'y')
T 'Sin BOM' (([IO.File]::ReadAllBytes($j)[0]) -eq 123)

Seccion 'JSON profundo: 5 niveles, arrays, nulos y caracteres especiales (se compara que quede idéntico salvo la clave cambiada)'
$jp = Join-Path $tmp 'profundo.json'
$textoOriginal = '{"nombre":"Prueba ñandú <&> ''q''","version":3,"activo":true,"nulo":null,"fecha":"2024-05-01T12:00:00Z","decimal":1.5,"grande":12345678901,"lista":[1,2,3],"vacia":[],"objVacio":{},"uno":["solo"],"nivel1":{"nivel2":{"nivel3":{"nivel4":{"nivel5":{"profundo":"valor","arr":[{"a":1,"b":[10,20,{"c":"x"}]},{"a":2}]}}}}},"matriz":[[1,2],[3,[4,5]]],"enableHardwareAcceleration":true}'
[IO.File]::WriteAllText($jp, $textoOriginal, (New-Object Text.UTF8Encoding($false)))
$canon = { param($texto) ConvertTo-Json -InputObject (ConvertFrom-Json -InputObject $texto) -Depth 100 -Compress }
$canonOriginal = & $canon $textoOriginal

[void](Start-JournalSesion -Nueva)
T 'Cambiar una clave de primer nivel' ((Set-JsonValor -Ruta $jp -Clave 'enableHardwareAcceleration' -Valor $false) -eq 'Cambiado')
$despues = [IO.File]::ReadAllText($jp)
$esperado = ConvertFrom-Json -InputObject $textoOriginal
$esperado.enableHardwareAcceleration = $false
T 'El resto del contenido quedó idéntico (solo cambió esa clave)' ((& $canon $despues) -ceq (ConvertTo-Json -InputObject $esperado -Depth 100 -Compress))
T 'No aparecen textos de objetos aplastados (System.Collections / @{)' (($despues -notmatch 'System\.Collections') -and ($despues -notmatch '@\{'))
$o = ConvertFrom-Json -InputObject $despues
T 'El valor del nivel 5 y el array anidado siguen ahí' (($o.nivel1.nivel2.nivel3.nivel4.nivel5.arr[0].b[2].c -eq 'x') -and ($o.matriz[1][1][1] -eq 5))
T 'Array de un solo elemento sigue siendo array' (($o.uno -is [array]) -and ($o.uno.Count -eq 1))
T 'Array y objeto vacíos se conservan' (($o.vacia -is [array]) -and ($o.vacia.Count -eq 0) -and ($o.objVacio -is [pscustomobject]))
T 'Los caracteres especiales no se alteran' ($o.nombre -ceq "Prueba ñandú <&> 'q'")
T 'Nulo y número grande se conservan' (($null -eq $o.nulo) -and ($o.grande -eq 12345678901))

T 'Cambiar una clave del nivel 5' ((Set-JsonValor -Ruta $jp -Clave 'nivel1', 'nivel2', 'nivel3', 'nivel4', 'nivel5', 'profundo' -Valor 'nuevo') -eq 'Cambiado')
T 'Reemplazar un objeto entero (se guarda en el journal con -Depth 100)' ((Set-JsonValor -Ruta $jp -Clave 'matriz' -Valor 'plano') -eq 'Cambiado')
$r = Undo-Actual
T 'Deshacer completo' ($r.Estado -eq 'Restaurado')
T 'Tras deshacer, el JSON es idéntico al original' ((& $canon ([IO.File]::ReadAllText($jp))) -ceq $canonOriginal)
"== Archivos =="
$f = Join-Path $tmp 'a.txt'; Set-Content $f 'original' -Encoding UTF8
$f2 = Join-Path $tmp 'nuevo.txt'
[void](Start-JournalSesion -Nueva)
T 'Reescribir' ((Write-ArchivoTexto -Ruta $f -Contenido 'cambiado ñ') -eq 'Cambiado')
T 'Idempotente' ((Write-ArchivoTexto -Ruta $f -Contenido 'cambiado ñ') -eq 'SinCambios')
T 'Crear' ((Write-ArchivoTexto -Ruta $f2 -Contenido 'x') -eq 'Cambiado')
T 'Carpeta inexistente = NoAplica' ((Write-ArchivoTexto -Ruta (Join-Path $tmp 'no\x.txt') -Contenido 'x') -eq 'NoAplica')
$r = Undo-JournalSesion
T 'Undo completo' ($r.Estado -eq 'Restaurado')
T 'Contenido original' ((Get-Content $f -Raw).Trim() -eq 'original')
T 'Archivo creado se elimina' (-not (Test-Path $f2))
"-- creado por nosotros pero modificado después: no se borra --"
[void](Start-JournalSesion -Nueva)
[void](Write-ArchivoTexto -Ruta $f2 -Contenido 'x'); Set-Content $f2 'del usuario'
[void](Undo-JournalSesion)
T 'No se borra si cambió' (Test-Path $f2)

"== Tareas (tarea ficticia del usuario) =="
$nt = 'OptiLowPruebaHarness'
Unregister-ScheduledTask -TaskName $nt -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $nt -Action (New-ScheduledTaskAction -Execute 'cmd.exe') -Trigger (New-ScheduledTaskTrigger -Daily -At 3am) | Out-Null
[void](Start-JournalSesion -Nueva)
T 'Desactivar' ((Disable-TareaProgramada -Ruta '\' -Nombre $nt) -eq 'Cambiado')
T 'Estado desactivada' (-not (Get-TareaEstado -Ruta '\' -Nombre $nt).Habilitada)
T 'Otra vez = SinCambios' ((Disable-TareaProgramada -Ruta '\' -Nombre $nt) -eq 'SinCambios')
T 'Inexistente = NoAplica' ((Disable-TareaProgramada -Ruta '\Microsoft\Windows\NoExiste\' -Nombre 'Nada') -eq 'NoAplica')
$r = Undo-JournalSesion
T 'Undo completo' ($r.Estado -eq 'Restaurado')
T 'Habilitada de nuevo' ((Get-TareaEstado -Ruta '\' -Nombre $nt).Habilitada)
"-- restauración parcial: se borra la tarea antes de deshacer --"
[void](Start-JournalSesion -Nueva)
[void](Disable-TareaProgramada -Ruta '\' -Nombre $nt)
[void](Set-RegistroValor -Ruta 'HKCU:\Software\OptiLowPruebaHarness' -Nombre 'p' -Valor 1 -Tipo DWord)
Unregister-ScheduledTask -TaskName $nt -Confirm:$false
$idParcial = $global:OptiLow.Journal.Id
$r = Undo-JournalSesion
T 'Estado RestauradoParcial' ($r.Estado -eq 'RestauradoParcial')
T 'Indica 1 entrada fallida (la tarea)' (@($r.Fallidas).Count -eq 1 -and $r.Fallidas[0].Tipo -eq 'Tarea')
T 'El registro sí se restauró' (-not (Test-Path 'Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaHarness'))
$s = Get-JournalSesiones | Where-Object { $_.Id -eq $idParcial }
T 'Journal marcado RestauradoParcial' ($s.Estado -eq 'RestauradoParcial')

"== Servicios y energía: solo validaciones que no cambian nada =="
T 'Servicio inexistente = NoAplica' ((Set-ServicioInicio -Nombre 'OptiLowNoExiste' -Inicio Disabled) -eq 'NoAplica')
T 'Nombre con barra = Fallido' ((Set-ServicioInicio -Nombre 'a\b' -Inicio Disabled) -eq 'Fallido')
$s = Get-ServicioEstado -Nombre 'Spooler'; T 'Get-ServicioEstado lee Spooler' ($s.Existe -and $s.Start -ge 2)
T 'Servicio ya en su estado = SinCambios' ((Set-ServicioInicio -Nombre 'Spooler' -Inicio $s.Inicio) -eq 'SinCambios')
T 'Energía: GUID inválido = Fallido' ((Set-PlanEnergia -Guid 'xyz') -eq 'Fallido')
T 'Energía: plan inexistente = NoAplica' ((Set-PlanEnergia -Guid '00000000-1111-2222-3333-444444444444') -eq 'NoAplica')
$p = Get-PlanEnergiaActivo; T "Energía: plan activo leído ($($p.Nombre))" ($p.Guid -match '^[0-9a-f-]{36}$')
T 'Energía: plan ya activo = SinCambios' ((Set-PlanEnergia -Guid $p.Guid) -eq 'SinCambios')
$est = Get-EstadoProteccionSistema; "  (info) Protección del sistema: $($est.Motivo) - $($est.Detalle)"

"== Un cambio que falla no queda en el journal (sin administrador, HKLM y sc.exe dan acceso denegado) =="
[void](Start-JournalSesion -Nueva)
T 'Registro HKLM sin permiso = Fallido' ((Set-RegistroValor -Ruta 'HKLM:\SOFTWARE\OptiLowNoPermiso' -Nombre 'x' -Valor 1 -Tipo DWord) -eq 'Fallido')
T 'La entrada se quitó del journal' (@($global:OptiLow.Journal.Datos.Entradas).Count -eq 0)
T 'No quedó archivo de journal vacío' (-not (Test-Path $global:OptiLow.Journal.Ruta))
$sp = Get-ServicioEstado -Nombre 'Spooler'
$destino = if ($sp.Inicio -eq 'Manual') { 'Automatic' } else { 'Manual' }
T 'Servicio protegido/sin permiso (sc.exe código 5) = Fallido' ((Set-ServicioInicio -Nombre 'Spooler' -Inicio $destino) -eq 'Fallido')
T 'La entrada del servicio tampoco quedó en el journal' (@($global:OptiLow.Journal.Datos.Entradas).Count -eq 0)
T 'Spooler sigue igual' ((Get-ServicioEstado -Nombre 'Spooler').Inicio -eq $sp.Inicio)
"== Guarda: sin administrador, la función real se niega =="
Import-OptiLowArchivo -Ruta (Join-Path $raiz "Core\Journal.ps1")
$global:OptiLow.DirRespaldos = $null
$msg = $null; try { Assert-JournalListo } catch { $msg = $_.Exception.Message }
T 'Assert-JournalListo lanza error explicativo' ([bool]$msg)
"     -> $msg"

"`nResultado: $script:ok bien, $script:mal con fallos"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
