<#
.SYNOPSIS
    Pruebas de la fase 6a: deshacer UNA optimización (Undo-JournalTweak) con detección de conflictos.
.DESCRIPTION
    Comprueba, con optimizaciones de prueba, que:
      - se puede deshacer una sola optimización sin tocar las demás;
      - si una sesión posterior sin deshacer (o una optimización posterior de la misma sesión) modificó lo mismo,
        NO se deshace sin confirmación explícita (-Forzar) y se explica qué se perdería;
      - si el valor actual ya no es el que dejamos nosotros, también pide confirmación;
      - un archivo entero choca con las claves JSON de ese archivo, pero dos claves JSON distintas no chocan;
      - la sesión pasa a «Restaurado» solo cuando ya no queda nada por deshacer, y «Deshacer sesión» no repite lo
        que ya se deshizo una a una;
      - Get-JournalSesiones informa de cuántos cambios hay y cuántos se deshicieron.
    SIN -ConRegistro solo toca archivos de una carpeta temporal (y redirige %ProgramData%): es seguro en cualquier
    equipo y no necesita administrador (anula en memoria Assert-JournalListo y Test-AclRespaldos, solo en este proceso).
    CON -ConRegistro añade una sección con una clave HKCU\Software\OptiLowPrueba6a (se borra al terminar): ejecútalo
    en la VM, no en el equipo principal.
    Ejecutar en Windows PowerShell 5.1:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pruebas\Probar-Fase6a.ps1
.PARAMETER ConRegistro
    Añade las pruebas con valores del registro (HKCU de prueba). Solo en la VM.
#>
param(
    [switch]$ConRegistro
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

$tmp = Join-Path $env:TEMP ('ol_6a_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
$env:ProgramData = $tmp
. (Join-Path $raiz 'Core\Loader.ps1')
Import-OptiLowCore -Raiz $raiz
Initialize-OptiLowRutas -Raiz $raiz
Initialize-OptiLowLog
$bk = Join-Path $tmp 'bk'
$global:OptiLow.DirRespaldos = $bk; New-Item -ItemType Directory $bk | Out-Null
# --- solo para el arnés: se anula la verificación de administrador/ACL ---
function global:Assert-JournalListo { param([switch]$Completo) }
function global:Test-AclRespaldos { param($Ruta, [switch]$Archivo) [pscustomobject]@{ Valido = $true; Motivos = @() } }

$script:ok = 0; $script:mal = 0
function T($nombre, $cond) { if ($cond) { $script:ok++; "  OK   $nombre" } else { $script:mal++; "  FALLA $nombre" } }
function Seccion($x) { ""; "== $x ==" }

$json = Join-Path $tmp 'config.json'
$env:OL6A_JSON = $json

# --- Optimizaciones de prueba (escriben solo en el JSON temporal) ---
$d = 'Optimización de prueba de la fase 6a. Escribe una clave de un JSON temporal.'
[void](Register-Tweak -Id 'pr-a' -Nombre 'Prueba A' -Categoria 'Pruebas' -Descripcion $d -Riesgo Bajo -Aplicar {
        Set-JsonValor -Ruta $env:OL6A_JSON -Clave 'compartida' -Valor 1
        Set-JsonValor -Ruta $env:OL6A_JSON -Clave 'soloA' -Valor 1 })
[void](Register-Tweak -Id 'pr-b' -Nombre 'Prueba B' -Categoria 'Pruebas' -Descripcion $d -Riesgo Bajo -Aplicar {
        Set-JsonValor -Ruta $env:OL6A_JSON -Clave 'compartida' -Valor 2
        Set-JsonValor -Ruta $env:OL6A_JSON -Clave 'soloB' -Valor 1 })
[void](Register-Tweak -Id 'pr-c' -Nombre 'Prueba C' -Categoria 'Pruebas' -Descripcion $d -Riesgo Bajo -Aplicar {
        Set-JsonValor -Ruta $env:OL6A_JSON -Clave 'soloC' -Valor 1 })
[void](Register-Tweak -Id 'pr-f' -Nombre 'Prueba F (archivo entero)' -Categoria 'Pruebas' -Descripcion $d -Riesgo Bajo -Aplicar {
        Write-ArchivoTexto -Ruta $env:OL6A_JSON -Contenido '{"nuevo":1}' })

function Reiniciar-Escenario {
    # Journal vacío y JSON con el estado inicial
    Get-ChildItem $bk -Filter '*.json' | Remove-Item -Force
    $global:OptiLow.Journal = $null
    [System.IO.File]::WriteAllText($json, '{"compartida":0,"x":"y"}', (New-Object System.Text.UTF8Encoding($false)))
}
function Aplicar-Lote([string[]]$Ids) { [void](Start-JournalSesion -Nueva); [void](Invoke-TweaksLote -Ids $Ids) }
function Aplicar-EnSesionNueva([string[]]$Ids) { Aplicar-Lote $Ids }
function Val([string]$Clave) { $r = Get-JsonValor -Ruta $json -Clave $Clave; if ($r.ClaveExiste) { return $r.Valor } else { return '<ausente>' } }
function Sesiones { @(Get-JournalSesiones) }
function CambiarJsonAMano([string]$Clave, $Valor) {
    $o = [System.IO.File]::ReadAllText($json) | ConvertFrom-Json
    $o.$Clave = $Valor
    [System.IO.File]::WriteAllText($json, (ConvertTo-Json -InputObject $o -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
}

# =============================================================================================
Seccion 'S1. Misma sesión: A y B tocan la misma clave'
Reiniciar-Escenario
Aplicar-Lote @('pr-a', 'pr-b')
T 'Tras aplicar: compartida = 2, soloA = 1, soloB = 1' ((Val 'compartida') -eq 2 -and (Val 'soloA') -eq 1 -and (Val 'soloB') -eq 1)
$dz = Get-JournalTweaksDeshacibles
T 'Deshacibles: pr-a y pr-b sí, pr-c no' ($dz.ContainsKey('pr-a') -and $dz.ContainsKey('pr-b') -and -not $dz.ContainsKey('pr-c'))
$s = (Sesiones)[0]
T 'Sesión: 4 cambios, 0 deshechos, 2 optimizaciones en el detalle' ($s.Cambios -eq 4 -and $s.CambiosDeshechos -eq 0 -and @($s.Detalle).Count -eq 2)
$r = Undo-JournalTweak -TweakId 'pr-a'
T 'Deshacer A sin confirmar: RequiereConfirmacion' ($r.Estado -eq 'RequiereConfirmacion')
T 'Hay al menos un conflicto que nombra «Prueba B»' (@($r.Conflictos).Count -ge 1 -and (@($r.Conflictos)[0].Texto -match 'Prueba B'))
T 'NO se tocó nada: compartida = 2, soloA = 1' ((Val 'compartida') -eq 2 -and (Val 'soloA') -eq 1)
T 'A sigue siendo deshacible' ((Get-JournalTweaksDeshacibles).ContainsKey('pr-a'))
$r = Undo-JournalTweak -TweakId 'pr-b'
T 'Deshacer B (la última): Restaurado' ($r.Estado -eq 'Restaurado' -and $r.Restauradas -eq 2)
T 'B revertida: compartida = 1, soloB ausente; A intacta (soloA = 1)' ((Val 'compartida') -eq 1 -and (Val 'soloB') -eq '<ausente>' -and (Val 'soloA') -eq 1)
$s = (Sesiones)[0]
T 'Sesión sigue «Activo» con 2 de 4 cambios deshechos' ($s.Estado -eq 'Activo' -and $s.CambiosDeshechos -eq 2 -and $s.Cambios -eq 4)
$dz = Get-JournalTweaksDeshacibles
T 'B ya no es deshacible; A sí' ((-not $dz.ContainsKey('pr-b')) -and $dz.ContainsKey('pr-a'))
$r = Undo-JournalTweak -TweakId 'pr-a'
T 'Deshacer A ya sin conflicto (B está deshecha): Restaurado sin confirmar' ($r.Estado -eq 'Restaurado')
T 'Estado original: compartida = 0, soloA ausente' ((Val 'compartida') -eq 0 -and (Val 'soloA') -eq '<ausente>')
T 'La sesión pasa a «Restaurado» al no quedar nada por deshacer' ((Sesiones)[0].Estado -eq 'Restaurado')
T 'Deshacer A otra vez: NadaQueDeshacer' ((Undo-JournalTweak -TweakId 'pr-a').Estado -eq 'NadaQueDeshacer')
T 'Una optimización desconocida: NadaQueDeshacer' ((Undo-JournalTweak -TweakId 'no-existe').Estado -eq 'NadaQueDeshacer')

# =============================================================================================
Seccion 'S2. Claves distintas del mismo archivo JSON NO chocan'
Reiniciar-Escenario
Aplicar-Lote @('pr-a', 'pr-c')
$r = Undo-JournalTweak -TweakId 'pr-a'
T 'Deshacer A con C aplicada después (otra clave): sin confirmación' ($r.Estado -eq 'Restaurado')
T 'C intacta (soloC = 1), A revertida' ((Val 'soloC') -eq 1 -and (Val 'soloA') -eq '<ausente>' -and (Val 'compartida') -eq 0)
$r = Undo-JournalTweak -TweakId 'pr-c'
T 'Deshacer C: Restaurado y sesión Restaurado' ($r.Estado -eq 'Restaurado' -and (Sesiones)[0].Estado -eq 'Restaurado')

# =============================================================================================
Seccion 'S3. Conflicto con una sesión POSTERIOR sin deshacer; confirmación y divergencia'
Reiniciar-Escenario
Aplicar-Lote @('pr-a')
Start-Sleep -Milliseconds 20
Aplicar-EnSesionNueva @('pr-b')
$ses = Sesiones
T 'Hay dos sesiones' ($ses.Count -eq 2)
$idB = $ses[0].Id
$r = Undo-JournalTweak -TweakId 'pr-a'
T 'Deshacer A: RequiereConfirmacion por la sesión posterior de B' ($r.Estado -eq 'RequiereConfirmacion' -and @($r.Conflictos).Count -ge 1 -and $r.Conflictos[0].OtraSesion -eq $idB)
T 'No se tocó nada' ((Val 'compartida') -eq 2 -and (Val 'soloA') -eq 1)
$r = Undo-JournalTweak -TweakId 'pr-a' -Forzar
T 'Con -Forzar (confirmación explícita): Restaurado' ($r.Estado -eq 'Restaurado')
T 'Se restauró el original (compartida = 0): el cambio posterior de B se perdió, como se avisó' ((Val 'compartida') -eq 0 -and (Val 'soloA') -eq '<ausente>')
$r = Undo-JournalTweak -TweakId 'pr-b'
T 'Deshacer B ahora avisa: compartida ya no es 2 (divergencia), sin conflictos' ($r.Estado -eq 'RequiereConfirmacion' -and @($r.Divergencias).Count -ge 1 -and @($r.Conflictos).Count -eq 0)
$r = Undo-JournalTweak -TweakId 'pr-b' -Forzar
T 'B con -Forzar: Restaurado, soloB ausente' ($r.Estado -eq 'Restaurado' -and (Val 'soloB') -eq '<ausente>')
T 'Ambas sesiones quedan «Restaurado»' (@(Sesiones | Where-Object { $_.Estado -ne 'Restaurado' }).Count -eq 0)

# =============================================================================================
Seccion 'S4. El valor actual ya no es el que dejamos (cambio manual)'
Reiniciar-Escenario
Aplicar-Lote @('pr-a')
CambiarJsonAMano 'compartida' 7
$r = Undo-JournalTweak -TweakId 'pr-a'
T 'RequiereConfirmacion con 1 divergencia y 0 conflictos' ($r.Estado -eq 'RequiereConfirmacion' -and @($r.Divergencias).Count -eq 1 -and @($r.Conflictos).Count -eq 0)
T 'El aviso explica qué se sobrescribiría' ($r.Divergencias[0].Texto -match 'ya no tiene el valor')
T 'No se tocó nada (compartida sigue 7)' ((Val 'compartida') -eq 7)
$r = Undo-JournalTweak -TweakId 'pr-a' -Forzar
T 'Con -Forzar: Restaurado y compartida = 0' ($r.Estado -eq 'Restaurado' -and (Val 'compartida') -eq 0)

# =============================================================================================
Seccion 'S5. Un archivo entero choca con las claves JSON de ese archivo'
Reiniciar-Escenario
Aplicar-Lote @('pr-a')
Start-Sleep -Milliseconds 20
Aplicar-EnSesionNueva @('pr-f')
$r = Undo-JournalTweak -TweakId 'pr-a'
T 'Deshacer A tras reescribir el archivo entero (F): RequiereConfirmacion con conflicto con F' ($r.Estado -eq 'RequiereConfirmacion' -and @($r.Conflictos).Count -ge 1 -and (@($r.Conflictos)[0].Texto -match 'Prueba F'))
$e1 = [pscustomobject]@{ Tipo = 'Json'; Ruta = 'C:\x\a.json'; Clave = @('k1') }
$e2 = [pscustomobject]@{ Tipo = 'Json'; Ruta = 'C:\X\A.json'; Clave = @('K2') }
$e3 = [pscustomobject]@{ Tipo = 'Json'; Ruta = 'c:\x\a.json'; Clave = @('K1') }
$e4 = [pscustomobject]@{ Tipo = 'Archivo'; Ruta = 'C:\x\a.JSON' }
$e5 = [pscustomobject]@{ Tipo = 'Servicio'; Nombre = 'DiagTrack' }
$e6 = [pscustomobject]@{ Tipo = 'Servicio'; Nombre = 'diagtrack' }
$e7 = [pscustomobject]@{ Tipo = 'Tarea'; Ruta = '\A\'; Nombre = 'T' }
$e8 = [pscustomobject]@{ Tipo = 'Registro'; Ruta = 'HKCU:\Software\X'; Nombre = 'V' }
$e9 = [pscustomobject]@{ Tipo = 'Registro'; Ruta = 'HKCU:\Software\X'; Nombre = 'v' }
function Chocan($a, $b) { Test-JournalObjetivosChocan -A (Get-JournalEntradaObjetivo -Entrada $a) -B (Get-JournalEntradaObjetivo -Entrada $b) }
T 'Dos claves JSON distintas del mismo archivo: no chocan' (-not (Chocan $e1 $e2))
T 'Misma clave JSON (mayúsculas distintas): chocan' (Chocan $e1 $e3)
T 'Archivo entero y clave JSON del mismo archivo: chocan' ((Chocan $e4 $e1) -and (Chocan $e1 $e4))
T 'Servicio igual (sin distinguir mayúsculas): chocan; servicio y tarea: no' ((Chocan $e5 $e6) -and -not (Chocan $e5 $e7))
T 'Registro igual (valor sin distinguir mayúsculas): chocan; registro y servicio: no' ((Chocan $e8 $e9) -and -not (Chocan $e8 $e5))
T 'Una nota no toca nada (sin objetivo)' ($null -eq (Get-JournalEntradaObjetivo -Entrada ([pscustomobject]@{ Tipo = 'Nota' })))

# =============================================================================================
Seccion 'S6. Deshacer la sesión completa después de deshacer una optimización suelta'
Reiniciar-Escenario
Aplicar-Lote @('pr-a', 'pr-b')
[void](Undo-JournalTweak -TweakId 'pr-b')
$r = Undo-JournalSesion
T 'Deshacer sesión: Restaurado, 2 entradas restauradas (las de B se omiten)' ($r.Estado -eq 'Restaurado' -and $r.Restauradas -eq 2)
T 'Estado original (compartida = 0, sin soloA ni soloB): B no se restauró dos veces' ((Val 'compartida') -eq 0 -and (Val 'soloA') -eq '<ausente>' -and (Val 'soloB') -eq '<ausente>')

# =============================================================================================
Seccion 'S7. Volver a aplicar tras deshacer, en el mismo proceso'
Reiniciar-Escenario
Aplicar-Lote @('pr-a')
[void](Undo-JournalTweak -TweakId 'pr-a')
T 'La sesión activa en memoria se descarta tras deshacer' ($null -eq $global:OptiLow.Journal)
[void](Invoke-TweaksLote -Ids @('pr-a'))
T 'Se aplicó de nuevo (compartida = 1)' ((Val 'compartida') -eq 1)
$ses = Sesiones
T 'Dos sesiones: la primera Restaurado y la nueva Activo' ($ses.Count -eq 2 -and $ses[0].Estado -eq 'Activo' -and $ses[1].Estado -eq 'Restaurado')
T 'Solo la sesión nueva tiene cambios pendientes de A' ((Get-JournalTweaksDeshacibles)['pr-a'].Sesiones.Count -eq 1)
$r = Undo-JournalTweak -TweakId 'pr-a'
T 'Se vuelve a poder deshacer: Restaurado y compartida = 0' ($r.Estado -eq 'Restaurado' -and (Val 'compartida') -eq 0)

# =============================================================================================
if ($ConRegistro) {
    Seccion 'R. Registro (HKCU de prueba): conflicto y divergencia'
    $rutaReg = 'HKCU:\Software\OptiLowPrueba6a'
    $rutaCrudaReg = 'Registry::HKEY_CURRENT_USER\Software\OptiLowPrueba6a'
    if (Test-Path $rutaCrudaReg) { Remove-Item $rutaCrudaReg -Recurse -Force }
    [void](Register-Tweak -Id 'pr-ra' -Nombre 'Prueba registro A' -Categoria 'Pruebas' -Descripcion $d -Riesgo Bajo -Aplicar {
            Set-RegistroValor -Ruta 'HKCU:\Software\OptiLowPrueba6a' -Nombre 'compartida' -Valor 1 -Tipo DWord
            Set-RegistroValor -Ruta 'HKCU:\Software\OptiLowPrueba6a' -Nombre 'soloA' -Valor 'a' -Tipo String })
    [void](Register-Tweak -Id 'pr-rb' -Nombre 'Prueba registro B' -Categoria 'Pruebas' -Descripcion $d -Riesgo Bajo -Aplicar {
            Set-RegistroValor -Ruta 'HKCU:\Software\OptiLowPrueba6a' -Nombre 'compartida' -Valor 2 -Tipo DWord })
    function RegVal([string]$n) { $x = Get-RegistroEstado -Ruta $rutaReg -Nombre $n; if ($x.ValorExiste) { $x.Dato } else { '<ausente>' } }

    Reiniciar-Escenario
    Aplicar-Lote @('pr-ra', 'pr-rb')
    $r = Undo-JournalTweak -TweakId 'pr-ra'
    T 'Registro: deshacer A con B posterior: RequiereConfirmacion y no se toca nada' ($r.Estado -eq 'RequiereConfirmacion' -and (RegVal 'compartida') -eq 2 -and (RegVal 'soloA') -eq 'a')
    $r = Undo-JournalTweak -TweakId 'pr-rb'
    T 'Registro: deshacer B (la última): Restaurado, compartida vuelve a 1' ($r.Estado -eq 'Restaurado' -and (RegVal 'compartida') -eq 1)
    $r = Undo-JournalTweak -TweakId 'pr-ra'
    T 'Registro: deshacer A: Restaurado y la clave que creamos desaparece' ($r.Estado -eq 'Restaurado' -and -not (Test-Path $rutaCrudaReg))

    Reiniciar-Escenario
    Aplicar-Lote @('pr-ra')
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\OptiLowPrueba6a', $true); $k.SetValue('compartida', 9, 'DWord'); $k.Dispose()
    $r = Undo-JournalTweak -TweakId 'pr-ra'
    T 'Registro: valor cambiado a mano: RequiereConfirmacion con divergencia' ($r.Estado -eq 'RequiereConfirmacion' -and @($r.Divergencias).Count -eq 1 -and (RegVal 'compartida') -eq 9)
    $r = Undo-JournalTweak -TweakId 'pr-ra' -Forzar
    T 'Registro: con -Forzar se restaura y la clave desaparece' ($r.Estado -eq 'Restaurado' -and -not (Test-Path $rutaCrudaReg))
    if (Test-Path $rutaCrudaReg) { Remove-Item $rutaCrudaReg -Recurse -Force }
}

""
"Resultado: $script:ok bien, $script:mal fallos"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($script:mal -gt 0) { exit 1 } else { exit 0 }
