# Tweaks/EfectosVisuales.ps1
# Categoría: Efectos visuales.

[void](Register-Tweak `
    -Id 'efectos-transparencia-off' `
    -Nombre 'Desactivar transparencias de Windows' `
    -Categoria 'Efectos visuales' `
    -Descripcion 'Desactiva el efecto de transparencia (acrílico/vidrio) de la barra de tareas, el menú Inicio y las ventanas de Windows (EnableTransparency = 0 en HKCU). Ayuda en equipos con gráficos integrados antiguos porque la GPU deja de mezclar capas translúcidas. Efecto secundario: esas superficies se ven opacas, con un aspecto más plano.' `
    -Riesgo Bajo `
    -Requiere Nada `
    -Aplicar {
        Set-RegistroValor -Ruta 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Nombre 'EnableTransparency' -Valor 0 -Tipo DWord
    } `
    -Comprobar {
        $v = Get-RegistroEstado -Ruta 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Nombre 'EnableTransparency'
        # Si el valor no existe, Windows usa su valor por defecto (transparencias activadas): pendiente
        ($v.ValorExiste -and ($v.Tipo -eq 'DWord') -and ([int64]$v.Dato -eq 0))
    } `
    -Recomendar {
        param($Hardware)
        # Propuesta de la fase 3 (a revisar en la fase 4): se preselecciona en equipos de perfil Bajo
        $Hardware.Perfil -eq 'Bajo'
    })
