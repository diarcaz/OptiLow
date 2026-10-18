<#
.SYNOPSIS
    Pruebas de la fase 6b: programas de inicio (listar, deshabilitar y habilitar con StartupApproved).
.DESCRIPTION
    SIN -ConRegistro solo LEE (no escribe nada en el sistema, no necesita administrador): formato de los bytes,
    lectura de las cinco fuentes, coherencia con el conteo del diagnóstico, elementos protegidos, apps de la Store y
    rechazo de elementos que no existen.
    CON -ConRegistro (solo en la VM) crea un valor ficticio en HKCU\...\Run («OptiLowPrueba6b») y un archivo en la
    carpeta Inicio del usuario («OptiLowPrueba6b.txt»), los deshabilita y habilita, comprueba el journal y el deshacer y
    lo borra todo al terminar. El journal va a una carpeta temporal (redirige %ProgramData%).
    Ejecutar en Windows PowerShell 5.1:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pruebas\Probar-Fase6b.ps1
.PARAMETER ConRegistro
    Añade las pruebas que escriben en HKCU y en la carpeta Inicio del usuario. Solo en la VM.
#>
param(
    [switch]$ConRegistro
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

$tmp = Join-Path $env:TEMP ('ol_6b_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
$env:ProgramData = $tmp
. (Join-Path $raiz 'Core\Loader.ps1')
Import-OptiLowCore -Raiz $raiz
Initialize-OptiLowRutas -Raiz $raiz
Initialize-OptiLowLog
[void](Import-OptiLowExtras -Raiz $raiz)
$bk = Join-Path $tmp 'bk'
$global:OptiLow.DirRespaldos = $bk; New-Item -ItemType Directory $bk | Out-Null

$script:ok = 0; $script:mal = 0
function T($nombre, $cond) { if ($cond) { $script:ok++; "  OK   $nombre" } else { $script:mal++; "  FALLA $nombre" } }
function Seccion($x) { ""; "== $x ==" }

# =============================================================================================
Seccion 'S1. Formato de los bytes (solo cálculo)'
$on = New-InicioBytes -Habilitado $true
$off = New-InicioBytes -Habilitado $false
T 'Habilitado = 12 bytes, primer byte 02, resto 0' ($on.Length -eq 12 -and $on[0] -eq 2 -and (@($on[1..11] | Where-Object { $_ -ne 0 }).Count -eq 0))
T 'Deshabilitado = 12 bytes, primer byte 03' ($off.Length -eq 12 -and $off[0] -eq 3)
$ft = [BitConverter]::ToInt64($off, 4)
T 'Deshabilitado lleva la fecha (FILETIME) de ahora en los bytes 4-11' ([math]::Abs(([DateTime]::FromFileTimeUtc($ft) - [DateTime]::UtcNow).TotalMinutes) -lt 2)
T '02 -> habilitado' (-not (Test-InicioBytesDeshabilitado -Bytes ([byte[]]@(2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))))
T '03 -> deshabilitado' (Test-InicioBytesDeshabilitado -Bytes ([byte[]]@(3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
T '06 (visto en SecurityHealth) -> habilitado' (-not (Test-InicioBytesDeshabilitado -Bytes ([byte[]]@(6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))))
T '07 -> deshabilitado (bit 0)' (Test-InicioBytesDeshabilitado -Bytes ([byte[]]@(7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
T '00 (visto en un programa real) -> habilitado' (-not (Test-InicioBytesDeshabilitado -Bytes ([byte[]]@(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))))
T 'Sin datos o vacío -> habilitado' ((-not (Test-InicioBytesDeshabilitado -Bytes $null)) -and (-not (Test-InicioBytesDeshabilitado -Bytes ([byte[]]@()))))

# =============================================================================================
Seccion 'S2. Fuentes y claves de StartupApproved'
$f = Get-InicioFuentes
T 'Hay 5 fuentes' (@($f).Count -eq 5)
T 'Run de WOW6432Node usa StartupApproved\Run32' ((@($f | Where-Object { $_.Id -eq 'hklm-run32' })[0]).Aprob -like '*StartupApproved\Run32')
T 'Las dos carpetas de Inicio usan StartupApproved\StartupFolder' (@($f | Where-Object { $_.Tipo -eq 'Carpeta' -and $_.Aprob -like '*StartupApproved\StartupFolder' }).Count -eq 2)
T 'HKCU Run y HKLM Run usan StartupApproved\Run' (@($f | Where-Object { $_.Tipo -eq 'Run' -and $_.Aprob -like '*StartupApproved\Run' }).Count -eq 2)

# =============================================================================================
Seccion 'S3. Lectura real (solo lee)'
$lista = @(Get-ProgramasInicio)
"  ($($lista.Count) programas en este equipo)"
T 'Todos tienen Id, Nombre, Origen y estado' (@($lista | Where-Object { (-not $_.Id) -or (-not $_.Nombre) -or (-not $_.Origen) -or ($null -eq $_.Habilitado) }).Count -eq 0)
T 'Los Id son únicos' (@($lista | Select-Object -ExpandProperty Id -Unique).Count -eq $lista.Count)
$cnt = Get-HwProgramasInicio
T 'El conteo del diagnóstico coincide con la pestaña (habilitados)' ($cnt.Habilitados -eq @($lista | Where-Object { $_.Habilitado }).Count)
T 'El conteo del diagnóstico coincide con la pestaña (deshabilitados)' ($cnt.Deshabilitados -eq @($lista | Where-Object { -not $_.Habilitado }).Count)
$sh = $lista | Where-Object { $_.Nombre -eq 'SecurityHealth' } | Select-Object -First 1
if ($sh) { T 'SecurityHealth aparece como protegido' ($sh.Protegido -eq $true) } else { "  (SecurityHealth no está en este equipo; se omite)" }
$st = @(Get-ProgramasInicioStore)
"  ($($st.Count) apps de la Store con tarea de inicio)"
T 'Get-ProgramasInicioStore no falla y devuelve nombres' (@($st | Where-Object { -not $_.Nombre }).Count -eq 0)
$ph = Set-ProgramaInicio -Id 'hkcu-run|NoExiste-OptiLow-6b' -Habilitado $false
T 'Un programa que no existe -> NoAplica (sin tocar nada)' ($ph -eq 'NoAplica')

# =============================================================================================
if ($ConRegistro) {
    Seccion 'S4. VM: deshabilitar y habilitar de verdad (HKCU Run + carpeta Inicio del usuario)'
    # Solo para el arnés: sin administrador ni ACL real del journal, que va a una carpeta temporal
    function global:Assert-JournalListo { param([switch]$Completo) }
    function global:Test-AclRespaldos { param($Ruta, [switch]$Archivo) [pscustomobject]@{ Valido = $true; Motivos = @() } }

    $runK = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $apK = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    $apF = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    $n1 = 'OptiLowPrueba6b'
    $n2 = 'OptiLowPrueba6b.txt'
    $arch = Join-Path ([Environment]::GetFolderPath('Startup')) $n2
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
        $k.SetValue($n1, 'cmd.exe /c exit', [Microsoft.Win32.RegistryValueKind]::String); $k.Dispose()
        [System.IO.File]::WriteAllText($arch, 'prueba de OptiLow 6b', (New-Object System.Text.UTF8Encoding($false)))
        $id1 = 'hkcu-run|' + $n1
        $id2 = 'carpeta-usuario|' + $n2
        $p = @(Get-ProgramasInicio)
        T 'Aparecen los dos elementos de prueba, habilitados' ((@($p | Where-Object { $_.Id -eq $id1 -and $_.Habilitado }).Count -eq 1) -and (@($p | Where-Object { $_.Id -eq $id2 -and $_.Habilitado }).Count -eq 1))

        $r = Invoke-ProgramasInicioCambio -Ids @($id1, $id2) -Habilitar $false
        T 'Deshabilitar: 2 cambiados, 0 fallidos' (@($r.Cambiados).Count -eq 2 -and @($r.Fallidos).Count -eq 0)
        $p = @(Get-ProgramasInicio)
        T 'Ahora salen deshabilitados' ((@($p | Where-Object { $_.Id -eq $id1 -and -not $_.Habilitado }).Count -eq 1) -and (@($p | Where-Object { $_.Id -eq $id2 -and -not $_.Habilitado }).Count -eq 1))
        T 'El valor de Run NO se borró' ($null -ne (Get-ItemProperty -Path $runK -Name $n1 -ErrorAction SilentlyContinue).$n1)
        T 'El archivo de la carpeta Inicio NO se borró' (Test-Path -LiteralPath $arch)
        $b = (Get-ItemProperty -Path $apK -Name $n1).$n1
        T 'StartupApproved\Run tiene 12 bytes y primer byte 03' ($b.Length -eq 12 -and $b[0] -eq 3)
        $b = (Get-ItemProperty -Path $apF -Name $n2).$n2
        T 'StartupApproved\StartupFolder tiene 12 bytes y primer byte 03' ($b.Length -eq 12 -and $b[0] -eq 3)
        $r2 = Invoke-ProgramasInicioCambio -Ids @($id1) -Habilitar $false
        T 'Deshabilitar otra vez -> SinCambios' (@($r2.SinCambios).Count -eq 1 -and @($r2.Cambiados).Count -eq 0)
        $s = @(Get-JournalSesiones)
        T 'El journal tiene la sesión con TweakId programas-inicio' (@($s | Where-Object { @($_.Tweaks) -contains 'programas-inicio' }).Count -ge 1)
        T 'Get-JournalTweaksDeshacibles incluye programas-inicio' ((Get-JournalTweaksDeshacibles).ContainsKey('programas-inicio'))

        $r3 = Invoke-ProgramasInicioCambio -Ids @($id1, $id2) -Habilitar $true
        T 'Habilitar: 2 cambiados' (@($r3.Cambiados).Count -eq 2)
        $b = (Get-ItemProperty -Path $apK -Name $n1).$n1
        T 'Habilitado deja 02 y 11 ceros' ($b[0] -eq 2 -and @($b[1..11] | Where-Object { $_ -ne 0 }).Count -eq 0)
        $p = @(Get-ProgramasInicio)
        T 'Vuelven a salir habilitados' ((@($p | Where-Object { $_.Id -eq $id1 -and $_.Habilitado }).Count -eq 1) -and (@($p | Where-Object { $_.Id -eq $id2 -and $_.Habilitado }).Count -eq 1))

        # Deshacer desde el journal: la sesión de «deshabilitar» devuelve el estado original (sin valor aprobado)
        $r4 = Invoke-ProgramasInicioCambio -Ids @($id1) -Habilitar $false
        $r5 = Undo-JournalSesion -Id $r4.Sesion
        T 'Undo-JournalSesion de la sesión de deshabilitar restaura' ($r5.Estado -eq 'Restaurado')
        $p = @(Get-ProgramasInicio)
        T 'Tras deshacer vuelve a salir habilitado' (@($p | Where-Object { $_.Id -eq $id1 -and $_.Habilitado }).Count -eq 1)
    }
    finally {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run', $true)
        if ($k) { try { $k.DeleteValue($n1, $false) } catch { } $k.Dispose() }
        foreach ($rutaAp in @('Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run', 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder')) {
            $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($rutaAp, $true)
            if ($k) { foreach ($nn in @($n1, $n2)) { try { $k.DeleteValue($nn, $false) } catch { } }; $k.Dispose() }
        }
        Remove-Item -LiteralPath $arch -Force -ErrorAction SilentlyContinue
    }
    T 'Limpieza: no queda el valor de prueba en Run' ($null -eq (Get-ItemProperty -Path $runK -Name $n1 -ErrorAction SilentlyContinue))
    T 'Limpieza: no queda el archivo de prueba' (-not (Test-Path -LiteralPath $arch))
}
else {
    ""
    "(Sección S4 omitida: usa -ConRegistro en la VM para probar deshabilitar y habilitar de verdad.)"
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
""
"Resultado: $($script:ok) bien, $($script:mal) fallos"
if ($script:mal -gt 0) { exit 1 }
