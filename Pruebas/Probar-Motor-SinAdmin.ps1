<#
.SYNOPSIS
    Pruebas del motor de tweaks y de la consola sin administrador.
.DESCRIPTION
    Comprueba el registro de tweaks (validación del contrato), el cargador tolerante a fallos, los estados Aplicado/Parcial/Fallido/NoAplica, el TweakId del journal, una sola sesión por lote y las decisiones de -SinPreguntar con un punto de restauración simulado.
    Se ejecuta SIN administrador a propósito: anula en memoria Assert-JournalListo y Test-AclRespaldos (solo en este
    proceso) y usa una carpeta de respaldos temporal, así prueba la lógica sin necesitar la carpeta protegida.
    Se NIEGA a correr elevado (algunas comprobaciones intentan escribir en HKLM y cambiar un servicio, y deben fallar
    por falta de permisos). Crea y borra una clave HKCU\Software\OptiLowPrueba* y una tarea programada ficticia del
    usuario: ejecútalo en una VM, no en el equipo principal.
    Ejecutar en Windows PowerShell 5.1 normal (no elevada):
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pruebas\Probar-Motor-SinAdmin.ps1
#>
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

Write-Host 'Pruebas sin administrador: crean claves HKCU de prueba y una tarea ficticia (se borran al terminar).' -ForegroundColor Yellow
if ((Read-Host 'Escribe SI (en mayúsculas) para continuar') -cne 'SI') { Write-Host 'Cancelado.'; exit 0 }
if ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Esta prueba debe ejecutarse SIN administrador (consola normal).' -ForegroundColor Red
    exit 1
}
$tmp = Join-Path $env:TEMP ('ol_h2_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
$env:ProgramData = $tmp
. (Join-Path $raiz 'Core\Loader.ps1')
Import-OptiLowCore -Raiz $raiz
Initialize-OptiLowRutas -Raiz $raiz
Initialize-OptiLowLog
$global:OptiLow.DirRespaldos = Join-Path $tmp 'bk'; New-Item -ItemType Directory $global:OptiLow.DirRespaldos | Out-Null
# --- solo para el arnés (sin admin) ---
function global:Assert-JournalListo { param([switch]$Completo) }
function global:Test-AclRespaldos { param($Ruta, [switch]$Archivo) [pscustomobject]@{ Valido = $true; Motivos = @() } }

$script:ok = 0; $script:mal = 0
function T($nombre, $cond) { if ($cond) { $script:ok++; "  OK   $nombre" } else { $script:mal++; "  FALLA $nombre" } }
function Seccion($x) { ""; "== $x ==" }
function Undo-Actual { $id = $global:OptiLow.Journal.Id; Undo-JournalSesion -Id $id }

$k = 'HKCU:\Software\OptiLowPruebaMotor'
$limpiar = { if (Test-Path 'Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaMotor') { Remove-Item 'Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaMotor' -Recurse -Force } }
& $limpiar

Seccion 'Tweaks reales: se registran, plantilla no'
$reg = @(Get-Tweak)
Write-Log -Nivel INFO -Mensaje 'cargando extras' | Out-Null
$r = Import-OptiLowExtras -Raiz $raiz
T 'Extras: 4 archivos cargados (2 módulos + 2 tweaks), 0 con error' ($r.Cargados -eq 4 -and $r.Fallidos -eq 0)
T 'Hay 3 tweaks registrados' (@(Get-Tweak).Count -eq 3)
T 'La plantilla no registró nada' (-not (Get-Tweak -Id 'ejemplo-id-del-tweak'))
T 'Servicios: Requiere = Reiniciar' ((Get-Tweak -Id 'telemetria-servicios-off').Requiere -eq 'Reiniciar')
T 'Comprobar de los tres devuelve un estado válido' ((@(Get-Tweak | ForEach-Object { (Get-TweakEstado -Id $_.Id).Estado }) | Where-Object { @('Aplicado', 'Pendiente', 'NoAplica') -notcontains $_ }).Count -eq 0)
T 'Recomendar con perfil Bajo = true / Alto = false' ((Test-TweakRecomendado -Id 'efectos-transparencia-off' -Hardware ([pscustomobject]@{ Perfil = 'Bajo' })) -and -not (Test-TweakRecomendado -Id 'efectos-transparencia-off' -Hardware ([pscustomobject]@{ Perfil = 'Alto' })))

Seccion 'Validación del contrato al registrar'
$n0 = @(Get-Tweak).Count
$bloqueOk = { Set-RegistroValor -Ruta 'HKCU:\Software\OptiLowPruebaMotor' -Nombre 'v' -Valor 1 -Tipo DWord }
T 'Id con mayúsculas rechazado' (-not (Register-Tweak -Id 'Mal-Id' -Nombre 'x' -Categoria 'c' -Descripcion 'Descripción suficientemente larga para pasar.' -Riesgo Bajo -Aplicar $bloqueOk))
T 'Id con guion doble rechazado' (-not (Register-Tweak -Id 'mal--id' -Nombre 'x' -Categoria 'c' -Descripcion 'Descripción suficientemente larga para pasar.' -Riesgo Bajo -Aplicar $bloqueOk))
T 'Descripción corta rechazada' (-not (Register-Tweak -Id 'corta' -Nombre 'x' -Categoria 'c' -Descripcion 'corta' -Riesgo Bajo -Aplicar $bloqueOk))
T 'Aplicar con Set-ItemProperty rechazado' (-not (Register-Tweak -Id 'directo' -Nombre 'x' -Categoria 'c' -Descripcion 'Descripción suficientemente larga para pasar.' -Riesgo Bajo -Aplicar { Set-ItemProperty -Path 'HKCU:\Software\X' -Name v -Value 1 }))
T 'Aplicar con sc.exe rechazado' (-not (Register-Tweak -Id 'conexe' -Nombre 'x' -Categoria 'c' -Descripcion 'Descripción suficientemente larga para pasar.' -Riesgo Bajo -Aplicar { sc.exe config x start= disabled }))
T 'Aplicar con Write-Host rechazado' (-not (Register-Tweak -Id 'conhost' -Nombre 'x' -Categoria 'c' -Descripcion 'Descripción suficientemente larga para pasar.' -Riesgo Bajo -Aplicar { Write-Host 'hola' }))
T 'Comprobar con Remove-Item rechazado' (-not (Register-Tweak -Id 'compesc' -Nombre 'x' -Categoria 'c' -Descripcion 'Descripción suficientemente larga para pasar.' -Riesgo Bajo -Aplicar $bloqueOk -Comprobar { Remove-Item C:\x }))
T 'Id duplicado (otro archivo) rechazado' (-not (Register-Tweak -Id 'efectos-transparencia-off' -Nombre 'x' -Categoria 'c' -Descripcion 'Descripción suficientemente larga para pasar.' -Riesgo Bajo -Aplicar $bloqueOk))
T 'Los tweaks reales siguen intactos (misma cantidad)' (@(Get-Tweak).Count -eq $n0)
T 'Un tweak válido sí se registra' (Register-Tweak -Id 'prueba-ok' -Nombre 'Prueba ok' -Categoria 'Pruebas' -Descripcion 'Escribe un valor de prueba en HKCU. Sin efectos secundarios.' -Riesgo Bajo -Requiere 'Cerrar sesión' -Aplicar { Set-RegistroValor -Ruta 'HKCU:\Software\OptiLowPruebaMotor' -Nombre 'ok' -Valor 1 -Tipo DWord } -Comprobar { $v = Get-RegistroEstado -Ruta 'HKCU:\Software\OptiLowPruebaMotor' -Nombre 'ok'; ($v.ValorExiste -and ([int64]$v.Dato -eq 1)) })

Seccion 'Cargador: un archivo roto no impide cargar los demás; los "_" no se cargan'
$tr = Join-Path $tmp 'proyecto'; New-Item -ItemType Directory "$tr\Tweaks", "$tr\Modules", "$tr\Core" | Out-Null
Copy-Item (Join-Path $raiz 'Core\*.ps1') "$tr\Core"
Set-Content "$tr\Tweaks\Roto.ps1" 'Register-Tweak -Id "x" -Nombre ' -Encoding UTF8
Set-Content "$tr\Tweaks\_NoCargar.ps1" 'throw "no debe cargarse"' -Encoding UTF8
Set-Content "$tr\Tweaks\Bueno.ps1" "[void](Register-Tweak -Id 'prueba-del-archivo' -Nombre 'x' -Categoria 'Pruebas' -Descripcion 'Tweak de prueba cargado desde un archivo. Sin efectos.' -Riesgo Bajo -Aplicar { Set-RegistroValor -Ruta 'HKCU:\Software\OptiLowPruebaMotor' -Nombre 'f' -Valor 1 -Tipo DWord })" -Encoding UTF8
Set-Content "$tr\Tweaks\ConError.ps1" "[void](Register-Tweak -Id 'prueba-roto-a-medias' -Nombre 'x' -Categoria 'Pruebas' -Descripcion 'Corta' -Riesgo Bajo -Aplicar { Set-RegistroValor -Ruta 'HKCU:\Software\X' -Nombre 'f' -Valor 1 -Tipo DWord })`r`n[void](Register-Tweak -Id 'prueba-despues-del-error' -Nombre 'x' -Categoria 'Pruebas' -Descripcion 'Este tweak va después de uno rechazado en el mismo archivo.' -Riesgo Bajo -Aplicar { Set-RegistroValor -Ruta 'HKCU:\Software\OptiLowPruebaMotor' -Nombre 'g' -Valor 1 -Tipo DWord })" -Encoding UTF8
$r = Import-OptiLowExtras -Raiz $tr
T 'Cargados 2 (Bueno y ConError), fallido 1 (Roto)' ($r.Cargados -eq 2 -and $r.Fallidos -eq 1)
T 'El tweak del archivo bueno se registró' ([bool](Get-Tweak -Id 'prueba-del-archivo'))
T 'El rechazado no se registró pero el siguiente del mismo archivo sí' ((-not (Get-Tweak -Id 'prueba-roto-a-medias')) -and [bool](Get-Tweak -Id 'prueba-despues-del-error'))
T 'Los tweaks reales siguen ahí' ([bool](Get-Tweak -Id 'efectos-transparencia-off'))
T 'Recargar el mismo archivo no da error de duplicado' ((Import-OptiLowExtras -Raiz $tr).Fallidos -eq 1)

Seccion 'Motor: lote en una sola sesión, estados y TweakId'
foreach ($def in @(
        @{ Id = 'prueba-excepcion'; A = { throw 'boom' } },
        @{ Id = 'prueba-parcial'; A = { Set-RegistroValor -Ruta 'HKCU:\Software\OptiLowPruebaMotor' -Nombre 'p' -Valor 1 -Tipo DWord; Set-ServicioInicio -Nombre 'a\b' -Inicio Disabled } },
        @{ Id = 'prueba-noaplica'; A = { Disable-TareaProgramada -Ruta '\Microsoft\Windows\NoExiste\' -Nombre 'Uno'; Disable-TareaProgramada -Ruta '\Microsoft\Windows\NoExiste\' -Nombre 'Dos' } },
        @{ Id = 'prueba-reiniciar'; A = { Set-RegistroValor -Ruta 'HKCU:\Software\OptiLowPruebaMotor' -Nombre 'r' -Valor 1 -Tipo DWord } }
    )) {
    $req = 'Nada'; if ($def.Id -eq 'prueba-reiniciar') { $req = 'Reiniciar' }
    [void](Register-Tweak -Id $def.Id -Nombre $def.Id -Categoria 'Pruebas' -Descripcion 'Tweak de prueba del motor. Sin efectos secundarios reales.' -Riesgo Bajo -Requiere $req -Aplicar $def.A)
}
[void](Register-Tweak -Id 'prueba-multi' -Nombre 'multi' -Categoria 'Pruebas' -Descripcion 'Tweak con dos valores de registro para probar la combinación.' -Riesgo Bajo -Aplicar { Set-RegistroValor -Ruta 'HKCU:\Software\OptiLowPruebaMotor' -Nombre 'm1' -Valor 1 -Tipo DWord; Set-RegistroValor -Ruta 'HKCU:\Software\OptiLowPruebaMotor' -Nombre 'm2' -Valor 1 -Tipo DWord })
[void](Register-Tweak -Id 'prueba-comprobar-malo' -Nombre 'x' -Categoria 'Pruebas' -Descripcion 'Comprobar devuelve dos valores a propósito (contrato roto).' -Riesgo Bajo -Aplicar $bloqueOk -Comprobar { $true; $true })

T 'Comprobar con dos valores = Error' ((Get-TweakEstado -Id 'prueba-comprobar-malo').Estado -eq 'Error')
T 'Join-EstadosTweak: ninguno existe = null' ($null -eq (Join-EstadosTweak -Estados @($null, $null)))
T 'Join-EstadosTweak: todos bien = true' ((Join-EstadosTweak -Estados @($true, $null, $true)) -eq $true)
T 'Join-EstadosTweak: alguno mal = false' ((Join-EstadosTweak -Estados @($true, $false)) -eq $false)
T 'Estado previo de prueba-ok = Pendiente' ((Get-TweakEstado -Id 'prueba-ok').Estado -eq 'Pendiente')

[void](Start-JournalSesion -Nueva)
$idSesion = $global:OptiLow.Journal.Id
$lote = Invoke-TweaksLote -Ids 'prueba-ok', 'prueba-excepcion', 'prueba-parcial', 'prueba-noaplica', 'prueba-reiniciar', 'prueba-multi', 'no-existe'
$por = @{}; foreach ($x in $lote.Resultados) { $por[$x.Id] = $x }
T 'prueba-ok = Aplicado' ($por['prueba-ok'].Estado -eq 'Aplicado')
T 'Excepción = Fallido y no detiene a los demás' ($por['prueba-excepcion'].Estado -eq 'Fallido' -and $por['prueba-reiniciar'].Estado -eq 'Aplicado')
T 'Un elemento falla y otro cambia = Parcial' ($por['prueba-parcial'].Estado -eq 'Parcial')
T 'Ningún elemento existe = NoAplica' ($por['prueba-noaplica'].Estado -eq 'NoAplica')
T 'Dos elementos cambiados = Aplicado' ($por['prueba-multi'].Estado -eq 'Aplicado' -and $por['prueba-multi'].Cambiados -eq 2)
T 'Id inexistente en el lote = Fallido' ($por['no-existe'].Estado -eq 'Fallido')
T 'Requiere del lote = Reiniciar (por prueba-reiniciar)' ($lote.Requiere -eq 'Reiniciar' -and (@($lote.TweaksQueRequieren).Id -contains 'prueba-reiniciar'))
T 'prueba-ok pide Cerrar sesión y está en la lista' (@($lote.TweaksQueRequieren).Id -contains 'prueba-ok')
T 'Es una sola sesión del journal' ($global:OptiLow.Journal.Id -eq $idSesion)
$entradas = @($global:OptiLow.Journal.Datos.Entradas)
T 'Cada entrada guarda el Id del tweak que la generó' ((@($entradas | Where-Object { -not $_.TweakId }).Count -eq 0) -and (@($entradas | Where-Object { $_.TweakId -eq 'prueba-multi' }).Count -eq 2))
T 'El fallo de prueba-parcial (servicio) no dejó entrada en el journal' (@($entradas | Where-Object { $_.TweakId -eq 'prueba-parcial' }).Count -eq 1)
$n = $entradas.Count
$otra = Invoke-TweaksLote -Ids 'prueba-ok', 'prueba-multi'
T 'Aplicar otra vez: SinCambios (ya aplicado) y sin entradas nuevas' ((@($otra.Resultados | Where-Object { $_.Estado -ne 'SinCambios' }).Count -eq 0) -and (@($global:OptiLow.Journal.Datos.Entradas).Count -eq $n))
$s = Get-JournalSesiones | Where-Object { $_.Id -eq $idSesion }
T 'Get-JournalSesiones lista los Ids de los tweaks' (@($s.Tweaks) -contains 'prueba-multi' -and @($s.Tweaks) -contains 'prueba-ok')
$u = Undo-Actual
T 'Deshacer completo' ($u.Estado -eq 'Restaurado')
T 'Registro de prueba limpio tras deshacer' (-not (Test-Path 'Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaMotor'))
T 'prueba-ok vuelve a Pendiente' ((Get-TweakEstado -Id 'prueba-ok').Estado -eq 'Pendiente')

Seccion 'Consola: -SinPreguntar elige siempre la opción segura (punto de restauración simulado)'
$script:enableLlamado = $false; $script:nPuntos = 0; $script:respuesta = $true
function global:Enable-ProteccionSistema { $script:enableLlamado = $true; [pscustomobject]@{ Activada = $true; Motivo = 'Activa'; Detalle = 'x' } }
function global:Read-ConfirmacionConsola { param($Pregunta) $script:respuesta }
$script:modo = 'Desactivada'
function global:New-PuntoRestauracion {
    param($Descripcion)
    $script:nPuntos++
    switch ($script:modo) {
        'Desactivada' { [pscustomobject]@{ Creado = $false; Motivo = 'Desactivada'; Detalle = 'Protección desactivada (simulada).'; Metodo = ''; SequenceNumber = $null; PuntoReciente = $null } }
        'Reciente' { [pscustomobject]@{ Creado = $false; Motivo = 'YaExisteReciente'; Detalle = 'Ya existe uno reciente (simulado).'; Metodo = ''; SequenceNumber = $null; PuntoReciente = [pscustomobject]@{ Secuencia = 3; Descripcion = 'Windows Update'; Fecha = (Get-Date).AddHours(-1) } } }
        'Error' { [pscustomobject]@{ Creado = $false; Motivo = 'ErrorDeSistema'; Detalle = 'Error simulado.'; Metodo = ''; SequenceNumber = $null; PuntoReciente = $null } }
        'Creado' { [pscustomobject]@{ Creado = $true; Motivo = 'Creado'; Detalle = 'ok'; Metodo = 'simulado'; SequenceNumber = 9; PuntoReciente = $null } }
    }
}
$script:modo = 'Desactivada'; $script:enableLlamado = $false
$c = [int](@(Invoke-AplicarConsola -Ids 'prueba-ok' -SinPreguntar)[-1])
T '-SinPreguntar + protección desactivada: cancela (2), NO activa la protección y no aplica' ($c -eq 2 -and -not $script:enableLlamado -and (-not (Test-Path 'Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaMotor')))
$script:modo = 'Reciente'
$c = [int](@(Invoke-AplicarConsola -Ids 'prueba-ok' -SinPreguntar)[-1])
T '-SinPreguntar + punto reciente: cancela (2)' ($c -eq 2 -and (-not (Test-Path 'Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaMotor')))
$script:modo = 'Error'
$c = [int](@(Invoke-AplicarConsola -Ids 'prueba-ok' -SinPreguntar)[-1])
T '-SinPreguntar + error del punto: cancela (2)' ($c -eq 2)
$script:nPuntos = 0
$c = [int](@(Invoke-AplicarConsola -Ids 'prueba-ok' -SinPreguntar -SinPuntoRestauracion)[-1])
T '-SinPreguntar -SinPuntoRestauracion: aplica (0) sin intentar crear punto' ($c -eq 0 -and $script:nPuntos -eq 0 -and (Test-Path 'Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaMotor'))
$sesion1 = $global:OptiLow.Journal.Id
$c = [int](@(Invoke-DeshacerConsola -SinPreguntar)[-1])
T 'Deshacer por defecto deshace la última sesión (0)' ($c -eq 0 -and (-not (Test-Path 'Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaMotor')))
$c = [int](@(Invoke-DeshacerConsola -SinPreguntar)[-1])
T 'Sin sesiones pendientes: 0 y no hace nada' ($c -eq 0)
$c = [int](@(Invoke-DeshacerConsola -Sesion 'no-existe' -SinPreguntar)[-1])
T 'Sesión inexistente: 1' ($c -eq 1)
$script:modo = 'Creado'
$c = [int](@(Invoke-AplicarConsola -Ids 'prueba-ok' -SinPreguntar)[-1])
T 'Con punto creado continúa y aplica (0)' ($c -eq 0 -and (Test-Path 'Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaMotor'))
$c = [int](@(Invoke-AplicarConsola -Ids 'prueba-ok' -SinPreguntar)[-1])
T 'Todo ya aplicado: "nada que aplicar" (0) y sin intentar punto' ($c -eq 0)
$c = [int](@(Invoke-DeshacerConsola -Sesion $global:OptiLow.Journal.Id -SinPreguntar)[-1])
T 'Deshacer indicando el Id de la sesión (0)' ($c -eq 0 -and (-not (Test-Path 'Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaMotor')))

Seccion 'Consola interactiva simulada: el usuario decide'
$script:modo = 'Desactivada'; $script:respuesta = $false; $script:enableLlamado = $false
$c = [int](@(Invoke-AplicarConsola -Ids 'prueba-ok')[-1])
T 'El usuario dice NO a la confirmación: cancelado (2)' ($c -eq 2 -and -not (Test-Path 'Registry::HKEY_CURRENT_USER\Software\OptiLowPruebaMotor'))
$script:respuesta = $true; $script:modo = 'Reciente'
$c = [int](@(Invoke-AplicarConsola -Ids 'prueba-ok')[-1])
T 'Punto reciente + el usuario acepta continuar con él: aplica (0)' ($c -eq 0)
[void](Undo-Actual)

Import-OptiLowArchivo -Ruta (Join-Path $raiz 'Core\PuntoRestauracion.ps1')
Import-OptiLowArchivo -Ruta (Join-Path $raiz 'Core\Consola.ps1')
Seccion 'Listados'
$null = Show-TweaksConsola 6>&1 | Out-String
T 'Show-TweaksConsola no falla' $true
$code = [int](@(Show-SesionesConsola)[-1])
T 'Show-SesionesConsola devuelve 0' ($code -eq 0)

"`nResultado: $script:ok bien, $script:mal con fallos"
& $limpiar
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
