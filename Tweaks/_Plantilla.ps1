# Tweaks/_Plantilla.ps1
# PLANTILLA para crear una optimización nueva. El cargador NO carga los archivos que empiezan con "_".
# Para usarla: copia este archivo, quítale el "_" al nombre (un archivo por categoría) y rellena los campos.
# Un archivo puede registrar varios tweaks de la misma categoría; si uno tiene un error, solo ese se
# rechaza (se registra en el log) y el resto del programa sigue funcionando.
#
# REGLAS (el motor las comprueba al registrar y rechaza el tweak si no se cumplen):
#   - Id: minúsculas, números y guiones; único. Ej.: 'discord-hwaccel-off'.
#   - Descripcion: qué hace, por qué ayuda y QUÉ EFECTO SECUNDARIO tiene (mínimo 20 caracteres).
#   - Riesgo: Bajo, Medio o Alto.   Requiere: Nada, 'Cerrar sesión' o Reiniciar.
#   - Reversible: $true por defecto. Ponlo en $false solo si el journal NO puede deshacerlo.
#   - Aplicar: SOLO llama a funciones de Core/ (Set-RegistroValor, Remove-RegistroValor, Set-ServicioInicio,
#     Disable-TareaProgramada, Write-ArchivoTexto, Set-JsonValor, Set-PlanEnergia) y deja salir lo que
#     devuelven (Cambiado, SinCambios, NoAplica, Fallido). Nunca Set-ItemProperty, Set-Service, sc.exe,
#     powercfg, Remove-Item, etc. ni Write-Host (usa Write-Log). Si el valor ya es el deseado, esas
#     funciones no escriben nada ni lo anotan en el journal.
#   - Los bloques NO dependen de variables externas (se guardan como texto y se recrean al ejecutarlos).
#     Si necesitan datos compartidos, usa una función auxiliar de Core/.
#   - Comprobar (opcional): solo LEE la configuración (no el estado en ejecución). Devuelve $true
#     (aplicado), $false (pendiente) o $null (no aplica; p. ej. el programa no está instalado).
#     Con varios elementos usa Join-EstadosTweak: $null solo si no existe ninguno; $true si todos los que
#     existen están bien; $false en otro caso.
#   - Recomendar (opcional): recibe el objeto de hardware y devuelve $true/$false (preselección).
#     Hardware.Perfil es 'Bajo', 'Medio' o 'Alto'. Sin este bloque, el tweak nunca se preselecciona.
#
# Resultado de aplicar un tweak con varios elementos: Aplicado si todos los que existen quedaron bien,
# NoAplica solo si no existe ninguno, Parcial si alguno falló (p. ej. acceso denegado).

[void](Register-Tweak `
    -Id 'ejemplo-id-del-tweak' `
    -Nombre 'Texto corto para la interfaz' `
    -Categoria 'Nombre de la categoría' `
    -Descripcion 'Qué hace, por qué ayuda y qué efecto secundario tiene.' `
    -Riesgo Bajo `
    -Requiere Nada `
    -Aplicar {
        Set-RegistroValor -Ruta 'HKCU:\Software\Ejemplo' -Nombre 'Valor' -Valor 1 -Tipo DWord
    } `
    -Comprobar {
        $v = Get-RegistroEstado -Ruta 'HKCU:\Software\Ejemplo' -Nombre 'Valor'
        ($v.ValorExiste -and ([int64]$v.Dato -eq 1))
    } `
    -Recomendar {
        param($Hardware)
        $Hardware.Perfil -eq 'Bajo'
    })
