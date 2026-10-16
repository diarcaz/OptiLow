# Core/Tweaks.ps1
# Motor de optimizaciones (tweaks). Sin interfaz: lo usan la consola y, más adelante, la interfaz.
#
# Un tweak se registra con Register-Tweak (ver Tweaks/_Plantilla.ps1). Los bloques Aplicar, Comprobar y
# Recomendar se guardan como TEXTO y se recrean al ejecutarlos, de modo que no dependen de variables
# del archivo donde se definieron (y la interfaz puede ejecutarlos en un runspace aparte por Id).
#
# Contrato de los bloques:
#   Aplicar    : solo llama a funciones de Core/ (Set-RegistroValor, Set-ServicioInicio, ...) y deja salir
#                lo que ellas devuelven (Cambiado, SinCambios, NoAplica, Fallido). Nada más.
#   Comprobar  : solo LEE la configuración (no el estado en ejecución). Devuelve $true (aplicado),
#                $false (pendiente) o $null (no aplica). Si comprueba varios elementos, usa
#                Join-EstadosTweak: $null solo si no existe ninguno; $true si todos los que existen
#                están como se desea; $false en otro caso.
#   Recomendar : recibe el objeto de hardware (param($Hardware)) y devuelve $true/$false.
#   Ninguno usa Write-Host; para mensajes, Write-Log. Ninguno escribe directo al sistema.

$global:OptiLowTweakRequiere = @('Nada', 'Cerrar sesión', 'Reiniciar')

# Cmdlets/programas que un bloque NO puede usar: toda escritura al sistema pasa por Core/ (journal).
$global:OptiLowComandosProhibidos = @(
    'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Rename-ItemProperty', 'Clear-ItemProperty',
    'Set-Item', 'New-Item', 'Remove-Item', 'Move-Item', 'Copy-Item', 'Rename-Item',
    'Set-Content', 'Add-Content', 'Clear-Content', 'Out-File',
    'Set-Service', 'Stop-Service', 'Start-Service', 'Restart-Service', 'New-Service',
    'Disable-ScheduledTask', 'Enable-ScheduledTask', 'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Set-ScheduledTask',
    'Stop-Process', 'Start-Process', 'Invoke-Expression',
    'sc', 'sc.exe', 'reg', 'reg.exe', 'powercfg', 'powercfg.exe', 'schtasks', 'schtasks.exe', 'netsh', 'netsh.exe',
    'Write-Host'
)

function Get-ComandosProhibidosEnBloque {
    # Auxiliar interna: nombres de comandos prohibidos que aparecen en el texto de un bloque (análisis sintáctico).
    param(
        [Parameter(Mandatory)][string]$Texto
    )

    $tokens = $null
    $errores = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Texto, [ref]$tokens, [ref]$errores)
    if ($errores -and $errores.Count -gt 0) {
        return @("(error de sintaxis: $($errores[0].Message))")
    }
    $encontrados = New-Object System.Collections.ArrayList
    $comandos = $ast.FindAll({ param($nodo) $nodo -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $comandos) {
        $nombre = $c.GetCommandName()
        if ($nombre -and ($global:OptiLowComandosProhibidos -contains $nombre)) {
            [void]$encontrados.Add($nombre)
        }
    }
    return @($encontrados | Select-Object -Unique)
}

function Register-Tweak {
    <#
    .SYNOPSIS
        Registra una optimización en el motor. Devuelve $true si quedó registrada.
    .DESCRIPTION
        Valida el contrato: Id en minúsculas, números y guiones y único; campos obligatorios; riesgo
        Bajo/Medio/Alto; bloques sin comandos prohibidos. Si algo no cumple, registra un ERROR en el
        log, NO registra el tweak y devuelve $false (el resto del archivo sigue cargándose).
    .EXAMPLE
        Register-Tweak -Id 'ejemplo-clave' -Nombre 'Ejemplo' -Categoria 'Pruebas' `
            -Descripcion 'Escribe un valor de prueba. Efecto secundario: ninguno.' -Riesgo Bajo `
            -Aplicar { Set-RegistroValor -Ruta 'HKCU:\Software\Ejemplo' -Nombre 'v' -Valor 1 -Tipo DWord } `
            -Comprobar { (Get-RegistroEstado -Ruta 'HKCU:\Software\Ejemplo' -Nombre 'v').Dato -eq 1 }
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)][string]$Categoria,
        [Parameter(Mandatory)][string]$Descripcion,
        [Parameter(Mandatory)][ValidateSet('Bajo', 'Medio', 'Alto')][string]$Riesgo,
        [ValidateSet('Nada', 'Cerrar sesión', 'Reiniciar')][string]$Requiere = 'Nada',
        [bool]$Reversible = $true,
        [Parameter(Mandatory)][scriptblock]$Aplicar,
        [scriptblock]$Comprobar,
        [scriptblock]$Recomendar
    )

    $e = $global:OptiLow
    if (-not $e.ContainsKey('Tweaks')) { $e.Tweaks = [ordered]@{} }

    $archivo = ''
    $pila = @(Get-PSCallStack)
    if ($pila.Count -gt 1) { $archivo = [string]$pila[1].ScriptName }

    $fallos = New-Object System.Collections.ArrayList
    if ($Id -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { [void]$fallos.Add("El Id debe tener solo minúsculas, números y guiones (sin guiones al inicio/fin ni dobles).") }
    if ($Descripcion.Trim().Length -lt 20) { [void]$fallos.Add('La descripción es demasiado corta: debe explicar qué hace, por qué ayuda y qué efecto secundario tiene.') }
    if ($e.Tweaks.Contains($Id) -and ($e.Tweaks[$Id].Archivo -ne $archivo)) {
        [void]$fallos.Add("Ya existe un tweak con ese Id (definido en '$($e.Tweaks[$Id].Archivo)').")
    }

    $textoAplicar = $Aplicar.ToString()
    $textoComprobar = $null
    $textoRecomendar = $null
    $prohibidosAplicar = @(Get-ComandosProhibidosEnBloque -Texto $textoAplicar)
    if ($prohibidosAplicar.Count -gt 0) {
        [void]$fallos.Add("El bloque Aplicar usa comandos prohibidos ($($prohibidosAplicar -join ', ')): toda escritura debe pasar por las funciones de Core/ y no se usa Write-Host.")
    }
    if ($Comprobar) {
        $textoComprobar = $Comprobar.ToString()
        $p = @(Get-ComandosProhibidosEnBloque -Texto $textoComprobar)
        if ($p.Count -gt 0) { [void]$fallos.Add("El bloque Comprobar usa comandos prohibidos ($($p -join ', ')): solo debe leer.") }
    }
    if ($Recomendar) {
        $textoRecomendar = $Recomendar.ToString()
        $p = @(Get-ComandosProhibidosEnBloque -Texto $textoRecomendar)
        if ($p.Count -gt 0) { [void]$fallos.Add("El bloque Recomendar usa comandos prohibidos ($($p -join ', ')).") }
    }

    if ($fallos.Count -gt 0) {
        Write-Log -Nivel ERROR -Mensaje "Tweak '$Id' NO registrado: $($fallos -join ' ')"
        return $false
    }

    if ($e.Tweaks.Contains($Id)) { Write-Log -Nivel DEBUG -Mensaje "Tweak '$Id' registrado de nuevo (recarga del mismo archivo)." }
    $e.Tweaks[$Id] = [pscustomobject]@{
        Id          = $Id
        Nombre      = $Nombre
        Categoria   = $Categoria
        Descripcion = $Descripcion
        Riesgo      = $Riesgo
        Requiere    = $Requiere
        Reversible  = $Reversible
        Aplicar     = $textoAplicar
        Comprobar   = $textoComprobar
        Recomendar  = $textoRecomendar
        Archivo     = $archivo
    }
    Write-Log -Nivel DEBUG -Mensaje "Tweak registrado: $Id"
    return $true
}

function Unregister-Tweak {
    # Quita un tweak del registro (se usa en las pruebas).
    param(
        [Parameter(Mandatory)][string]$Id
    )
    $e = $global:OptiLow
    if ($e.ContainsKey('Tweaks') -and $e.Tweaks.Contains($Id)) { $e.Tweaks.Remove($Id) }
}

function Get-Tweak {
    <#
    .SYNOPSIS
        Devuelve las definiciones de tweaks registrados (todas, o una por Id, o las de una categoría).
    .EXAMPLE
        Get-Tweak | Format-Table Id, Categoria, Riesgo, Requiere
    #>
    param(
        [string]$Id,
        [string]$Categoria
    )

    $e = $global:OptiLow
    if (-not $e.ContainsKey('Tweaks')) { return @() }
    $todos = @($e.Tweaks.Values)
    if ($Id) { $todos = @($todos | Where-Object { $_.Id -ceq $Id }) }
    if ($Categoria) { $todos = @($todos | Where-Object { $_.Categoria -eq $Categoria }) }
    return $todos
}

function Join-EstadosTweak {
    <#
    .SYNOPSIS
        Combina los estados de varios elementos para el bloque Comprobar de un tweak con varios elementos.
    .OUTPUTS
        $null si ningún elemento existe (no aplica); $true si todos los que existen están en el estado
        deseado; $false en otro caso.
    .EXAMPLE
        Join-EstadosTweak -Estados @($true, $null, $false)   # -> $false
    #>
    param(
        [AllowNull()][object[]]$Estados
    )

    $existentes = @($Estados | Where-Object { $null -ne $_ })
    if ($existentes.Count -eq 0) { return $null }
    foreach ($estado in $existentes) {
        if (-not $estado) { return $false }
    }
    return $true
}

function Invoke-BloqueTweak {
    # Auxiliar interna: ejecuta el texto de un bloque en un ámbito propio. Devuelve todo lo que emita.
    param(
        [Parameter(Mandatory)][string]$Texto,
        [object[]]$Argumentos = @()
    )
    $bloque = [scriptblock]::Create($Texto)
    return @(& $bloque @Argumentos)
}

function Get-TweakEstado {
    <#
    .SYNOPSIS
        Comprueba la configuración actual de un tweak (no el estado en ejecución).
    .OUTPUTS
        Objeto con Estado: Aplicado, Pendiente, NoAplica, Desconocido (sin bloque Comprobar) o Error (con Detalle).
    .EXAMPLE
        Get-TweakEstado -Id 'efectos-transparencia-off'
    #>
    param(
        [Parameter(Mandatory)][string]$Id
    )

    $def = Get-Tweak -Id $Id | Select-Object -First 1
    if (-not $def) { throw "No existe el tweak '$Id'." }
    if (-not $def.Comprobar) {
        return [pscustomobject]@{ Id = $Id; Estado = 'Desconocido'; Detalle = 'El tweak no tiene bloque Comprobar.' }
    }
    try {
        $salida = @(Invoke-BloqueTweak -Texto $def.Comprobar)
    }
    catch {
        Write-Log -Nivel ERROR -Mensaje "Tweak '$Id': error al comprobar el estado: $($_.Exception.Message)"
        return [pscustomobject]@{ Id = $Id; Estado = 'Error'; Detalle = $_.Exception.Message }
    }
    if ($salida.Count -gt 1) {
        $detalle = "El bloque Comprobar devolvió $($salida.Count) valores y debe devolver uno (`$true, `$false o `$null)."
        Write-Log -Nivel ERROR -Mensaje "Tweak '$Id': $detalle"
        return [pscustomobject]@{ Id = $Id; Estado = 'Error'; Detalle = $detalle }
    }
    if (($salida.Count -eq 0) -or ($null -eq $salida[0])) {
        return [pscustomobject]@{ Id = $Id; Estado = 'NoAplica'; Detalle = '' }
    }
    if ($salida[0] -isnot [bool]) {
        $detalle = "El bloque Comprobar devolvió '$($salida[0])' y debe devolver `$true, `$false o `$null."
        Write-Log -Nivel ERROR -Mensaje "Tweak '$Id': $detalle"
        return [pscustomobject]@{ Id = $Id; Estado = 'Error'; Detalle = $detalle }
    }
    $estado = 'Pendiente'
    if ($salida[0]) { $estado = 'Aplicado' }
    return [pscustomobject]@{ Id = $Id; Estado = $estado; Detalle = '' }
}

function New-Recomendacion {
    <#
    .SYNOPSIS
        Auxiliar para los bloques Recomendar: devuelve la decisión junto con el MOTIVO (se muestra al usuario).
    .EXAMPLE
        New-Recomendacion -Si $true -Motivo 'GPU antigua detectada'
    #>
    param(
        [Parameter(Mandatory)][bool]$Si,
        [string]$Motivo = ''
    )
    return [pscustomobject]@{ Recomendar = $Si; Motivo = $Motivo }
}

function Get-TweakRecomendacion {
    <#
    .SYNOPSIS
        Ejecuta el bloque Recomendar de un tweak con el objeto de hardware y devuelve la decisión y su motivo.
    .DESCRIPTION
        El bloque puede devolver $true/$false o un objeto con Recomendar y Motivo (ver New-Recomendacion).
        Sin bloque Recomendar el tweak nunca se recomienda.
    .OUTPUTS
        Id, Recomendado, Motivo, TieneBloque y Error.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Hardware
    )

    $def = Get-Tweak -Id $Id | Select-Object -First 1
    if (-not $def) { throw "No existe el tweak '$Id'." }
    if (-not $def.Recomendar) {
        return [pscustomobject]@{ Id = $Id; Recomendado = $false; Motivo = 'No tiene criterio de recomendación.'; TieneBloque = $false; Error = '' }
    }
    try {
        $salida = @(Invoke-BloqueTweak -Texto $def.Recomendar -Argumentos @($Hardware))
        if ($salida.Count -ne 1) { throw "El bloque Recomendar devolvió $($salida.Count) valores y debe devolver uno." }
        $v = $salida[0]
        if ($v -is [bool]) {
            return [pscustomobject]@{ Id = $Id; Recomendado = $v; Motivo = ''; TieneBloque = $true; Error = '' }
        }
        if ($v -and ($v.PSObject.Properties['Recomendar'])) {
            return [pscustomobject]@{ Id = $Id; Recomendado = [bool]$v.Recomendar; Motivo = [string]$v.Motivo; TieneBloque = $true; Error = '' }
        }
        throw "El bloque Recomendar devolvió '$v' y debe devolver `$true, `$false o New-Recomendacion."
    }
    catch {
        Write-Log -Nivel ERROR -Mensaje "Tweak '$Id': error en el bloque Recomendar: $($_.Exception.Message)"
        return [pscustomobject]@{ Id = $Id; Recomendado = $false; Motivo = 'Error al evaluar la recomendación.'; TieneBloque = $true; Error = $_.Exception.Message }
    }
}

function Test-TweakRecomendado {
    <#
    .SYNOPSIS
        Indica si un tweak se preselecciona para el hardware dado (bloque Recomendar). Sin bloque: $false.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Hardware
    )
    return [bool](Get-TweakRecomendacion -Id $Id -Hardware $Hardware).Recomendado
}

function Get-TweaksRecomendados {
    <#
    .SYNOPSIS
        Para cada tweak registrado: ¿se recomienda para este hardware?, por qué, y su estado actual.
    .DESCRIPTION
        Seleccionable = recomendado y todavía pendiente (omite los ya aplicados y los que no aplican). Es lo que usa
        "-Aplicar recomendados" y lo que usará el botón "Seleccionar recomendadas" de la interfaz. Solo lee.
    .EXAMPLE
        Get-TweaksRecomendados -Hardware (Get-Diagnostico) | Format-Table Id, Recomendado, Estado, Motivo
    #>
    param(
        [Parameter(Mandatory)]$Hardware
    )

    $lista = New-Object System.Collections.ArrayList
    foreach ($def in (Get-Tweak)) {
        $rec = Get-TweakRecomendacion -Id $def.Id -Hardware $Hardware
        $estado = Get-TweakEstado -Id $def.Id
        $pendiente = @('Pendiente', 'Desconocido', 'Error') -contains $estado.Estado
        [void]$lista.Add([pscustomobject]@{
                Id           = $def.Id
                Nombre       = $def.Nombre
                Recomendado  = $rec.Recomendado
                Motivo       = $rec.Motivo
                Estado       = $estado.Estado
                Seleccionable = ($rec.Recomendado -and $pendiente)
            })
    }
    return @($lista)
}
function Invoke-Tweak {
    <#
    .SYNOPSIS
        Aplica un tweak y devuelve su resultado. No pregunta nada ni crea el punto de restauración.
    .DESCRIPTION
        - Si Comprobar dice que ya está aplicado (o que no aplica), no ejecuta Aplicar.
        - Todo lo que Aplicar cambie queda en el journal con el Id del tweak (TweakId).
        - Estado del resultado: Aplicado (hubo cambios), SinCambios (ya estaba como se desea),
          NoAplica (no existe ningún elemento), Parcial (alguno falló y otros no) o Fallido.
          Con varios elementos: Aplicado/SinCambios si todos los que existen quedaron bien; NoAplica
          solo si no existe ninguno; Parcial si alguno falló (p. ej. acceso denegado).
        - Una excepción en el bloque se registra y se devuelve como Fallido (el resto de tweaks sigue).
        Lanza una excepción si no se puede garantizar el journal.
    .EXAMPLE
        Invoke-Tweak -Id 'efectos-transparencia-off'
    #>
    param(
        [Parameter(Mandatory)][string]$Id
    )

    $def = Get-Tweak -Id $Id | Select-Object -First 1
    if (-not $def) { throw "No existe el tweak '$Id'." }

    Assert-JournalListo
    $e = $global:OptiLow

    function Nuevo-Resultado($estado, $detalle, $cambiados) {
        return [pscustomobject]@{
            Id = $def.Id; Nombre = $def.Nombre; Estado = $estado; Detalle = $detalle; Cambiados = $cambiados
            Requiere = $def.Requiere; Reversible = $def.Reversible; Riesgo = $def.Riesgo
        }
    }

    $previo = Get-TweakEstado -Id $Id
    if ($previo.Estado -eq 'Aplicado') {
        Write-Log -Mensaje "Tweak '$Id': ya estaba aplicado."
        return Nuevo-Resultado 'SinCambios' 'Ya estaba aplicado.' 0
    }
    if ($previo.Estado -eq 'NoAplica') {
        Write-Log -Mensaje "Tweak '$Id': no aplica en este equipo."
        return Nuevo-Resultado 'NoAplica' 'No aplica en este equipo.' 0
    }

    Write-Log -Mensaje "Aplicando: $($def.Nombre) [$Id]..."
    $e.TweakActual = $Id
    try {
        $salida = @(Invoke-BloqueTweak -Texto $def.Aplicar)
    }
    catch {
        Write-Log -Nivel ERROR -Mensaje "Tweak '$Id': error al aplicar: $($_.Exception.Message)"
        return Nuevo-Resultado 'Fallido' $_.Exception.Message 0
    }
    finally {
        $e.TweakActual = $null
    }

    $cuenta = @{ Cambiado = 0; SinCambios = 0; NoAplica = 0; Fallido = 0 }
    foreach ($item in $salida) {
        if (($item -is [string]) -and $cuenta.ContainsKey($item)) { $cuenta[$item]++ }
        else { Write-Log -Nivel WARN -Mensaje "Tweak '$Id': el bloque Aplicar devolvió '$item', que no es un estado de Core/ (se ignora)." }
    }
    $total = $cuenta.Cambiado + $cuenta.SinCambios + $cuenta.NoAplica + $cuenta.Fallido
    if ($total -eq 0) {
        Write-Log -Nivel WARN -Mensaje "Tweak '$Id': el bloque Aplicar no devolvió ningún estado; no se puede saber si cambió algo."
        return Nuevo-Resultado 'SinCambios' 'El bloque Aplicar no devolvió ningún estado.' 0
    }

    if ($cuenta.Fallido -gt 0) {
        if (($cuenta.Cambiado + $cuenta.SinCambios) -gt 0) { $estado = 'Parcial' } else { $estado = 'Fallido' }
        $detalle = "$($cuenta.Fallido) elemento(s) fallaron, $($cuenta.Cambiado) cambiaron, $($cuenta.SinCambios) ya estaban bien."
        Write-Log -Nivel WARN -Mensaje "Tweak '$Id': $estado. $detalle"
        return Nuevo-Resultado $estado $detalle $cuenta.Cambiado
    }
    if ($cuenta.Cambiado -gt 0) {
        $estado = 'Aplicado'
        $detalle = "$($cuenta.Cambiado) elemento(s) cambiados."
    }
    elseif ($cuenta.SinCambios -gt 0) {
        $estado = 'SinCambios'
        $detalle = 'Ya estaba como se desea.'
    }
    else {
        $estado = 'NoAplica'
        $detalle = 'No existe ningún elemento en este equipo.'
    }

    # Verificar que la configuración quedó como se desea
    if (($estado -eq 'Aplicado') -and $def.Comprobar) {
        $despues = Get-TweakEstado -Id $Id
        if ($despues.Estado -ne 'Aplicado') {
            $detalle = "Se hicieron cambios pero la comprobación dice '$($despues.Estado)'. $($despues.Detalle)"
            Write-Log -Nivel ERROR -Mensaje "Tweak '$Id': $detalle"
            return Nuevo-Resultado 'Fallido' $detalle $cuenta.Cambiado
        }
    }

    if ($estado -eq 'Aplicado') { Write-Log -Nivel OK -Mensaje "Tweak '$Id' aplicado." }
    elseif ($estado -eq 'NoAplica') { Write-Log -Mensaje "Tweak '$Id': no aplica en este equipo." }
    return Nuevo-Resultado $estado $detalle $cuenta.Cambiado
}

function Invoke-TweaksLote {
    <#
    .SYNOPSIS
        Aplica varios tweaks seguidos en la sesión de journal ya iniciada (una ejecución = una sesión).
    .OUTPUTS
        Objeto con Resultados (uno por tweak), Requiere (el mayor: Nada, Cerrar sesión o Reiniciar) y
        TweaksQueRequieren (los que, habiendo cambiado algo, piden Cerrar sesión o Reiniciar).
    .EXAMPLE
        [void](Start-JournalSesion -Nueva); Invoke-TweaksLote -Ids 'efectos-transparencia-off'
    #>
    param(
        [Parameter(Mandatory)][string[]]$Ids
    )

    Assert-JournalListo -Completo
    [void](Start-JournalSesion)

    $resultados = New-Object System.Collections.ArrayList
    foreach ($id in $Ids) {
        try {
            [void]$resultados.Add((Invoke-Tweak -Id $id))
        }
        catch {
            # Solo llegan aquí los fallos que impiden todo (journal) o Ids inexistentes: se detiene el lote
            if ($_.Exception.Message -like 'No existe el tweak*') {
                Write-Log -Nivel ERROR -Mensaje $_.Exception.Message
                [void]$resultados.Add([pscustomobject]@{ Id = $id; Nombre = $id; Estado = 'Fallido'; Detalle = $_.Exception.Message; Cambiados = 0; Requiere = 'Nada'; Reversible = $true; Riesgo = 'Bajo' })
            }
            else { throw }
        }
    }

    $nivel = 'Nada'
    $quienes = New-Object System.Collections.ArrayList
    foreach ($r in $resultados) {
        if ((@('Aplicado', 'Parcial') -contains $r.Estado) -and ($r.Requiere -ne 'Nada')) {
            [void]$quienes.Add($r)
            if ($r.Requiere -eq 'Reiniciar') { $nivel = 'Reiniciar' }
            elseif ($nivel -eq 'Nada') { $nivel = 'Cerrar sesión' }
        }
    }
    return [pscustomobject]@{ Resultados = @($resultados); Requiere = $nivel; TweaksQueRequieren = @($quienes) }
}
