<#
.SYNOPSIS
    Autopruebas de la Fase 4 (diagnóstico de hardware y recomendaciones).
.DESCRIPTION
    Es de SOLO LECTURA: no cambia nada en el sistema (se puede ejecutar sin administrador y no pide confirmación).
    Las pruebas que simulan fallos o aplican "recomendados" usan funciones de prueba en memoria; nada se escribe.
    Comprueba: patrones de GPU con nombres reales, perfiles, detección de VM, tipo de disco, recomendaciones con
    perfiles simulados (Bajo, Medio, Alto), tolerancia a fallos y a tiempos agotados, que el diagnóstico no
    escribe nada, el bloqueo estricto de -PerfilSimulado y el diagnóstico REAL del equipo (con su duración).
    Este script NUNCA lo carga el cargador (está fuera de Core/, Modules/ y Tweaks/).
    Ejecutar en Windows PowerShell 5.1:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pruebas\Probar-Fase4.ps1
#>
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

. (Join-Path $raiz 'Core\Loader.ps1')
Import-OptiLowCore -Raiz $raiz
Initialize-OptiLowRutas -Raiz $raiz
Initialize-OptiLowLog -Destino Consola
$extras = Import-OptiLowExtras -Raiz $raiz

$script:bien = 0
$script:mal = 0
function T { param([string]$Nombre, [bool]$Condicion)
    if ($Condicion) { $script:bien++; Write-Host "  OK     $Nombre" -ForegroundColor Green }
    else { $script:mal++; Write-Host "  FALLA  $Nombre" -ForegroundColor Red } }
function Info { param([string]$Texto) Write-Host "  (info) $Texto" -ForegroundColor DarkGray }
function Seccion { param([string]$Texto) Write-Host ''; Write-Host "== $Texto ==" -ForegroundColor Cyan }
function TieneId { param($Hw, [string]$Id) return (@($Hw.Recomendaciones | Where-Object { $_.Id -eq $Id }).Count -gt 0) }

Seccion '1. Carga'
T 'Los módulos de Modules/ se cargaron sin errores' ($extras.Fallidos -eq 0)
T 'Existen Get-Diagnostico, Get-Recomendaciones y New-HardwareSimulado' ((Get-Command Get-Diagnostico, Get-Recomendaciones, New-HardwareSimulado -ErrorAction SilentlyContinue).Count -eq 3)
T 'Hay 3 optimizaciones registradas' (@(Get-Tweak).Count -eq 3)
foreach ($a in 'legacy-gpu-patterns.txt', 'unsupported-gpu-patterns.txt', 'virtual-gpu-patterns.txt') {
    T "Config\$a tiene patrones" (@(Read-PatronesConfig -Archivo $a).Count -gt 0)
}

# ---------------------------------------------------------------------------------------------
Seccion '2. Patrones de GPU contra nombres reales de Win32_VideoController'
$deben = @(
    'Intel(R) GMA 4500MHD', 'Mobile Intel(R) 4 Series Express Chipset Family', 'Intel(R) G41 Express Chipset', 'Intel(R) HD Graphics',
    'Intel(R) HD Graphics 2000', 'Intel(R) HD Graphics 2500', 'Intel(R) HD Graphics 3000', 'Intel(R) HD Graphics 4000',
    'NVIDIA GeForce 6600', 'NVIDIA GeForce 7300 GS', 'NVIDIA GeForce 8600 GT', 'NVIDIA GeForce 9400 GT', 'NVIDIA GeForce 9800 GTX+',
    'NVIDIA GeForce 210', 'NVIDIA GeForce 310M', 'NVIDIA GeForce G 105M', 'NVIDIA GeForce GT 220', 'NVIDIA GeForce GT 240',
    'NVIDIA GeForce GTS 250', 'NVIDIA GeForce GTX 260', 'NVIDIA GeForce GTX 295', 'NVIDIA GeForce GT 430', 'NVIDIA GeForce GTX 460',
    'NVIDIA GeForce GT 520', 'NVIDIA GeForce GT 540M', 'NVIDIA GeForce GTX 560 Ti', 'NVIDIA GeForce GTX 580',
    'ATI Radeon HD 4850', 'ATI Mobility Radeon HD 5470', 'AMD Radeon HD 5450', 'AMD Radeon HD 6450', 'AMD Radeon HD 6310 Graphics',
    'AMD Radeon HD 6520G', 'S3 Graphics ProSavage', 'SiS Mirage 3 Graphics', 'VIA/S3G UniChrome IGP', 'Matrox G200eW WDDM 1.2'
)
foreach ($n in $deben) { T "ANTIGUA (nivel 1): $n" ((Get-HwClasificacionGpu -Nombre $n).EsAntigua) }

$noDeben = @(
    'NVIDIA GeForce GTX 750 Ti', 'NVIDIA GeForce GTX 960', 'NVIDIA GeForce GTX 1660', 'NVIDIA GeForce GTX 1660 SUPER', 'NVIDIA GeForce GTX 1050',
    'NVIDIA GeForce GTX 1060 6GB', 'NVIDIA GeForce GT 1030', 'NVIDIA GeForce RTX 3060', 'NVIDIA GeForce RTX 4090', 'NVIDIA GeForce MX150',
    'NVIDIA GeForce 940MX', 'AMD Radeon RX 580', 'AMD Radeon RX 6600', 'AMD Radeon RX 7600', 'Intel(R) UHD Graphics 620', 'Intel(R) UHD Graphics',
    'Intel(R) Iris(R) Xe Graphics', 'Intel(R) Arc(TM) A380 Graphics', 'AMD Radeon(TM) Vega 8 Graphics', 'AMD Radeon(TM) Graphics',
    'Intel(R) HD Graphics 520', 'Intel(R) HD Graphics 4600', 'Intel(R) Iris(TM) Pro Graphics 5200', 'NVIDIA GeForce GT 730', 'AMD Radeon HD 7970',
    'AMD Radeon R7 200 Series'
)
foreach ($n in $noDeben) { T "NO antigua: $n" (-not (Get-HwClasificacionGpu -Nombre $n).EsAntigua) }

$nivel2 = @(
    'Intel(R) HD Graphics 4600', 'Intel(R) Iris(TM) Pro Graphics 5200', 'Intel(R) Iris(TM) Graphics 6100', 'Intel(R) HD Graphics 5500',
    'NVIDIA GeForce GT 730', 'NVIDIA GeForce GTX 650 Ti', 'NVIDIA GeForce GTX 780 Ti', 'NVIDIA GeForce GT 640', 'NVIDIA GeForce 710M',
    'AMD Radeon HD 7970', 'AMD Radeon HD 7640G', 'AMD Radeon R7 200 Series', 'AMD Radeon(TM) R5 Graphics', 'AMD Radeon R9 380X', 'AMD Radeon R9 Fury Series'
)
foreach ($n in $nivel2) {
    $c = Get-HwClasificacionGpu -Nombre $n
    T "SIN SOPORTE ACTIVO (nivel 2, solo Info, no antigua): $n" ($c.SinSoporteFabricante -and -not $c.EsAntigua)
}
$noNivel2 = @('NVIDIA GeForce GTX 750 Ti', 'NVIDIA GeForce GTX 960', 'NVIDIA GeForce GTX 1660', 'NVIDIA GeForce RTX 3060', 'AMD Radeon RX 580',
    'Intel(R) UHD Graphics 620', 'Intel(R) Iris(R) Xe Graphics', 'AMD Radeon(TM) Graphics', 'AMD Radeon(TM) Vega 8 Graphics')
foreach ($n in $noNivel2) { T "NO sin soporte (nivel 3 comentado o moderna): $n" (-not (Get-HwClasificacionGpu -Nombre $n).SinSoporteFabricante) }

foreach ($n in 'Microsoft Basic Render Driver', 'VMware SVGA 3D', 'VirtualBox Graphics Adapter (WDDM)', 'Microsoft Hyper-V Video', 'Microsoft Remote Display Adapter', 'Red Hat QXL controller', 'Parsec Virtual Display Adapter') {
    $c = Get-HwClasificacionGpu -Nombre $n
    T "VIRTUAL (se excluye, ni antigua ni sin driver): $n" ($c.EsVirtual -and -not $c.EsAntigua -and -not $c.SinDriver)
}
$c = Get-HwClasificacionGpu -Nombre 'Microsoft Basic Display Adapter'
T '"Microsoft Basic Display Adapter" = sin driver (no virtual)' ($c.SinDriver -and -not $c.EsVirtual)

# ---------------------------------------------------------------------------------------------
Seccion '3. Perfil (Bajo, Medio, Alto)'
$casos = @(
    @(4, 2, 'HDD', 'Bajo'), @(4, 8, 'SSD', 'Bajo'), @(8, 4, 'HDD', 'Bajo'), @(8, 4, 'SSD', 'Medio'), @(8, 2, 'SSD', 'Bajo'),
    @(16, 8, 'SSD', 'Alto'), @(16, 8, 'HDD', 'Medio'), @(32, 16, 'SSD', 'Alto'), @(16, 8, 'Desconocido', 'Medio'),
    @($null, $null, 'Desconocido', 'Desconocido'), @(8, $null, 'SSD', 'Medio'), @($null, 2, 'SSD', 'Bajo'), @(16, 6, 'SSD', 'Medio')
)
foreach ($k in $casos) {
    $p = Get-HwPerfil -RamGB $k[0] -Hilos $k[1] -TipoDisco $k[2]
    T ("RAM={0} hilos={1} disco={2} -> {3}" -f $k[0], $k[1], $k[2], $k[3]) ($p.Perfil -eq $k[3])
}

# ---------------------------------------------------------------------------------------------
Seccion '4. Detección de máquina virtual (no solo por fabricante)'
$vms = @(
    @('Microsoft Corporation', 'Virtual Machine', '', 'Hyper-V UEFI Release v4.1', $true),
    @('Microsoft Corporation', 'Surface Laptop 4', 'Microsoft Corporation', '1.2.3', $false),
    @('Microsoft Corporation', 'Surface Pro 9', 'Microsoft Corporation', '5.7.1', $false),
    @('VMware, Inc.', 'VMware7,1', 'VMware, Inc.', 'VMW71.00V.12345', $true),
    @('VMware, Inc.', 'VMware Virtual Platform', 'Phoenix Technologies LTD', '6.00', $true),
    @('innotek GmbH', 'VirtualBox', 'innotek GmbH', 'VirtualBox', $true),
    @('QEMU', 'Standard PC (Q35 + ICH9, 2009)', 'SeaBIOS', 'rel-1.16', $true),
    @('Parallels Software International Inc.', 'Parallels Virtual Platform', '', '', $true),
    @('Xen', 'HVM domU', 'Xen', '4.2', $true),
    @('Gigabyte Technology Co., Ltd.', 'B650 EAGLE AX', 'American Megatrends International, LLC.', 'F40', $false),
    @('Dell Inc.', 'Latitude 7420', 'Dell Inc.', '1.20.0', $false),
    @('Unknown', 'Standard PC (i440FX + PIIX, 1996)', 'Unknown', '1.0', $false)
)
foreach ($v in $vms) {
    $r = Test-HwMaquinaVirtual -Fabricante $v[0] -Modelo $v[1] -BiosFabricante $v[2] -BiosVersion $v[3]
    T ("{0} / {1} -> {2}" -f $v[0], $v[1], $(if ($v[4]) { 'VM' } else { 'equipo real' })) ($r.EsVM -eq $v[4])
}
$r = Test-HwMaquinaVirtual -Fabricante 'Desconocido' -Modelo 'x' -BiosFabricante '' -BiosVersion 'VBOX   - 1'
T 'Solo por BIOS (VBOX) = VM probable, con el motivo' ($r.EsVM -and $r.Motivo -match 'BIOS')

# ---------------------------------------------------------------------------------------------
Seccion '5. Tipo de disco (MediaType y, si es Unspecified, las inferencias)'
$discos = @(
    @(3, 11, 4294967295, 'WDC WD10EZEX', 'HDD'), @(4, 17, 0, 'Samsung 980', 'SSD'), @(5, 17, 0, 'Optane', 'SSD'),
    @(0, 17, 0, 'Disco raro', 'SSD'), @(0, 11, 7200, 'Disco raro', 'HDD'), @(0, 11, 4294967295, 'Disco raro', 'HDD'),
    @(0, 11, 0, 'Disco raro', 'SSD'), @(0, $null, $null, 'Samsung SSD 860 EVO', 'SSD'), @(0, $null, $null, 'Disco generico', 'Desconocido')
)
foreach ($d in $discos) {
    $r = Get-HwTipoDisco -MediaType $d[0] -BusType $d[1] -SpindleSpeed $d[2] -Modelo $d[3]
    T ("Media={0} Bus={1} giro={2} modelo='{3}' -> {4} ({5})" -f $d[0], $d[1], $d[2], $d[3], $d[4], $r.Origen) ($r.Tipo -eq $d[4])
}

# ---------------------------------------------------------------------------------------------
Seccion '6. Recomendaciones con perfiles simulados'
$bajo = New-HardwareSimulado -Perfil Bajo
$medio = New-HardwareSimulado -Perfil Medio
$alto = New-HardwareSimulado -Perfil Alto
T 'Los tres están marcados como simulados' ($bajo.Simulado -and $medio.Simulado -and $alto.Simulado)
T 'Perfiles: Bajo, Medio y Alto' (($bajo.Perfil -eq 'Bajo') -and ($medio.Perfil -eq 'Medio') -and ($alto.Perfil -eq 'Alto'))
foreach ($id in 'ram-4gb', 'disco-hdd', 'gpu-antigua', 'poco-espacio', 'gpu-driver-viejo', 'inicio-muchos', 'sin-reiniciar', 'consejo-paginacion', 'consejo-limpieza', 'consejo-navegador', 'consejo-antivirus') {
    T "Perfil Bajo genera: $id" (TieneId $bajo $id)
}
T 'Perfil Bajo: ranuras libres en el texto de la RAM' ((@($bajo.Recomendaciones | Where-Object { $_.Id -eq 'ram-4gb' })[0].Detalle) -match 'libre')
$drv = @($bajo.Recomendaciones | Where-Object { $_.Id -eq 'gpu-driver-viejo' })[0].Detalle
T 'Texto del driver: página oficial, Windows Update y no usar "actualizar drivers"' (($drv -match 'oficial') -and ($drv -match 'Windows Update') -and ($drv -match 'actualizar drivers'))
foreach ($id in 'ram-4gb', 'disco-hdd', 'gpu-antigua', 'inicio-muchos', 'sin-reiniciar', 'consejo-limpieza', 'consejo-paginacion') {
    T "Perfil Medio NO genera: $id" (-not (TieneId $medio $id))
}
T 'Perfil Medio: consejo del navegador (8 GB)' (TieneId $medio 'consejo-navegador')
foreach ($id in 'ram-4gb', 'disco-hdd', 'gpu-antigua', 'gpu-driver-viejo', 'poco-espacio', 'inicio-muchos', 'sin-reiniciar', 'consejo-limpieza', 'consejo-navegador', 'consejo-paginacion') {
    T "Perfil Alto NO genera: $id" (-not (TieneId $alto $id))
}
T 'Perfil Alto: el único aviso es el consejo del antivirus' (@($alto.Recomendaciones | Where-Object { $_.Nivel -ne 'Consejo' }).Count -eq 0)
$niveles = @($bajo.Recomendaciones | ForEach-Object { $_.Nivel })
$orden = @{ 'Crítico' = 0; 'Aviso' = 1; 'Info' = 2; 'Consejo' = 3 }
$ok = $true; for ($i = 1; $i -lt $niveles.Count; $i++) { if ($orden[$niveles[$i]] -lt $orden[$niveles[$i - 1]]) { $ok = $false } }
T 'Las recomendaciones salen ordenadas por nivel' $ok

Seccion '6b. Qué optimizaciones se recomiendan según el perfil (y por qué)'
$rb = @{}; foreach ($x in (Get-TweaksRecomendados -Hardware $bajo)) { $rb[$x.Id] = $x }
$rm = @{}; foreach ($x in (Get-TweaksRecomendados -Hardware $medio)) { $rm[$x.Id] = $x }
$ra = @{}; foreach ($x in (Get-TweaksRecomendados -Hardware $alto)) { $ra[$x.Id] = $x }
T 'Bajo: transparencias recomendadas, con el motivo "perfil Bajo" y "GPU antigua"' ($rb['efectos-transparencia-off'].Recomendado -and ($rb['efectos-transparencia-off'].Motivo -match 'perfil Bajo') -and ($rb['efectos-transparencia-off'].Motivo -match 'GPU antigua'))
T 'Bajo: tareas recomendadas (HDD)' ($rb['telemetria-tareas-off'].Recomendado -and ($rb['telemetria-tareas-off'].Motivo -match 'HDD'))
T 'Bajo: servicios recomendados (no administrado)' ($rb['telemetria-servicios-off'].Recomendado)
T 'Medio: transparencias NO, tareas NO, servicios SÍ' ((-not $rm['efectos-transparencia-off'].Recomendado) -and (-not $rm['telemetria-tareas-off'].Recomendado) -and $rm['telemetria-servicios-off'].Recomendado)
T 'Alto: transparencias NO, tareas NO' ((-not $ra['efectos-transparencia-off'].Recomendado) -and (-not $ra['telemetria-tareas-off'].Recomendado))
T 'Todos los motivos tienen texto' ((@($rb.Values) + @($rm.Values) + @($ra.Values) | Where-Object { -not $_.Motivo }).Count -eq 0)

function Copiar { param($Hw) return ($Hw | Select-Object *) }

# GPU sin driver
$h = Copiar $medio
$h.GPUPrincipal = [pscustomobject]@{ Nombre = 'Microsoft Basic Display Adapter'; DriverVersion = '10.0'; FechaDriver = $null; EdadDriverDias = $null; EsVirtual = $false; SinDriver = $true; EsAntigua = $false; SinSoporteFabricante = $false; PatronCoincidente = $null }
$h.Recomendaciones = @(Get-Recomendaciones -Hardware $h)
$rec = @($h.Recomendaciones | Where-Object { $_.Id -eq 'gpu-sin-driver' })
T 'GPU sin driver = Crítico' ($rec.Count -eq 1 -and $rec[0].Nivel -eq 'Crítico')
T 'GPU sin driver: transparencias recomendadas' ((Get-TweakRecomendacion -Id 'efectos-transparencia-off' -Hardware $h).Recomendado)

# GPU sin soporte (nivel 2) en equipo Medio: Info y NO recomienda
$h = Copiar $medio
$c2 = Get-HwClasificacionGpu -Nombre 'Intel(R) HD Graphics 4600'
$h.GPUPrincipal = [pscustomobject]@{ Nombre = 'Intel(R) HD Graphics 4600'; DriverVersion = '20.19'; FechaDriver = (Get-Date).AddDays(-100); EdadDriverDias = 100; EsVirtual = $false; SinDriver = $false; EsAntigua = $c2.EsAntigua; SinSoporteFabricante = $c2.SinSoporteFabricante; PatronCoincidente = $c2.Patron }
$h.Recomendaciones = @(Get-Recomendaciones -Hardware $h)
$rec = @($h.Recomendaciones | Where-Object { $_.Id -eq 'gpu-sin-soporte' })
T 'GPU sin soporte activo = Info (no Aviso)' ($rec.Count -eq 1 -and $rec[0].Nivel -eq 'Info')
T 'GPU sin soporte NO genera "gpu-antigua"' (-not (TieneId $h 'gpu-antigua'))
T 'GPU sin soporte NO recomienda las transparencias (perfil Medio)' (-not (Get-TweakRecomendacion -Id 'efectos-transparencia-off' -Hardware $h).Recomendado)

# Máquina virtual
$h = Copiar $bajo
$h.EsMaquinaVirtual = $true; $h.Hipervisor = 'VMware'; $h.MotivoVM = "fabricante 'VMware, Inc.'"
$h.GPUPrincipal = $null
$h.Disco = [pscustomobject]@{ Unidad = 'C:'; Modelo = 'VMware Virtual disk'; Tipo = 'HDD'; TipoOrigen = 'x'; EsNVMe = $false; Bus = 'SAS'; TamanoGB = 60; LibreGB = 30; LibrePct = 50; Salud = 'Unknown'; EsVirtual = $true; Fiable = $false }
$h.Recomendaciones = @(Get-Recomendaciones -Hardware $h)
T 'VM: aparece el Info "máquina virtual"' ((@($h.Recomendaciones | Where-Object { $_.Id -eq 'maquina-virtual' })[0].Nivel) -eq 'Info')
foreach ($id in 'gpu-sin-driver', 'gpu-antigua', 'gpu-sin-soporte', 'gpu-driver-viejo', 'disco-hdd', 'ram-4gb', 'disco-salud', 'disco-salud-desconocida', 'consejo-limpieza') {
    T "VM: sin alerta falsa '$id'" (-not (TieneId $h $id))
}
T 'VM: los avisos de uso del sistema sí se mantienen (inicio, sin reiniciar)' ((TieneId $h 'inicio-muchos') -and (TieneId $h 'sin-reiniciar'))
T 'VM: tareas no se recomiendan por el HDD virtual (pero sí por perfil Bajo, con el motivo correcto)' (((Get-TweakRecomendacion -Id 'telemetria-tareas-off' -Hardware $h).Motivo) -match 'perfil Bajo')

# Salud del disco y espacio
$h = Copiar $medio
$h.Disco = [pscustomobject]@{ Unidad = 'C:'; Modelo = 'Disco'; Tipo = 'SSD'; TipoOrigen = 'x'; EsNVMe = $false; Bus = 'SATA'; TamanoGB = 100; LibreGB = 9; LibrePct = 9; Salud = 'Warning'; EsVirtual = $false; Fiable = $true }
$h.Recomendaciones = @(Get-Recomendaciones -Hardware $h)
T 'Salud Warning = Crítico' ((@($h.Recomendaciones | Where-Object { $_.Id -eq 'disco-salud' })[0].Nivel) -eq 'Crítico')
T 'Menos del 15 % libre = Aviso' ((@($h.Recomendaciones | Where-Object { $_.Id -eq 'poco-espacio' })[0].Nivel) -eq 'Aviso')

# Administración (dsregcmd): bloquean DomainJoined, AzureAdJoined, EnterpriseJoined y PartOfDomain; WorkplaceJoined solo avisa
function ConAdmin { param($Hw, $Admin) $x = Copiar $Hw; $x.Administracion = [pscustomobject]$Admin; $x.Recomendaciones = @(Get-Recomendaciones -Hardware $x); return $x }
$base = @{ Administrado = $false; Bloqueantes = @(); PartOfDomain = $false; AzureAdJoined = $false; EnterpriseJoined = $false; DomainJoined = $false; WorkplaceJoined = $false; AvisoWorkplace = ''; Error = '' }
foreach ($campo in 'AzureAdJoined', 'EnterpriseJoined', 'DomainJoined', 'PartOfDomain') {
    $a = $base.Clone(); $a[$campo] = $true; $a.Administrado = $true; $a.Bloqueantes = @("$campo = YES")
    $h = ConAdmin $bajo $a
    T "$campo = YES bloquea telemetria-servicios-off y muestra la advertencia" ((-not (Get-TweakRecomendacion -Id 'telemetria-servicios-off' -Hardware $h).Recomendado) -and (TieneId $h 'equipo-administrado'))
}
$a = $base.Clone(); $a.WorkplaceJoined = $true; $a.AvisoWorkplace = 'Hay una cuenta del trabajo...'
$h = ConAdmin $bajo $a
T 'WorkplaceJoined = YES NO bloquea: sigue recomendada, solo aviso Info' ((Get-TweakRecomendacion -Id 'telemetria-servicios-off' -Hardware $h).Recomendado -and (TieneId $h 'cuenta-trabajo'))
$a = $base.Clone(); $a.Administrado = $null; $a.AzureAdJoined = $null; $a.DomainJoined = $null; $a.EnterpriseJoined = $null; $a.WorkplaceJoined = $null; $a.Error = 'dsregcmd falló'
$h = ConAdmin $bajo $a
T 'dsregcmd sin datos: no se recomienda (precaución) y se explica' ((-not (Get-TweakRecomendacion -Id 'telemetria-servicios-off' -Hardware $h).Recomendado) -and (TieneId $h 'administracion-desconocida'))
$a = $base.Clone(); $a.WorkplaceJoined = $null
$h = ConAdmin $bajo $a
T 'WorkplaceJoined sin determinar: se ignora, no bloquea' ((Get-TweakRecomendacion -Id 'telemetria-servicios-off' -Hardware $h).Recomendado)

# Consultas fallidas
$h = Copiar $medio
$h.Consultas = @([pscustomobject]@{ Nombre = 'GPU'; Estado = 'TiempoAgotado'; Ms = 15000; Error = 'x' })
$h.Recomendaciones = @(Get-Recomendaciones -Hardware $h)
T 'Consultas fallidas: Info "datos incompletos" que las nombra' ((@($h.Recomendaciones | Where-Object { $_.Id -eq 'datos-incompletos' })[0].Detalle) -match 'GPU')

# ---------------------------------------------------------------------------------------------
Seccion '7. Tolerancia a fallos y a tiempos agotados'
$sw = [Diagnostics.Stopwatch]::StartNew()
$global:OptiLow.HwTimeoutSeg = 2
$global:OptiLow.HwConsultas = New-Object System.Collections.ArrayList
$lenta = Invoke-ConsultaHw -Nombre 'Prueba.Lenta' -Bloque { Get-CimInstance -Query "SELECT * FROM CIM_DataFile WHERE Drive='C:' AND Extension='dll'" -OperationTimeoutSec 2 -ErrorAction Stop }
$sw.Stop()
T "Una consulta CIM lenta se corta con -OperationTimeoutSec (estado $($lenta.Estado), $($lenta.Ms) ms)" (($lenta.Estado -eq 'TiempoAgotado') -and ($lenta.Ms -lt 8000))
$mala = Invoke-ConsultaHw -Nombre 'Prueba.Error' -Bloque { throw 'fallo de prueba' }
T 'Una consulta que lanza un error queda como Error y no detiene nada' (($mala.Estado -eq 'Error') -and ($mala.Valor.Count -eq 0))
$global:OptiLow.HwTimeoutSeg = 15

# Se sustituye Get-CimHw para que la GPU y la RAM fallen, y se comprueba que el resto sigue
function global:Get-CimHw {
    param([string]$Clase, [string]$Namespace = 'root/cimv2', [string]$Filtro)
    if (@('Win32_VideoController', 'Win32_PhysicalMemory') -contains $Clase) { throw "fallo simulado en $Clase" }
    $p = @{ Namespace = $Namespace; ClassName = $Clase; OperationTimeoutSec = 15; ErrorAction = 'Stop' }
    if ($Filtro) { $p.Filter = $Filtro }
    return @(Get-CimInstance @p)
}
$hw = Get-Diagnostico -Forzar
Import-OptiLowArchivo -Ruta (Join-Path $raiz 'Modules\Hardware.ps1')
T 'El diagnóstico termina aunque fallen la GPU y los módulos de RAM' ($null -ne $hw)
T 'La GPU queda desconocida (sin elementos) y la consulta marcada Error' ((@($hw.GPUs).Count -eq 0) -and (@($hw.Consultas | Where-Object { $_.Nombre -eq 'GPU' -and $_.Estado -eq 'Error' }).Count -eq 1))
T 'El resto sigue: CPU y disco se leyeron' (($null -ne $hw.CPU) -and ($null -ne $hw.Disco.TamanoGB))
T 'La RAM usa el respaldo (total reportado, aproximado)' (($hw.RAM.Fuente -match 'aproximado') -and ($null -ne $hw.RAM.InstaladaGB))
T 'Aparece el Info "datos incompletos"' (TieneId $hw 'datos-incompletos')
T 'No hay alerta de GPU por una GPU desconocida' (-not (TieneId $hw 'gpu-sin-driver') -and -not (TieneId $hw 'gpu-antigua'))

# ---------------------------------------------------------------------------------------------
Seccion '8. El diagnóstico solo lee'
$prohibidas = @('Set-RegistroValor', 'Remove-RegistroValor', 'Set-ServicioInicio', 'Disable-TareaProgramada', 'Write-ArchivoTexto', 'Set-JsonValor',
    'Set-PlanEnergia', 'Add-JournalEntrada', 'Start-JournalSesion', 'New-PuntoRestauracion', 'Enable-ProteccionSistema', 'Invoke-Tweak', 'Invoke-TweaksLote', 'Undo-JournalSesion')
foreach ($f in 'Modules\Hardware.ps1', 'Modules\Recomendaciones.ps1') {
    $ruta = Join-Path $raiz $f
    $texto = [IO.File]::ReadAllText($ruta)
    $malos = @(Get-ComandosProhibidosEnBloque -Texto $texto)
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($texto, [ref]$null, [ref]$null)
    $llamadas = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $prohibidas -contains $_ })
    T "$f no usa comandos de escritura ni funciones de Core que escriben" (($malos.Count -eq 0) -and ($llamadas.Count -eq 0))
}
$global:OptiLow.Journal = $null
$hwReal = Get-Diagnostico -Forzar
T 'Tras el diagnóstico no se abrió ninguna sesión del journal' ($null -eq $global:OptiLow.Journal)
T 'Win32_Product no se usa en ningún archivo de Modules/ (los comentarios que lo mencionan no cuentan)' (@(Get-ChildItem (Join-Path $raiz 'Modules') -Filter *.ps1 | Select-String -Pattern 'Win32_Product' -SimpleMatch | Where-Object { $_.Line.TrimStart() -notmatch '^#' }).Count -eq 0)

# ---------------------------------------------------------------------------------------------
Seccion '9. -PerfilSimulado: bloqueo estricto'
$global:OptiLow.SimulacionActiva = $true
$msg = $null; try { Assert-JournalListo } catch { $msg = $_.Exception.Message }
T 'Assert-JournalListo se niega con un perfil simulado' ($msg -match 'SIMULADO')
$k = 'HKCU:\Software\OptiLowPruebaFase4'
$msg = $null; try { [void](Set-RegistroValor -Ruta $k -Nombre 'v' -Valor 1 -Tipo DWord) } catch { $msg = $_.Exception.Message }
T 'Las funciones de escritura de Core/ se niegan y no crean nada' (($msg -match 'SIMULADO') -and -not (Get-RegistroEstado -Ruta $k -Nombre 'v').ClaveExiste)
$msg = $null; try { [void](Invoke-Tweak -Id 'efectos-transparencia-off') } catch { $msg = $_.Exception.Message }
T 'Invoke-Tweak se niega' ($msg -match 'SIMULADO')
$msg = $null; try { [void](Undo-JournalSesion) } catch { $msg = $_.Exception.Message }
T 'Undo-JournalSesion se niega' ($msg -match 'SIMULADO')
$c = [int](@(Invoke-AplicarConsola -Recomendados -SinPreguntar -SinPuntoRestauracion)[-1])
T 'Invoke-AplicarConsola -Recomendados se niega (código 1)' ($c -eq 1)
$global:OptiLow.SimulacionActiva = $false

Seccion '9b. -Aplicar recomendados (flujo completo con funciones de prueba: no se aplica nada de verdad)'
$script:idsLote = $null; $script:llamadasLote = 0
function global:Assert-JournalListo { param([switch]$Completo) }
function global:Start-JournalSesion { param([switch]$Nueva) 'sesion-de-prueba' }
function global:Get-TweakEstado { param([string]$Id) [pscustomobject]@{ Id = $Id; Estado = 'Pendiente'; Detalle = '' } }
function global:Invoke-TweaksLote { param([string[]]$Ids) $script:llamadasLote++; $script:idsLote = @($Ids); [pscustomobject]@{ Resultados = @(); Requiere = 'Nada'; TweaksQueRequieren = @() } }
function global:Show-ResumenConsola { param($Lote) }
function global:Get-Diagnostico { param([switch]$Forzar, [int]$TimeoutSeg) $script:hwPrueba }
foreach ($perfil in 'Bajo', 'Medio', 'Alto') {
    $script:hwPrueba = New-HardwareSimulado -Perfil $perfil
    $script:idsLote = $null; $script:llamadasLote = 0
    $c = [int](@(Invoke-AplicarConsola -Recomendados -SinPreguntar -SinPuntoRestauracion)[-1])
    $esperados = @((Get-TweaksRecomendados -Hardware $script:hwPrueba) | Where-Object { $_.Seleccionable } | ForEach-Object { $_.Id })
    $tx = @($script:idsLote) -join ', '
    Info "Perfil $perfil -> se aplicarían: $tx"
    T "Perfil ${perfil}: aplica exactamente las recomendadas pendientes" ((($tx) -eq ($esperados -join ', ')) -and ($c -eq 0))
}
$script:hwPrueba = New-HardwareSimulado -Perfil Bajo
$script:idsLote = $null
$c = [int](@(Invoke-AplicarConsola -Ids 'telemetria-tareas-off' -Recomendados -SinPreguntar -SinPuntoRestauracion)[-1])
T 'Se pueden combinar Ids explícitos con "recomendados" (sin duplicados)' ((@($script:idsLote | Select-Object -Unique).Count -eq @($script:idsLote).Count) -and (@($script:idsLote) -contains 'telemetria-tareas-off'))
function global:Get-TweakEstado { param([string]$Id) [pscustomobject]@{ Id = $Id; Estado = 'Aplicado'; Detalle = '' } }
$script:llamadasLote = 0
$c = [int](@(Invoke-AplicarConsola -Recomendados -SinPreguntar -SinPuntoRestauracion)[-1])
T 'Si todo está ya aplicado: "nada que aplicar" (código 0) sin llamar al lote' (($c -eq 0) -and ($script:llamadasLote -eq 0))
# Se restauran las funciones reales
foreach ($a in 'Core\Journal.ps1', 'Core\Tweaks.ps1', 'Core\Consola.ps1', 'Modules\Hardware.ps1') { Import-OptiLowArchivo -Ruta (Join-Path $raiz $a) }
T 'Funciones reales restauradas' ((Get-Command Invoke-TweaksLote).ScriptBlock.ToString() -match 'Assert-JournalListo')

# ---------------------------------------------------------------------------------------------
Seccion '10. OptiLow.ps1 como proceso hijo (parámetros nuevos; sin administrador y SIN aplicar nada)'
$ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script1 = Join-Path $raiz 'OptiLow.ps1'
function Invoke-Hijo {
    # Proceso hijo con salida y errores capturados por separado (sin mezclar el stderr de un programa nativo en 5.1)
    param([string[]]$Argumentos)
    $partes = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $script1) + $Argumentos
    $cadena = ($partes | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $ps
    $info.Arguments = $cadena
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $proc = [System.Diagnostics.Process]::Start($info)
    $tOut = $proc.StandardOutput.ReadToEndAsync()
    $tErr = $proc.StandardError.ReadToEndAsync()
    [void]$proc.WaitForExit(120000)
    $r = [pscustomobject]@{ Codigo = $proc.ExitCode; Salida = ($tOut.Result + "`n" + $tErr.Result) }
    $proc.Dispose()
    return $r
}
foreach ($p in 'Bajo', 'Medio', 'Alto') {
    $h = Invoke-Hijo @('-SinElevar', '-Diagnostico', '-PerfilSimulado', $p)
    T "-Diagnostico -PerfilSimulado ${p}: código 0, dice SIMULADO y muestra el perfil" (($h.Codigo -eq 0) -and ($h.Salida -match 'SIMULADO') -and ($h.Salida -match "PERFIL: $p"))
}
$h = Invoke-Hijo @('-SinElevar', '-Diagnostico', '-PerfilSimulado', 'Bajo', '-Aplicar', 'efectos-transparencia-off')
T '-PerfilSimulado con -Aplicar: código 1 (bloqueo estricto)' ($h.Codigo -eq 1)
$h = Invoke-Hijo @('-SinElevar', '-Diagnostico', '-PerfilSimulado', 'Bajo', '-Aplicar', 'recomendados')
T '-PerfilSimulado con -Aplicar recomendados: código 1' ($h.Codigo -eq 1)
$h = Invoke-Hijo @('-SinElevar', '-Diagnostico', '-PerfilSimulado', 'Bajo', '-Deshacer')
T '-PerfilSimulado con -Deshacer: código 1' ($h.Codigo -eq 1)
$h = Invoke-Hijo @('-SinElevar', '-PerfilSimulado', 'Bajo')
T '-PerfilSimulado sin -Diagnostico: código 1' ($h.Codigo -eq 1)
$h = Invoke-Hijo @('-SinElevar', '-PerfilSimulado', 'Extremo', '-Diagnostico')
T '-PerfilSimulado con un valor no válido: código distinto de 0' ($h.Codigo -ne 0)
$h = Invoke-Hijo @('-SinElevar', '-Aplicar')
T '-Aplicar sin valor: no aplica nada (código distinto de 0)' ($h.Codigo -ne 0)

# ---------------------------------------------------------------------------------------------
Seccion '11. Salida de consola del diagnóstico simulado'
$txt = (Show-DiagnosticoConsola -Hardware (New-HardwareSimulado -Perfil Bajo) 6>&1 | Out-String)
T 'Muestra SIMULADO, el perfil, las recomendaciones y las optimizaciones recomendadas' (($txt -match 'SIMULADO') -and ($txt -match 'PERFIL: Bajo') -and ($txt -match '--- Recomendaciones ---') -and ($txt -match 'RECOMENDADA'))
T 'Muestra por qué se recomienda cada una' ($txt -match 'GPU antigua')

# ---------------------------------------------------------------------------------------------
Seccion '13. Correcciones tras la VM (el 0 es un dato válido; los datos que faltan quedan como consulta fallida; textos legibles)'
T 'Format-ValorHw: 0 y 0.0 se muestran como 0; null y "" como desconocido' (((Format-ValorHw 0) -eq '0') -and ((Format-ValorHw ([double]0)) -eq '0') -and ((Format-ValorHw $null) -eq 'desconocido') -and ((Format-ValorHw '') -eq 'desconocido'))
$h = New-HardwareSimulado -Perfil Medio
$h.ArranqueDias = 0.0
$txt = (Show-DiagnosticoConsola -Hardware $h 6>&1 | Out-String)
T 'Equipo recién encendido: "Arranque: 0 días encendido" (no "desconocido")' (($txt -match 'Arranque:\s+0 días encendido') -and ($txt -notmatch 'desconocido días'))
$h.ArranqueDias = $null
$txt = (Show-DiagnosticoConsola -Hardware $h 6>&1 | Out-String)
T 'Sin dato: "tiempo encendido desconocido" (frase legible)' (($txt -match 'tiempo encendido desconocido') -and ($txt -notmatch 'desconocido días'))
$sinMod = [pscustomobject]@{ InstaladaGB = 4; Modulos = $null; RanurasTotales = $null; RanurasLibres = $null; VelocidadMHz = $null }
$t1 = Format-RamHw -Ram $sinMod
T "RAM sin detalle de módulos: '$t1'" (($t1 -match 'detalle de módulos no disponible') -and ($t1 -notmatch 'desconocido') -and ($t1 -notmatch ';\s*;'))
$cero = [pscustomobject]@{ InstaladaGB = 8; Modulos = 2; RanurasTotales = 2; RanurasLibres = 0; VelocidadMHz = 0 }
$t2 = Format-RamHw -Ram $cero
T "0 ranuras libres se muestra como 0: '$t2'" (($t2 -match 'ranuras libres: 0 de 2') -and ($t2 -notmatch 'desconocido'))
$t3 = Format-RamHw -Ram $null
T 'RAM completamente desconocida: "desconocido"' ($t3 -eq 'desconocido')
$bajoT = New-HardwareSimulado -Perfil Bajo
$tit = @($bajoT.Recomendaciones | Where-Object { $_.Id -eq 'poco-espacio' })[0].Titulo
T "Título de poco espacio sin doble dos puntos: '$tit'" (($tit -notmatch '::') -and ($tit -match 'C:'))

# Un dato que falta aunque la consulta "termine bien" queda como consulta Desconocida y sale el Info
function global:Get-CimHw {
    param([string]$Clase, [string]$Namespace = 'root/cimv2', [string]$Filtro)
    if ($Clase -eq 'Win32_OperatingSystem') { return @([pscustomobject]@{ Caption = 'Windows de prueba'; Version = '10.0'; BuildNumber = '26100'; OSArchitecture = '64 bits'; LastBootUpTime = $null }) }
    if (@('Win32_PhysicalMemory', 'Win32_PhysicalMemoryArray') -contains $Clase) { return @() }
    $p = @{ Namespace = $Namespace; ClassName = $Clase; OperationTimeoutSec = 15; ErrorAction = 'Stop' }
    if ($Filtro) { $p.Filter = $Filtro }
    return @(Get-CimInstance @p)
}
$hwF = Get-Diagnostico -Forzar
Import-OptiLowArchivo -Ruta (Join-Path $raiz 'Modules\Hardware.ps1')
$nombres = @($hwF.Consultas | Where-Object { $_.Estado -ne 'Ok' } | ForEach-Object { $_.Nombre })
Info ('Consultas no Ok: ' + ($nombres -join ', '))
T 'LastBootUpTime vacío: la consulta "Sistema.ArranqueDias" queda como Desconocido' ($nombres -contains 'Sistema.ArranqueDias')
T 'Sin módulos de RAM: "RAM.Modulos" y "RAM.Ranuras" quedan como Desconocido' (($nombres -contains 'RAM.Modulos') -and ($nombres -contains 'RAM.Ranuras'))
T 'Sale el Info "datos incompletos" nombrando ArranqueDias' ((@($hwF.Recomendaciones | Where-Object { $_.Id -eq 'datos-incompletos' })[0].Detalle) -match 'ArranqueDias')
T 'No hay consultas duplicadas por el mismo origen' ((@($hwF.Consultas | Group-Object Nombre | Where-Object { $_.Count -gt 1 }).Count) -eq 0)
$salidaF = (Show-DiagnosticoConsola -Hardware $hwF 6>&1 | Out-String)
T 'En la consola: tiempo encendido desconocido y RAM legible' (($salidaF -match 'tiempo encendido desconocido') -and ($salidaF -match 'detalle de módulos no disponible'))
# ---------------------------------------------------------------------------------------------
Seccion '12. DIAGNÓSTICO REAL de este equipo'
$hw = $hwReal
T 'Duración registrada' ($hw.DuracionMs -gt 0)
Info ("Duración total: {0:N1} s en {1} consultas" -f ($hw.DuracionMs / 1000), @($hw.Consultas).Count)
foreach ($q in @($hw.Consultas | Sort-Object Ms -Descending | Select-Object -First 5)) { Info ("   {0,-24} {1,-14} {2} ms" -f $q.Nombre, $q.Estado, $q.Ms) }
T 'Cada consulta tiene nombre, estado y milisegundos' (@($hw.Consultas | Where-Object { (-not $_.Nombre) -or (-not $_.Estado) -or ($null -eq $_.Ms) }).Count -eq 0)
$props = 'Version', 'FechaHora', 'DuracionMs', 'Simulado', 'EsMaquinaVirtual', 'Hipervisor', 'Equipo', 'Windows', 'CPU', 'RAM', 'GPUs', 'GPUPrincipal', 'Disco', 'EsPortatil', 'ArranqueDias', 'InicioRapido', 'ProgramasInicio', 'Administracion', 'Perfil', 'PerfilMotivo', 'Consultas', 'Recomendaciones'
T 'El objeto tiene todas las propiedades que usará la interfaz' (@($props | Where-Object { -not $hw.PSObject.Properties[$_] }).Count -eq 0)
T 'No está marcado como simulado' (-not $hw.Simulado)
Info "Equipo: $($hw.Equipo.Fabricante) $($hw.Equipo.Modelo) | VM: $($hw.EsMaquinaVirtual) $($hw.Hipervisor) $($hw.MotivoVM)"
Info "Perfil: $($hw.Perfil) ($($hw.PerfilMotivo))"
if ($hw.CPU) { Info "CPU: $($hw.CPU.Nombre) $($hw.CPU.Nucleos)/$($hw.CPU.Hilos)" }
Info ('RAM: ' + (Format-RamHw -Ram $hw.RAM))
foreach ($g in $hw.GPUs) { Info "GPU: $($g.Nombre) | virtual=$($g.EsVirtual) sinDriver=$($g.SinDriver) antigua=$($g.EsAntigua) sinSoporte=$($g.SinSoporteFabricante)" }
if ($hw.Disco) { Info "Disco: $($hw.Disco.Modelo) | $($hw.Disco.Tipo) ($($hw.Disco.TipoOrigen)) | bus $($hw.Disco.Bus) | salud $($hw.Disco.Salud) | libre $($hw.Disco.LibrePct) % | virtual=$($hw.Disco.EsVirtual)" }
Info "Inicio: $($hw.ProgramasInicio.Habilitados) habilitados, $($hw.ProgramasInicio.Deshabilitados) deshabilitados (compáralos con el Administrador de tareas > Aplicaciones de inicio)"
Info "Administración: administrado=$($hw.Administracion.Administrado) Azure=$($hw.Administracion.AzureAdJoined) Dominio=$($hw.Administracion.DomainJoined) Enterprise=$($hw.Administracion.EnterpriseJoined) Workplace=$($hw.Administracion.WorkplaceJoined) $($hw.Administracion.Error)"
T 'dsregcmd se pudo leer (AzureAdJoined conocido)' ($null -ne $hw.Administracion.AzureAdJoined)
if ($hw.EsMaquinaVirtual) {
    T 'Es una VM: se muestra el Info de VM' (TieneId $hw 'maquina-virtual')
    foreach ($id in 'gpu-sin-driver', 'gpu-antigua', 'gpu-sin-soporte', 'gpu-driver-viejo', 'disco-hdd', 'ram-4gb') { T "VM real: sin alerta falsa '$id'" (-not (TieneId $hw $id)) }
}
Info 'Recomendaciones del diagnóstico real:'
foreach ($r in $hw.Recomendaciones) { Info ("   [{0}] {1}" -f $r.Nivel, $r.Titulo) }

Write-Host ''
$color = 'Green'; if ($script:mal -gt 0) { $color = 'Red' }
Write-Host "Resultado: $($script:bien) bien, $($script:mal) con fallos." -ForegroundColor $color
exit $(if ($script:mal -eq 0) { 0 } else { 1 })
