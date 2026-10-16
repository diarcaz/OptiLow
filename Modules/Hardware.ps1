# Modules/Hardware.ps1
# Diagnóstico de hardware. SOLO LEE: no escribe nada en el sistema ni en el journal.
#
# - Cada consulta (CPU, RAM, GPU, disco, batería, etc.) va por separado con cronómetro y límite de tiempo.
#   Si una falla o se pasa del tiempo, se marca como Desconocido y el resto sigue.
# - Se usa Get-CimInstance -OperationTimeoutSec (verificado en Windows PowerShell 5.1: corta una consulta CIM local).
#   Nunca Win32_Product (lentísimo y dispara reparaciones de MSI) ni Get-WmiObject.
# - Resultado: UN objeto que la interfaz de la fase 5 puede usar tal cual (ver Get-Diagnostico).
# - Fuentes de datos verificadas en Microsoft Learn: MSFT_PhysicalDisk (MediaType, BusType, SpindleSpeed,
#   HealthStatus), MSFT_Partition/MSFT_Disk, Win32_PhysicalMemory(+Array), Win32_VideoController, Win32_Battery,
#   Win32_ComputerSystem, dsregcmd /status.

$global:OptiLowHwTimeoutPorDefecto = 15

function Get-HwTimeoutSeg {
    $t = $global:OptiLowHwTimeoutPorDefecto
    if ($global:OptiLow -and $global:OptiLow.ContainsKey('HwTimeoutSeg') -and $global:OptiLow.HwTimeoutSeg) { $t = [int]$global:OptiLow.HwTimeoutSeg }
    return $t
}

function Get-CimHw {
    # Auxiliar interna: consulta CIM de solo lectura con límite de tiempo.
    param(
        [Parameter(Mandatory)][string]$Clase,
        [string]$Namespace = 'root/cimv2',
        [string]$Filtro
    )
    $parametros = @{ Namespace = $Namespace; ClassName = $Clase; OperationTimeoutSec = (Get-HwTimeoutSeg); ErrorAction = 'Stop' }
    if ($Filtro) { $parametros.Filter = $Filtro }
    return @(Get-CimInstance @parametros)
}

function Invoke-ConsultaHw {
    <#
    .SYNOPSIS
        Ejecuta una consulta del diagnóstico de forma aislada: cronómetro, captura de errores y registro en
        la lista de consultas del diagnóstico en curso.
    .OUTPUTS
        Objeto con Nombre, Estado (Ok, Desconocido, TiempoAgotado, Error), Ms, Error y Valor (siempre un arreglo).
    #>
    param(
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)][scriptblock]$Bloque
    )

    $reloj = [System.Diagnostics.Stopwatch]::StartNew()
    $estado = 'Ok'
    $error1 = ''
    $valor = @()
    try {
        $valor = @(& $Bloque)
    }
    catch {
        $error1 = $_.Exception.Message
        $estado = 'Error'
        if (($_.Exception.GetType().Name -eq 'CimException') -and ($reloj.Elapsed.TotalSeconds -ge ((Get-HwTimeoutSeg) - 1))) {
            $estado = 'TiempoAgotado'
        }
        Write-Log -Nivel DEBUG -Mensaje "Diagnóstico: la consulta '$Nombre' falló ($estado): $error1"
    }
    $reloj.Stop()

    $r = [pscustomobject]@{ Nombre = $Nombre; Estado = $estado; Ms = [int]$reloj.ElapsedMilliseconds; Error = $error1; Valor = $valor }
    # OJO: una lista vacía es "falsa" en PowerShell; hay que comparar con $null
    if ($global:OptiLow -and $global:OptiLow.ContainsKey('HwConsultas') -and ($null -ne $global:OptiLow.HwConsultas)) {
        [void]$global:OptiLow.HwConsultas.Add([pscustomobject]@{ Nombre = $r.Nombre; Estado = $r.Estado; Ms = $r.Ms; Error = $r.Error })
    }
    return $r
}

function Add-DatoDesconocido {
    <#
    .SYNOPSIS
        Anota como consulta Desconocida un dato que ninguna consulta pudo dar, aunque la consulta "terminara bien"
        (por ejemplo, LastBootUpTime vacío). Así un dato que falta SIEMPRE queda reflejado y sale el Info de
        "datos incompletos". No duplica si la consulta de origen ya figura como fallida.
    #>
    param(
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)][string]$Motivo,
        [string]$Origen = ''
    )

    $e = $global:OptiLow
    if ((-not $e) -or (-not $e.ContainsKey('HwConsultas')) -or ($null -eq $e.HwConsultas)) { return }
    # La misma consulta ya figura como "Ok" pero sin datos útiles: se corrige su estado en vez de duplicarla
    foreach ($c in $e.HwConsultas) {
        if (($c.Nombre -eq $Nombre) -and ($c.Estado -eq 'Ok')) {
            $c.Estado = 'Desconocido'
            $c.Error = $Motivo
            return
        }
    }
    if ($Origen) {
        foreach ($c in $e.HwConsultas) {
            if (($c.Estado -ne 'Ok') -and ($c.Nombre -like "$Origen*")) { return }
        }
    }
    [void]$e.HwConsultas.Add([pscustomobject]@{ Nombre = $Nombre; Estado = 'Desconocido'; Ms = 0; Error = $Motivo })
}

function Test-DatosDiagnostico {
    # Auxiliar interna: revisa los datos recolectados y anota como Desconocido los que faltan.
    param(
        $Equipo, $Sistema, $Cpu, $Ram, $Gpus, $Disco
    )

    $vm = ($Equipo.EsMaquinaVirtual -eq $true)
    if (-not $Equipo.Modelo) { Add-DatoDesconocido -Nombre 'Equipo.Modelo' -Motivo 'fabricante y modelo no disponibles' -Origen 'Equipo' }
    if (-not $Sistema.Nombre) { Add-DatoDesconocido -Nombre 'Sistema.Nombre' -Motivo 'nombre de Windows no disponible' -Origen 'Sistema' }
    if ($null -eq $Sistema.ArranqueDias) { Add-DatoDesconocido -Nombre 'Sistema.ArranqueDias' -Motivo 'LastBootUpTime no disponible (no se puede calcular el tiempo encendido)' -Origen 'Sistema' }
    if ($Cpu -and ($null -eq $Cpu.Hilos)) { Add-DatoDesconocido -Nombre 'CPU.Hilos' -Motivo 'el número de hilos no está disponible' -Origen 'CPU' }
    if ($Ram) {
        if ($null -eq $Ram.InstaladaGB) { Add-DatoDesconocido -Nombre 'RAM.Capacidad' -Motivo 'capacidad de RAM no disponible' -Origen 'RAM' }
        if ($null -eq $Ram.Modulos) { Add-DatoDesconocido -Nombre 'RAM.Modulos' -Motivo 'detalle de módulos no disponible' -Origen 'RAM.Modulos' }
        if ($null -eq $Ram.RanurasTotales) { Add-DatoDesconocido -Nombre 'RAM.Ranuras' -Motivo 'número de ranuras no disponible' -Origen 'RAM.Ranuras' }
    }
    if ((-not $vm) -and (@($Gpus | Where-Object { -not $_.EsVirtual }).Count -eq 0)) { Add-DatoDesconocido -Nombre 'GPU.Principal' -Motivo 'no se detectó ninguna GPU real' -Origen 'GPU' }
    if ($Disco) {
        if ((-not $vm) -and ($Disco.Tipo -eq 'Desconocido')) { Add-DatoDesconocido -Nombre 'Disco.Tipo' -Motivo 'no se pudo determinar si es HDD o SSD' -Origen 'Disco' }
        if ($null -eq $Disco.TamanoGB) { Add-DatoDesconocido -Nombre 'Disco.Espacio' -Motivo 'tamaño y espacio libre no disponibles' -Origen 'Disco' }
        if ((-not $vm) -and (-not $Disco.Salud)) { Add-DatoDesconocido -Nombre 'Disco.Salud' -Motivo 'salud del disco no disponible' -Origen 'Disco' }
    }
}

# ---------------------------------------------------------------------------------------------
# Patrones editables (Config/*.txt)
# ---------------------------------------------------------------------------------------------

function Read-PatronesConfig {
    <#
    .SYNOPSIS
        Lee un archivo de patrones de Config/: texto que contiene, o 're:expresión'. Ignora # y líneas vacías.
    #>
    param(
        [Parameter(Mandatory)][string]$Archivo
    )

    $e = $global:OptiLow
    if (-not $e.ContainsKey('CachePatrones')) { $e.CachePatrones = @{} }
    if ($e.CachePatrones.ContainsKey($Archivo)) { return $e.CachePatrones[$Archivo] }

    $lista = New-Object System.Collections.ArrayList
    $ruta = [System.IO.Path]::Combine($e.Raiz, 'Config', $Archivo)
    if (-not (Test-Path -LiteralPath $ruta)) {
        Write-Log -Nivel WARN -Mensaje "No existe Config\$Archivo; se trabaja sin esos patrones."
    }
    else {
        foreach ($linea in [System.IO.File]::ReadAllLines($ruta, [System.Text.Encoding]::UTF8)) {
            $t = $linea.Trim()
            if ((-not $t) -or $t.StartsWith('#')) { continue }
            if ($t -match '^re:(.+)$') {
                $expr = $Matches[1]
                try {
                    $rx = New-Object System.Text.RegularExpressions.Regex($expr, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    [void]$lista.Add([pscustomobject]@{ Tipo = 'regex'; Texto = $expr; Regex = $rx })
                }
                catch {
                    Write-Log -Nivel WARN -Mensaje "Config\${Archivo}: expresión regular no válida '$expr' (se ignora): $($_.Exception.Message)"
                }
            }
            else {
                [void]$lista.Add([pscustomobject]@{ Tipo = 'texto'; Texto = $t; Regex = $null })
            }
        }
    }
    $e.CachePatrones[$Archivo] = @($lista)
    return $e.CachePatrones[$Archivo]
}

function Find-PatronCoincidente {
    # Auxiliar interna: devuelve el texto del primer patrón que coincide con el nombre, o $null.
    param(
        [AllowEmptyString()][string]$Nombre,
        [object[]]$Patrones
    )
    foreach ($p in $Patrones) {
        if ($p.Tipo -eq 'regex') {
            if ($p.Regex.IsMatch($Nombre)) { return $p.Texto }
        }
        elseif ($Nombre.IndexOf($p.Texto, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $p.Texto
        }
    }
    return $null
}

function Get-HwClasificacionGpu {
    <#
    .SYNOPSIS
        Clasifica el nombre de una GPU (el que devuelve Win32_VideoController) con los archivos de Config/.
    .OUTPUTS
        EsVirtual, SinDriver ("Microsoft Basic Display Adapter"), EsAntigua (nivel 1: recomienda desactivar la
        aceleración por hardware), SinSoporteFabricante (nivel 2: solo informativo) y el patrón que coincidió.
    .EXAMPLE
        Get-HwClasificacionGpu -Nombre 'Intel(R) HD Graphics 3000'
    #>
    param(
        [AllowEmptyString()][string]$Nombre
    )

    $virtual = Find-PatronCoincidente -Nombre $Nombre -Patrones (Read-PatronesConfig -Archivo 'virtual-gpu-patterns.txt')
    $sinDriver = ($Nombre -match 'Microsoft Basic Display')
    $antigua = $null
    $sinSoporte = $null
    if ((-not $virtual) -and (-not $sinDriver)) {
        $antigua = Find-PatronCoincidente -Nombre $Nombre -Patrones (Read-PatronesConfig -Archivo 'legacy-gpu-patterns.txt')
        if (-not $antigua) {
            $sinSoporte = Find-PatronCoincidente -Nombre $Nombre -Patrones (Read-PatronesConfig -Archivo 'unsupported-gpu-patterns.txt')
        }
    }
    return [pscustomobject]@{
        Nombre               = $Nombre
        EsVirtual            = [bool]$virtual
        SinDriver            = $sinDriver
        EsAntigua            = [bool]$antigua
        SinSoporteFabricante = [bool]$sinSoporte
        Patron               = $(if ($virtual) { $virtual } elseif ($antigua) { $antigua } else { $sinSoporte })
    }
}

# ---------------------------------------------------------------------------------------------
# Funciones puras (se prueban sin tocar el sistema)
# ---------------------------------------------------------------------------------------------

function Test-HwMaquinaVirtual {
    <#
    .SYNOPSIS
        Decide si los datos de SMBIOS corresponden a una máquina virtual.
    .DESCRIPTION
        No se basa solo en el fabricante: "Microsoft Corporation" también fabrica las Surface, así que Hyper-V
        exige además el modelo exacto "Virtual Machine". HypervisorPresent NO sirve (es verdadero en un host con
        Hyper-V o VBS). La BIOS solo corrobora. Son indicadores, no pruebas: el resultado dice por qué.
    .OUTPUTS
        EsVM, Hipervisor y Motivo.
    .EXAMPLE
        Test-HwMaquinaVirtual -Fabricante 'Microsoft Corporation' -Modelo 'Surface Laptop 4'   # EsVM = False
    #>
    param(
        [AllowEmptyString()][string]$Fabricante,
        [AllowEmptyString()][string]$Modelo,
        [AllowEmptyString()][string]$BiosFabricante,
        [AllowEmptyString()][string]$BiosVersion
    )

    $f = ([string]$Fabricante).Trim()
    $m = ([string]$Modelo).Trim()
    $bf = ([string]$BiosFabricante).Trim()
    $bv = ([string]$BiosVersion).Trim()

    $hipervisor = $null
    $motivo = $null
    if (($f -ceq 'Microsoft Corporation') -and ($m -ceq 'Virtual Machine')) { $hipervisor = 'Hyper-V'; $motivo = "fabricante '$f' y modelo 'Virtual Machine'" }
    elseif (($f -match '^VMware') -or ($m -match 'VMware')) { $hipervisor = 'VMware'; $motivo = "fabricante '$f', modelo '$m'" }
    elseif (($f -match '^innotek') -or ($m -match 'VirtualBox')) { $hipervisor = 'VirtualBox'; $motivo = "fabricante '$f', modelo '$m'" }
    elseif ($f -match '^QEMU') { $hipervisor = 'QEMU/KVM'; $motivo = "fabricante '$f'" }
    elseif (($f -match 'Parallels') -or ($m -match 'Parallels')) { $hipervisor = 'Parallels'; $motivo = "fabricante '$f', modelo '$m'" }
    elseif (($f -match '^Xen') -or ($m -match 'HVM domU')) { $hipervisor = 'Xen'; $motivo = "fabricante '$f', modelo '$m'" }
    elseif ($m -match 'Google Compute Engine') { $hipervisor = 'Google Cloud'; $motivo = "modelo '$m'" }
    elseif ($f -match 'Amazon EC2') { $hipervisor = 'Amazon EC2'; $motivo = "fabricante '$f'" }

    $biosIndica = ("$bf $bv" -match 'VRTUAL|VMWARE|VBOX|BOCHS|QEMU|Hyper-V|SeaBIOS')
    if ($hipervisor) {
        if ($biosIndica) { $motivo += ' (la BIOS lo corrobora)' }
        return [pscustomobject]@{ EsVM = $true; Hipervisor = $hipervisor; Motivo = $motivo }
    }
    if ($bv -match 'VRTUAL|VMWARE|VBOX|BOCHS') {
        return [pscustomobject]@{ EsVM = $true; Hipervisor = 'Desconocido'; Motivo = "solo por la versión de BIOS '$bv' (probable)" }
    }
    return [pscustomobject]@{ EsVM = $false; Hipervisor = $null; Motivo = '' }
}

function Get-HwTipoDisco {
    <#
    .SYNOPSIS
        Tipo de disco (HDD/SSD) a partir de MSFT_PhysicalDisk, con las inferencias cuando MediaType es Unspecified.
    .DESCRIPTION
        MediaType: 3 = HDD, 4 = SSD, 5 = SCM (se trata como SSD). Si es 0 (Unspecified): bus NVMe (17) -> SSD;
        SpindleSpeed entre 1 y 0xFFFFFFFE -> HDD, 0xFFFFFFFF (giro desconocido) -> HDD, 0 -> SSD (no rotacional);
        por último el modelo ("SSD", "NVMe", "Solid State").
    .OUTPUTS
        Tipo (HDD, SSD o Desconocido), Origen (cómo se decidió) y EsNVMe.
    #>
    param(
        $MediaType,
        $BusType,
        $SpindleSpeed,
        [string]$Modelo
    )

    $nvme = ($null -ne $BusType) -and ([int]$BusType -eq 17)
    $media = $null
    if ($null -ne $MediaType) { $media = [int]$MediaType }
    if ($media -eq 3) { return [pscustomobject]@{ Tipo = 'HDD'; Origen = 'MediaType = HDD'; EsNVMe = $false } }
    if ($media -eq 4) { return [pscustomobject]@{ Tipo = 'SSD'; Origen = 'MediaType = SSD'; EsNVMe = $nvme } }
    if ($media -eq 5) { return [pscustomobject]@{ Tipo = 'SSD'; Origen = 'MediaType = SCM'; EsNVMe = $nvme } }

    if ($nvme) { return [pscustomobject]@{ Tipo = 'SSD'; Origen = 'inferido: bus NVMe'; EsNVMe = $true } }
    if ($null -ne $SpindleSpeed) {
        $giro = [uint32]$SpindleSpeed
        if ($giro -eq [uint32]::MaxValue) { return [pscustomobject]@{ Tipo = 'HDD'; Origen = 'inferido: giro desconocido (disco rotacional)'; EsNVMe = $false } }
        if ($giro -gt 0) { return [pscustomobject]@{ Tipo = 'HDD'; Origen = "inferido: giro de $giro RPM"; EsNVMe = $false } }
        return [pscustomobject]@{ Tipo = 'SSD'; Origen = 'inferido: giro 0 (no rotacional)'; EsNVMe = $false }
    }
    if ($Modelo -match 'SSD|NVMe|Solid State') { return [pscustomobject]@{ Tipo = 'SSD'; Origen = 'inferido: el modelo lo indica'; EsNVMe = ($Modelo -match 'NVMe') } }
    return [pscustomobject]@{ Tipo = 'Desconocido'; Origen = 'no se pudo inferir'; EsNVMe = $false }
}

function Get-HwPerfil {
    <#
    .SYNOPSIS
        Perfil del equipo: Bajo, Medio, Alto (o Desconocido si no se sabe nada).
    .DESCRIPTION
        Bajo: RAM <= 4 GB, o <= 2 hilos, o HDD con RAM <= 8 GB (cualquiera de las tres).
        Alto: RAM >= 16 GB, >= 8 hilos y SSD (las tres, todas conocidas).
        Medio: el resto. Un dato desconocido no cuenta para Bajo y hace imposible Alto.
    #>
    param(
        $RamGB,
        $Hilos,
        [string]$TipoDisco
    )

    $razones = New-Object System.Collections.ArrayList
    if (($null -ne $RamGB) -and ($RamGB -le 4)) { [void]$razones.Add("RAM de $RamGB GB (4 GB o menos)") }
    if (($null -ne $Hilos) -and ($Hilos -le 2)) { [void]$razones.Add("$Hilos hilo(s) de CPU (2 o menos)") }
    if (($TipoDisco -eq 'HDD') -and ($null -ne $RamGB) -and ($RamGB -le 8)) { [void]$razones.Add("disco HDD con $RamGB GB de RAM (8 GB o menos)") }
    if ($razones.Count -gt 0) {
        return [pscustomobject]@{ Perfil = 'Bajo'; Motivo = ($razones -join '; ') }
    }

    if (($null -ne $RamGB) -and ($null -ne $Hilos) -and ($TipoDisco -eq 'SSD') -and ($RamGB -ge 16) -and ($Hilos -ge 8)) {
        return [pscustomobject]@{ Perfil = 'Alto'; Motivo = "RAM de $RamGB GB, $Hilos hilos y disco SSD" }
    }
    if (($null -eq $RamGB) -and ($null -eq $Hilos) -and ((-not $TipoDisco) -or ($TipoDisco -eq 'Desconocido'))) {
        return [pscustomobject]@{ Perfil = 'Desconocido'; Motivo = 'no se pudo leer RAM, CPU ni disco' }
    }
    $falta = New-Object System.Collections.ArrayList
    if (($null -eq $RamGB) -or ($RamGB -lt 16)) { [void]$falta.Add('menos de 16 GB de RAM o desconocida') }
    if (($null -eq $Hilos) -or ($Hilos -lt 8)) { [void]$falta.Add('menos de 8 hilos o desconocidos') }
    if ($TipoDisco -ne 'SSD') { [void]$falta.Add('disco no SSD o desconocido') }
    return [pscustomobject]@{ Perfil = 'Medio'; Motivo = "no es Bajo ni Alto ($($falta -join '; '))" }
}

# ---------------------------------------------------------------------------------------------
# Recolectores (cada uno aísla sus consultas)
# ---------------------------------------------------------------------------------------------

function Get-HwEquipo {
    $cs = Invoke-ConsultaHw -Nombre 'Equipo.Sistema' -Bloque { Get-CimHw -Clase 'Win32_ComputerSystem' }
    $bios = Invoke-ConsultaHw -Nombre 'Equipo.BIOS' -Bloque { Get-CimHw -Clase 'Win32_BIOS' }
    $bat = Invoke-ConsultaHw -Nombre 'Equipo.Bateria' -Bloque { Get-CimHw -Clase 'Win32_Battery' }

    $sistema = $cs.Valor | Select-Object -First 1
    $b = $bios.Valor | Select-Object -First 1
    $res = [ordered]@{
        Fabricante = $null; Modelo = $null; BiosVersion = $null; PCSystemType = $null
        TieneBateria = $null; EsPortatil = $null; EsPortatilNota = ''
        PartOfDomain = $null; Dominio = $null
        EsMaquinaVirtual = $null; Hipervisor = $null; MotivoVM = ''
        MemoriaReportadaBytes = $null; HilosReportados = $null
    }
    if ($sistema) {
        $res.Fabricante = [string]$sistema.Manufacturer
        $res.Modelo = [string]$sistema.Model
        $res.PCSystemType = $sistema.PCSystemType
        $res.PartOfDomain = $sistema.PartOfDomain
        $res.Dominio = [string]$sistema.Domain
        $res.MemoriaReportadaBytes = $sistema.TotalPhysicalMemory
        $res.HilosReportados = $sistema.NumberOfLogicalProcessors
    }
    if ($b) { $res.BiosVersion = [string]$b.SMBIOSBIOSVersion }
    if ($sistema) {
        $vm = Test-HwMaquinaVirtual -Fabricante $res.Fabricante -Modelo $res.Modelo -BiosFabricante $(if ($b) { [string]$b.Manufacturer } else { '' }) -BiosVersion $res.BiosVersion
        $res.EsMaquinaVirtual = $vm.EsVM
        $res.Hipervisor = $vm.Hipervisor
        $res.MotivoVM = $vm.Motivo
    }
    if ($bat.Estado -eq 'Ok') {
        $res.TieneBateria = ($bat.Valor.Count -gt 0)
        # Un SAI por USB puede aparecer como batería: se cruza con PCSystemType (2 = móvil, 8 = tableta)
        $movil = @(2, 8) -contains [int]$res.PCSystemType
        if ($res.TieneBateria -and $movil) { $res.EsPortatil = $true }
        elseif ((-not $res.TieneBateria) -and (-not $movil)) { $res.EsPortatil = $false }
        elseif ($res.TieneBateria) { $res.EsPortatil = $true; $res.EsPortatilNota = 'hay batería pero el tipo de equipo no es móvil (¿SAI?)' }
        else { $res.EsPortatil = $true; $res.EsPortatilNota = 'el tipo de equipo es móvil pero no se detecta batería' }
    }
    return [pscustomobject]$res
}

function Get-HwProgramasInicio {
    <#
    .SYNOPSIS
        Cuenta los programas de inicio HABILITADOS (solo lee).
    .DESCRIPTION
        Fuentes: Run de HKCU, HKLM y WOW6432Node, y las carpetas de Inicio del usuario y común. Los deshabilitados
        desde el Administrador de tareas se descuentan con StartupApproved (primer byte 03 = deshabilitado,
        02 = habilitado). La asociación Run <-> StartupApproved\Run/Run32/StartupFolder se valida en la VM
        comparando con el Administrador de tareas.
    #>
    $habilitados = 0
    $deshabilitados = 0
    $detalle = New-Object System.Collections.ArrayList

    $aprobado = {
        param($Hive, $SubClave, $Nombre)
        $v = Get-RegistroEstado -Ruta ("{0}:\{1}" -f $Hive, $SubClave) -Nombre $Nombre
        if ($v.ValorExiste -and ($v.Dato -is [byte[]]) -and ($v.Dato.Length -gt 0)) { return (($v.Dato[0] -band 1) -eq 1) }   # 03 = deshabilitado
        return $false
    }

    $fuentesRun = @(
        @{ Hive = 'HKCU'; Ruta = 'Software\Microsoft\Windows\CurrentVersion\Run'; Aprob = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Etiqueta = 'HKCU Run' },
        @{ Hive = 'HKLM'; Ruta = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Aprob = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Etiqueta = 'HKLM Run' },
        @{ Hive = 'HKLM'; Ruta = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Aprob = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Etiqueta = 'HKLM WOW6432Node Run' }
    )
    foreach ($f in $fuentesRun) {
        $base = Open-RegistroBase -Hive $(if ($f.Hive -eq 'HKCU') { [Microsoft.Win32.RegistryHive]::CurrentUser } else { [Microsoft.Win32.RegistryHive]::LocalMachine })
        try {
            $k = $base.OpenSubKey($f.Ruta, $false)
            if ($k) {
                try {
                    foreach ($n in $k.GetValueNames()) {
                        if (-not $n) { continue }
                        $off = & $aprobado $f.Hive $f.Aprob $n
                        if ($off) { $deshabilitados++ } else { $habilitados++ }
                        [void]$detalle.Add([pscustomobject]@{ Origen = $f.Etiqueta; Nombre = $n; Habilitado = (-not $off) })
                    }
                }
                finally { $k.Dispose() }
            }
        }
        finally { $base.Dispose() }
    }

    $carpetas = @(
        @{ Ruta = [Environment]::GetFolderPath('Startup'); Hive = 'HKCU'; Aprob = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Etiqueta = 'Carpeta Inicio (usuario)' },
        @{ Ruta = [Environment]::GetFolderPath('CommonStartup'); Hive = 'HKLM'; Aprob = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Etiqueta = 'Carpeta Inicio (común)' }
    )
    foreach ($c in $carpetas) {
        if ((-not $c.Ruta) -or (-not (Test-Path -LiteralPath $c.Ruta))) { continue }
        foreach ($item in (Get-ChildItem -LiteralPath $c.Ruta -File -Force -ErrorAction SilentlyContinue)) {
            if ($item.Name -ieq 'desktop.ini') { continue }
            $off = & $aprobado $c.Hive $c.Aprob $item.Name
            if ($off) { $deshabilitados++ } else { $habilitados++ }
            [void]$detalle.Add([pscustomobject]@{ Origen = $c.Etiqueta; Nombre = $item.Name; Habilitado = (-not $off) })
        }
    }
    return [pscustomobject]@{ Habilitados = $habilitados; Deshabilitados = $deshabilitados; Detalle = @($detalle) }
}

function Get-HwDsreg {
    <#
    .SYNOPSIS
        Lee 'dsregcmd /status' (con límite de tiempo) y devuelve AzureAdJoined, EnterpriseJoined, DomainJoined y
        WorkplaceJoined como $true/$false, o $null si no se pudo leer. Las claves salen en inglés y los valores
        YES/NO aunque Windows esté en otro idioma (verificado en Windows 11 en español).
    #>
    param(
        [int]$TimeoutSeg = 10
    )

    $res = [ordered]@{ AzureAdJoined = $null; EnterpriseJoined = $null; DomainJoined = $null; WorkplaceJoined = $null; Error = '' }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = [System.IO.Path]::Combine($env:windir, 'System32', 'dsregcmd.exe')
    $info.Arguments = '/status'
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.CreateNoWindow = $true
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($info)
        $tarea = $proc.StandardOutput.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeg * 1000)) {
            try { $proc.Kill() } catch { }
            $res.Error = "dsregcmd tardó más de $TimeoutSeg s"
            return [pscustomobject]$res
        }
        $texto = $tarea.Result
        foreach ($clave in 'AzureAdJoined', 'EnterpriseJoined', 'DomainJoined', 'WorkplaceJoined') {
            if ($texto -match ("(?im)^\s*{0}\s*:\s*(YES|NO)\s*$" -f $clave)) { $res[$clave] = ($Matches[1].ToUpperInvariant() -eq 'YES') }
        }
        if ($null -eq $res.AzureAdJoined) { $res.Error = 'no se encontró AzureAdJoined en la salida de dsregcmd' }
    }
    catch {
        $res.Error = $_.Exception.Message
    }
    finally {
        if ($proc) { $proc.Dispose() }
    }
    return [pscustomobject]$res
}

function Get-HwAdministracion {
    <#
    .SYNOPSIS
        ¿El equipo está administrado por una organización? Bloquean DomainJoined, AzureAdJoined, EnterpriseJoined
        y PartOfDomain. WorkplaceJoined solo genera un aviso (OptiLow corre elevado y puede ser un equipo personal
        con una cuenta del trabajo). No se mira la inscripción MDM del registro (da falsos positivos).
    #>
    param(
        $PartOfDomain
    )

    $d = Invoke-ConsultaHw -Nombre 'Administracion.dsregcmd' -Bloque { Get-HwDsreg }
    $ds = $d.Valor | Select-Object -First 1
    if ((-not $ds) -or ($d.Estado -ne 'Ok')) {
        $ds = [pscustomobject]@{ AzureAdJoined = $null; EnterpriseJoined = $null; DomainJoined = $null; WorkplaceJoined = $null; Error = $d.Error }
    }

    $bloqueantes = New-Object System.Collections.ArrayList
    if ($PartOfDomain -eq $true) { [void]$bloqueantes.Add('unido a un dominio (PartOfDomain)') }
    if ($ds.DomainJoined -eq $true) { [void]$bloqueantes.Add('unido a un dominio (DomainJoined)') }
    if ($ds.AzureAdJoined -eq $true) { [void]$bloqueantes.Add('unido a Microsoft Entra ID / Azure AD (AzureAdJoined)') }
    if ($ds.EnterpriseJoined -eq $true) { [void]$bloqueantes.Add('unido a un dominio empresarial (EnterpriseJoined)') }

    $administrado = $null
    if ($bloqueantes.Count -gt 0) { $administrado = $true }
    elseif (($PartOfDomain -eq $false) -and ($ds.AzureAdJoined -eq $false) -and ($ds.DomainJoined -eq $false) -and ($ds.EnterpriseJoined -eq $false)) { $administrado = $false }

    $aviso = ''
    if ($ds.WorkplaceJoined -eq $true) { $aviso = 'Hay una cuenta del trabajo o la escuela agregada a este equipo (WorkplaceJoined); puede que la organización administre algo.' }
    return [pscustomobject]@{
        Administrado     = $administrado
        Bloqueantes      = @($bloqueantes)
        PartOfDomain     = $PartOfDomain
        AzureAdJoined    = $ds.AzureAdJoined
        EnterpriseJoined = $ds.EnterpriseJoined
        DomainJoined     = $ds.DomainJoined
        WorkplaceJoined  = $ds.WorkplaceJoined
        AvisoWorkplace   = $aviso
        Error            = $ds.Error
    }
}

function Get-HwSistema {
    $os = Invoke-ConsultaHw -Nombre 'Sistema.SO' -Bloque { Get-CimHw -Clase 'Win32_OperatingSystem' }
    $o = $os.Valor | Select-Object -First 1
    $res = [ordered]@{ Nombre = $null; Version = $null; Compilacion = $null; Arquitectura = $null; UltimoArranque = $null; ArranqueDias = $null; InicioRapido = $null }
    if ($o) {
        $res.Nombre = [string]$o.Caption
        $res.Version = [string]$o.Version
        $res.Compilacion = [string]$o.BuildNumber
        $res.Arquitectura = [string]$o.OSArchitecture
        if ($o.LastBootUpTime) {
            $res.UltimoArranque = $o.LastBootUpTime
            $res.ArranqueDias = [math]::Round(((Get-Date) - $o.LastBootUpTime).TotalDays, 1)
        }
    }
    try {
        $h = Get-RegistroEstado -Ruta 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Nombre 'HiberbootEnabled'
        if ($h.ValorExiste) { $res.InicioRapido = ([int64]$h.Dato -eq 1) }
    }
    catch { }
    return [pscustomobject]$res
}

function Get-HwCpu {
    $q = Invoke-ConsultaHw -Nombre 'CPU' -Bloque { Get-CimHw -Clase 'Win32_Processor' }
    if (($q.Estado -ne 'Ok') -or ($q.Valor.Count -eq 0)) { return $null }
    $nucleos = 0; $hilos = 0; $mhz = 0
    foreach ($p in $q.Valor) {
        if ($p.NumberOfCores) { $nucleos += [int]$p.NumberOfCores }
        if ($p.NumberOfLogicalProcessors) { $hilos += [int]$p.NumberOfLogicalProcessors }
        if ($p.MaxClockSpeed -gt $mhz) { $mhz = [int]$p.MaxClockSpeed }
    }
    return [pscustomobject]@{
        Nombre   = ([string]($q.Valor[0].Name)).Trim()
        Nucleos  = $(if ($nucleos -gt 0) { $nucleos } else { $null })
        Hilos    = $(if ($hilos -gt 0) { $hilos } else { $null })
        MaxMHz   = $(if ($mhz -gt 0) { $mhz } else { $null })
    }
}

function Get-HwRam {
    param(
        $MemoriaReportadaBytes
    )

    $mod = Invoke-ConsultaHw -Nombre 'RAM.Modulos' -Bloque { Get-CimHw -Clase 'Win32_PhysicalMemory' }
    $arr = Invoke-ConsultaHw -Nombre 'RAM.Ranuras' -Bloque { Get-CimHw -Clase 'Win32_PhysicalMemoryArray' }

    $res = [ordered]@{ ReportadaGB = $null; InstaladaGB = $null; Fuente = $null; Modulos = $null; RanurasTotales = $null; RanurasLibres = $null; VelocidadMHz = $null }
    if ($MemoriaReportadaBytes) { $res.ReportadaGB = [math]::Round([double]$MemoriaReportadaBytes / 1GB, 2) }

    if (($mod.Estado -eq 'Ok') -and ($mod.Valor.Count -gt 0)) {
        $bytes = 0; $vel = 0
        foreach ($m in $mod.Valor) {
            $bytes += [double]$m.Capacity
            $v = 0
            if ($m.ConfiguredClockSpeed) { $v = [int]$m.ConfiguredClockSpeed } elseif ($m.Speed) { $v = [int]$m.Speed }
            if ($v -gt $vel) { $vel = $v }
        }
        $res.InstaladaGB = [math]::Round($bytes / 1GB, 1)
        $res.Fuente = 'módulos (Win32_PhysicalMemory)'
        $res.Modulos = $mod.Valor.Count
        if ($vel -gt 0) { $res.VelocidadMHz = $vel }
    }
    elseif ($MemoriaReportadaBytes) {
        # Respaldo: TotalPhysicalMemory no es exacta (la BIOS o los gráficos integrados reservan memoria): se redondea
        $res.InstaladaGB = [math]::Round(([double]$MemoriaReportadaBytes / 1GB) + 0.25)
        $res.Fuente = 'total reportado (aproximado)'
    }

    if (($arr.Estado -eq 'Ok') -and ($arr.Valor.Count -gt 0)) {
        $sistema = @($arr.Valor | Where-Object { $_.Use -eq 3 })
        if ($sistema.Count -eq 0) { $sistema = @($arr.Valor) }
        $total = 0
        foreach ($a in $sistema) { $total += [int]$a.MemoryDevices }
        if ($total -gt 0) {
            $res.RanurasTotales = $total
            if ($null -ne $res.Modulos) { $res.RanurasLibres = [math]::Max(0, $total - $res.Modulos) }
        }
    }
    return [pscustomobject]$res
}

function Get-HwGpu {
    $q = Invoke-ConsultaHw -Nombre 'GPU' -Bloque { Get-CimHw -Clase 'Win32_VideoController' }
    if ($q.Estado -ne 'Ok') { return @() }
    $lista = New-Object System.Collections.ArrayList
    foreach ($g in $q.Valor) {
        $nombre = ([string]$g.Name).Trim()
        $c = Get-HwClasificacionGpu -Nombre $nombre
        $fecha = $null
        if ($g.DriverDate) { $fecha = $g.DriverDate }
        $edad = $null
        if ($fecha) { $edad = [int]((Get-Date) - $fecha).TotalDays }
        [void]$lista.Add([pscustomobject]@{
                Nombre               = $nombre
                Fabricante           = [string]$g.AdapterCompatibility
                DriverVersion        = [string]$g.DriverVersion
                FechaDriver          = $fecha
                EdadDriverDias       = $edad
                EsVirtual            = $c.EsVirtual
                SinDriver            = $c.SinDriver
                EsAntigua            = $c.EsAntigua
                SinSoporteFabricante = $c.SinSoporteFabricante
                PatronCoincidente    = $c.Patron
                Activa               = ([int]$g.CurrentHorizontalResolution -gt 0)
                ErrorConfigManager   = $g.ConfigManagerErrorCode
            })
    }
    return @($lista)
}

function Get-HwDisco {
    param(
        $EsMaquinaVirtual
    )

    $unidad = $env:SystemDrive
    if (-not $unidad) { $unidad = 'C:' }
    $letra = $unidad.Substring(0, 1)
    $ns = 'root/Microsoft/Windows/Storage'

    $res = [ordered]@{
        Unidad = $unidad; Modelo = $null; Tipo = 'Desconocido'; TipoOrigen = $null; EsNVMe = $false; Bus = $null
        TamanoGB = $null; LibreGB = $null; LibrePct = $null; Salud = $null; EsVirtual = $false; Fiable = $false; Fuente = $null
    }

    $ld = Invoke-ConsultaHw -Nombre 'Disco.Espacio' -Bloque { Get-CimHw -Clase 'Win32_LogicalDisk' -Filtro ("DeviceID='{0}'" -f $unidad) }
    $l = $ld.Valor | Select-Object -First 1
    if ($l -and $l.Size) {
        $res.TamanoGB = [math]::Round([double]$l.Size / 1GB, 1)
        $res.LibreGB = [math]::Round([double]$l.FreeSpace / 1GB, 1)
        $res.LibrePct = [math]::Round(([double]$l.FreeSpace / [double]$l.Size) * 100, 1)
    }

    $part = Invoke-ConsultaHw -Nombre 'Disco.Particion' -Bloque { Get-CimHw -Clase 'MSFT_Partition' -Namespace $ns -Filtro ("DriveLetter='{0}'" -f $letra) }
    $p = $part.Valor | Select-Object -First 1
    $fisico = $null
    if ($p -ne $null) {
        $numero = [int]$p.DiskNumber
        $dk = Invoke-ConsultaHw -Nombre 'Disco.Disco' -Bloque { Get-CimHw -Clase 'MSFT_Disk' -Namespace $ns -Filtro ("Number={0}" -f $numero) }
        $d = $dk.Valor | Select-Object -First 1
        $pd = Invoke-ConsultaHw -Nombre 'Disco.Fisico' -Bloque { Get-CimHw -Clase 'MSFT_PhysicalDisk' -Namespace $ns }
        if ($pd.Estado -eq 'Ok') {
            if ($d -and $d.UniqueId) { $fisico = $pd.Valor | Where-Object { $_.UniqueId -eq $d.UniqueId } | Select-Object -First 1 }
            if (-not $fisico) { $fisico = $pd.Valor | Where-Object { [string]$_.DeviceId -eq [string]$numero } | Select-Object -First 1 }
        }
        if ($d -and (-not $res.Modelo)) { $res.Modelo = [string]$d.Model }
    }

    if ($fisico) {
        $t = Get-HwTipoDisco -MediaType $fisico.MediaType -BusType $fisico.BusType -SpindleSpeed $fisico.SpindleSpeed -Modelo ([string]$fisico.FriendlyName)
        $res.Modelo = ([string]$fisico.FriendlyName).Trim()
        $res.Tipo = $t.Tipo
        $res.TipoOrigen = $t.Origen
        $res.EsNVMe = $t.EsNVMe
        $res.Fuente = 'MSFT_PhysicalDisk'
        $res.Bus = switch ([int]$fisico.BusType) { 1 { 'SCSI' } 3 { 'ATA' } 7 { 'USB' } 8 { 'RAID' } 10 { 'SAS' } 11 { 'SATA' } 15 { 'Virtual (archivo)' } 16 { 'Storage Spaces' } 17 { 'NVMe' } default { "Tipo $($fisico.BusType)" } }
        $res.Salud = switch ([int]$fisico.HealthStatus) { 0 { 'Healthy' } 1 { 'Warning' } 2 { 'Unhealthy' } default { 'Unknown' } }
        if ([int]$fisico.BusType -eq 15) { $res.EsVirtual = $true }
    }
    else {
        # Respaldo: Win32_DiskDrive por la cadena letra -> partición -> disco (sin MediaType fiable)
        $dd = Invoke-ConsultaHw -Nombre 'Disco.Win32_DiskDrive' -Bloque {
            $lg = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $unidad) -OperationTimeoutSec (Get-HwTimeoutSeg) -ErrorAction Stop
            $pt = Get-CimAssociatedInstance -InputObject $lg -ResultClassName Win32_DiskPartition -OperationTimeoutSec (Get-HwTimeoutSeg) -ErrorAction Stop
            Get-CimAssociatedInstance -InputObject $pt -ResultClassName Win32_DiskDrive -OperationTimeoutSec (Get-HwTimeoutSeg) -ErrorAction Stop
        }
        $x = $dd.Valor | Select-Object -First 1
        if ($x) {
            $t = Get-HwTipoDisco -MediaType $null -BusType $null -SpindleSpeed $null -Modelo ([string]$x.Model)
            $res.Modelo = ([string]$x.Model).Trim()
            $res.Tipo = $t.Tipo
            $res.TipoOrigen = $t.Origen
            $res.EsNVMe = $t.EsNVMe
            $res.Bus = [string]$x.InterfaceType
            $res.Fuente = 'Win32_DiskDrive (sin MediaType)'
        }
    }

    # En una VM el tipo y la salud del disco virtual no son fiables
    $res.EsVirtual = ($res.EsVirtual -or ($EsMaquinaVirtual -eq $true))
    $res.Fiable = (-not $res.EsVirtual) -and ($res.Tipo -ne 'Desconocido')
    return [pscustomobject]$res
}

# ---------------------------------------------------------------------------------------------
# Diagnóstico completo
# ---------------------------------------------------------------------------------------------

function Complete-Diagnostico {
    # Auxiliar interna: calcula el perfil y las recomendaciones del objeto de hardware (también para los simulados).
    param(
        [Parameter(Mandatory)]$Hardware
    )

    $ram = $null; if ($Hardware.RAM) { $ram = $Hardware.RAM.InstaladaGB }
    $hilos = $null; if ($Hardware.CPU) { $hilos = $Hardware.CPU.Hilos }
    $tipo = 'Desconocido'; if ($Hardware.Disco) { $tipo = $Hardware.Disco.Tipo }
    $p = Get-HwPerfil -RamGB $ram -Hilos $hilos -TipoDisco $tipo
    $Hardware.Perfil = $p.Perfil
    $motivo = $p.Motivo
    if ($Hardware.EsMaquinaVirtual) { $motivo += ' (calculado con los recursos de la máquina virtual)' }
    $Hardware.PerfilMotivo = $motivo
    $Hardware.Recomendaciones = @(Get-Recomendaciones -Hardware $Hardware)
    return $Hardware
}

function Get-Diagnostico {
    <#
    .SYNOPSIS
        Diagnóstico de hardware completo (solo lectura). Devuelve UN objeto listo para la interfaz.
    .DESCRIPTION
        Propiedades: Version, FechaHora, DuracionMs, Simulado, EsMaquinaVirtual, Hipervisor, MotivoVM, Equipo,
        Windows, CPU, RAM, GPUs, GPUPrincipal, Disco, EsPortatil, ArranqueDias, InicioRapido, ProgramasInicio,
        Administracion, Perfil, PerfilMotivo, Consultas (una por consulta: Nombre, Estado, Ms, Error) y
        Recomendaciones (Nivel, Id, Titulo, Detalle). Una parte que no se pudo leer queda en $null y su consulta
        aparece como Desconocido/TiempoAgotado/Error en Consultas. El resultado se guarda en
        $global:OptiLow.Hardware; -Forzar vuelve a consultar.
    .PARAMETER TimeoutSeg
        Límite por consulta CIM (15 s por defecto).
    .EXAMPLE
        $hw = Get-Diagnostico; "$($hw.Perfil) en $($hw.DuracionMs) ms"
    #>
    param(
        [switch]$Forzar,
        [int]$TimeoutSeg = 15
    )

    $e = $global:OptiLow
    if ((-not $Forzar) -and $e.ContainsKey('Hardware') -and $e.Hardware -and (-not $e.Hardware.Simulado)) { return $e.Hardware }

    $e.HwTimeoutSeg = $TimeoutSeg
    $e.HwConsultas = New-Object System.Collections.ArrayList
    $total = [System.Diagnostics.Stopwatch]::StartNew()

    $equipo = Get-HwEquipo
    $sistema = Get-HwSistema
    $cpu = Get-HwCpu
    $ram = Get-HwRam -MemoriaReportadaBytes $equipo.MemoriaReportadaBytes
    $gpus = @(Get-HwGpu)
    $disco = Get-HwDisco -EsMaquinaVirtual $equipo.EsMaquinaVirtual
    $admin = Get-HwAdministracion -PartOfDomain $equipo.PartOfDomain

    $inicioConsulta = Invoke-ConsultaHw -Nombre 'Inicio.Programas' -Bloque { Get-HwProgramasInicio }
    $inicio = $inicioConsulta.Valor | Select-Object -First 1

    # Un dato que falta aunque la consulta "terminara bien" también queda anotado como consulta Desconocida
    Test-DatosDiagnostico -Equipo $equipo -Sistema $sistema -Cpu $cpu -Ram $ram -Gpus $gpus -Disco $disco

    $noVirtuales = @($gpus | Where-Object { -not $_.EsVirtual })
    $principal = $noVirtuales | Where-Object { $_.Activa } | Select-Object -First 1
    if (-not $principal) { $principal = $noVirtuales | Select-Object -First 1 }

    $total.Stop()
    $hw = [pscustomobject]@{
        Version          = 1
        FechaHora        = Get-Date
        DuracionMs       = [int]$total.ElapsedMilliseconds
        Simulado         = $false
        EsMaquinaVirtual = $equipo.EsMaquinaVirtual
        Hipervisor       = $equipo.Hipervisor
        MotivoVM         = $equipo.MotivoVM
        Equipo           = $equipo
        Windows          = $sistema
        CPU              = $cpu
        RAM              = $ram
        GPUs             = $gpus
        GPUPrincipal     = $principal
        Disco            = $disco
        EsPortatil       = $equipo.EsPortatil
        ArranqueDias     = $sistema.ArranqueDias
        InicioRapido     = $sistema.InicioRapido
        ProgramasInicio  = $inicio
        Administracion   = $admin
        Perfil           = 'Desconocido'
        PerfilMotivo     = ''
        Consultas        = @($e.HwConsultas)
        Recomendaciones  = @()
    }
    $hw = Complete-Diagnostico -Hardware $hw
    $e.Hardware = $hw
    Write-Log -Nivel DEBUG -Mensaje "Diagnóstico completado en $($hw.DuracionMs) ms. Perfil: $($hw.Perfil)."
    return $hw
}

function New-HardwareSimulado {
    <#
    .SYNOPSIS
        Hardware de PRUEBA (Bajo, Medio o Alto) para ver cómo cambian el perfil y las recomendaciones sin depender
        del equipo real. Pasa por el mismo cálculo que el diagnóstico real. Marca Simulado = $true.
    .EXAMPLE
        New-HardwareSimulado -Perfil Bajo
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Bajo', 'Medio', 'Alto')][string]$Perfil
    )

    $gpuNombre = 'Intel(R) HD Graphics 3000'
    $edad = 4200
    switch ($Perfil) {
        'Bajo' {
            $cpu = @{ Nombre = 'Intel(R) Core(TM)2 Duo CPU E7500 @ 2.93GHz'; Nucleos = 2; Hilos = 2; MaxMHz = 2933 }
            $ram = @{ ReportadaGB = 3.87; InstaladaGB = 4; Fuente = 'simulado'; Modulos = 1; RanurasTotales = 2; RanurasLibres = 1; VelocidadMHz = 800 }
            $disco = @{ Unidad = 'C:'; Modelo = 'Simulado HDD 500 GB'; Tipo = 'HDD'; TipoOrigen = 'MediaType = HDD'; EsNVMe = $false; Bus = 'SATA'; TamanoGB = 465.7; LibreGB = 55.0; LibrePct = 11.8; Salud = 'Healthy'; EsVirtual = $false; Fiable = $true; Fuente = 'simulado' }
            $portatil = $false; $dias = 21.0; $inicioN = 18
        }
        'Medio' {
            $gpuNombre = 'Intel(R) UHD Graphics 620'; $edad = 400
            $cpu = @{ Nombre = 'Intel(R) Core(TM) i5-8250U CPU @ 1.60GHz'; Nucleos = 4; Hilos = 8; MaxMHz = 1800 }
            $ram = @{ ReportadaGB = 7.88; InstaladaGB = 8; Fuente = 'simulado'; Modulos = 1; RanurasTotales = 2; RanurasLibres = 1; VelocidadMHz = 2400 }
            $disco = @{ Unidad = 'C:'; Modelo = 'Simulado SSD 256 GB'; Tipo = 'SSD'; TipoOrigen = 'MediaType = SSD'; EsNVMe = $false; Bus = 'SATA'; TamanoGB = 238.0; LibreGB = 95.0; LibrePct = 39.9; Salud = 'Healthy'; EsVirtual = $false; Fiable = $true; Fuente = 'simulado' }
            $portatil = $true; $dias = 3.0; $inicioN = 7
        }
        'Alto' {
            $gpuNombre = 'NVIDIA GeForce RTX 3060'; $edad = 200
            $cpu = @{ Nombre = 'AMD Ryzen 7 5800X 8-Core Processor'; Nucleos = 8; Hilos = 16; MaxMHz = 3800 }
            $ram = @{ ReportadaGB = 31.9; InstaladaGB = 32; Fuente = 'simulado'; Modulos = 2; RanurasTotales = 4; RanurasLibres = 2; VelocidadMHz = 3200 }
            $disco = @{ Unidad = 'C:'; Modelo = 'Simulado NVMe 1 TB'; Tipo = 'SSD'; TipoOrigen = 'MediaType = SSD'; EsNVMe = $true; Bus = 'NVMe'; TamanoGB = 931.5; LibreGB = 600.0; LibrePct = 64.4; Salud = 'Healthy'; EsVirtual = $false; Fiable = $true; Fuente = 'simulado' }
            $portatil = $false; $dias = 1.0; $inicioN = 4
        }
    }
    $c = Get-HwClasificacionGpu -Nombre $gpuNombre
    $gpu = [pscustomobject]@{
        Nombre = $gpuNombre; Fabricante = 'Simulado'; DriverVersion = '1.0.0.0'; FechaDriver = (Get-Date).AddDays(-$edad); EdadDriverDias = $edad
        EsVirtual = $c.EsVirtual; SinDriver = $c.SinDriver; EsAntigua = $c.EsAntigua; SinSoporteFabricante = $c.SinSoporteFabricante
        PatronCoincidente = $c.Patron; Activa = $true; ErrorConfigManager = 0
    }
    $admin = [pscustomobject]@{
        Administrado = $false; Bloqueantes = @(); PartOfDomain = $false; AzureAdJoined = $false; EnterpriseJoined = $false
        DomainJoined = $false; WorkplaceJoined = $false; AvisoWorkplace = ''; Error = ''
    }
    $hw = [pscustomobject]@{
        Version = 1; FechaHora = (Get-Date); DuracionMs = 0; Simulado = $true
        EsMaquinaVirtual = $false; Hipervisor = $null; MotivoVM = ''
        Equipo = [pscustomobject]@{ Fabricante = 'Simulado'; Modelo = "Perfil $Perfil (simulado)" }
        Windows = [pscustomobject]@{ Nombre = 'Windows (simulado)'; Version = ''; Compilacion = ''; Arquitectura = ''; UltimoArranque = $null; ArranqueDias = $dias; InicioRapido = $true }
        CPU = [pscustomobject]$cpu; RAM = [pscustomobject]$ram; GPUs = @($gpu); GPUPrincipal = $gpu; Disco = [pscustomobject]$disco
        EsPortatil = $portatil; ArranqueDias = $dias; InicioRapido = $true
        ProgramasInicio = [pscustomobject]@{ Habilitados = $inicioN; Deshabilitados = 0; Detalle = @() }
        Administracion = $admin; Perfil = 'Desconocido'; PerfilMotivo = ''
        Consultas = @(); Recomendaciones = @()
    }
    return (Complete-Diagnostico -Hardware $hw)
}
