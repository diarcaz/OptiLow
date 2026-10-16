# Plan de la fase 5: interfaz WPF/XAML

**Estado: plan APROBADO por el usuario y fase 5 ESCRITA (probada con `Pruebas/Probar-Fase5.ps1`; falta la VM).** Cambios respecto al plan original, decididos al implementar:
- **Pantalla de "Cargando…":** se aprobó la de Windows Forms en otro hilo con dos condiciones (no impedir el arranque, cerrarse siempre) y con la instrucción de medir y quedarse con lo simple si la diferencia era insignificante. Medido (mismo equipo, disco en caché, ms desde el inicio del proceso, dos pasadas): script en marcha ~230; WPF cargado ~245; formulario WinForms en otro hilo visible ~320-345 (en el mismo hilo ~300-475). O sea, no gana nada (cargar WPF cuesta ~15-90 ms) y además saldría borroso con escala del 125-150 % porque `powershell.exe` no declara DPI hasta la primera ventana WPF. **Se quedó la opción simple:** la propia ventana principal con un panel "Cargando…" y carga por pasos. Sección 4 y 16 abajo.
- Datos (V) verificados: ver la sección 16.
- Todo lo demás se implementó como está descrito (el selector de `-Demo` usa radios, no un ComboBox).
Reglas generales en `CLAUDE.md` (sección Interfaz); este documento manda sobre ellas en lo que detalla.
Antes de escribir código: confirmar con el usuario que se empieza, y verificar en documentación oficial los datos técnicos marcados con (V) e informar del resultado.

## 1. Decisiones del usuario (resumen)

1. **Respaldo y restauración:** en la fase 5 la pestaña tiene lo mínimo (listar sesiones del journal y "Deshacer última sesión"). **Programas de inicio** es un marcador "disponible en la fase 6".
2. **Consola oculta en modo interfaz**, con condiciones: parámetro `-MostrarConsola` para depurar; si WPF no carga, el error se muestra con un método que **no dependa de WPF** (por ejemplo `WScript.Shell.Popup`) y se escribe en el log; como la consola está oculta, la ventana de "Cargando…" debe aparecer **lo antes posible** (el mensaje en consola deja de ser el primer indicio).
3. **Renderizado por software:** preferencia guardada en `%ProgramData%\OptiLow\` y reintento automático si falla la creación de la ventana. Como un fallo de renderizado muchas veces no da error (ventana negra o con basura, sin poder hacer clic en la casilla), hay un **segundo lanzador, `Iniciar (modo seguro).cmd`**, que abre directamente con `-RenderizadoSoftware`.
4. **Perfil simulado en la interfaz:** sí, pero **oculto para el usuario normal**: el selector solo aparece si se abre con un parámetro (`-Demo`). Es solo para ver.
5. **Escala del 150 %:** en 1366x768 quedan unas 911x485 unidades lógicas, menos que el mínimo previsto; hay que definir qué pasa y probarlo (sección 7).
6. **Escritorio de otro usuario:** banner visible en la interfaz, no solo en el log.
7. **Teclado:** orden de Tab lógico; Enter y Espacio activan los controles.

Requisitos que ya estaban en el CLAUDE.md y se mantienen: tema oscuro con colores como recursos en el XAML, sin librerías externas; navegación lateral con cinco pestañas; lista de optimizaciones generada dinámicamente y agrupada por categoría; botones "Seleccionar recomendadas", "Quitar selección" y "Aplicar seleccionadas"; interfaz que nunca se congela (runspace en segundo plano, cola de log, temporizador, un trabajo a la vez, confirmación al cerrar con trabajo en curso); controles localizados por `x:Name`; estado compartido en una sola variable global; opción de renderizado por software.
Peticiones del usuario al plan: usable en 1366x768 con escala del 125 %; **sin efectos pesados** (sombras, desenfoques, animaciones: el público tiene GPUs débiles); arranque en HDD con "Cargando…" lo antes posible y medición del tiempo de apertura; prueba en la VM incluido el modo de software.

## 2. Archivos

| Archivo | Qué hará |
|---|---|
| `UI/MainWindow.xaml` | Ventana, tema oscuro y recursos de color (`SolidColorBrush` con claves); todos los controles con `x:Name`. Sin efectos ni animaciones |
| `UI/Interfaz.ps1` | Crea la ventana, localiza controles por `x:Name`, conecta eventos, construye la lista de optimizaciones y las demás vistas. **Solo llama a funciones de `Core/` y `Modules/`; sin lógica de optimización** |
| `UI/Trabajos.ps1` | Runspace de trabajo, cola de log, `DispatcherTimer`, control de "un trabajo a la vez" y finalización de trabajos |
| `UI/Inicio.ps1` | (o dentro de `Interfaz.ps1`) arranque rápido: splash, medición de tiempos, errores sin WPF |
| `Iniciar.cmd` | Pasa a abrir la interfaz con la consola oculta |
| `Iniciar (modo seguro).cmd` | Igual, con `-RenderizadoSoftware` |
| `Pruebas/Probar-Fase5.ps1` | Autopruebas de la interfaz (sección 13) |
| `docs/IDEAS.md`, `CLAUDE.md`, `docs/ESTADO.md` | Se actualizan al cerrar la fase |

Restricciones técnicas: **sin compilar** (nada de `Add-Type` con C#); la lista de optimizaciones se arma con elementos creados desde código o con enlaces a hashtables (el enlace de WPF a `PSCustomObject` no funciona bien), no con clases propias. `UI/` no la carga el cargador general: la carga `OptiLow.ps1` solo en modo interfaz.

## 3. Modos de arranque, parámetros y lanzadores

| Invocación | Resultado |
|---|---|
| `OptiLow.ps1` sin acciones ni `-Consola` | Abre la interfaz (requiere STA; si el proceso no es STA se relanza con `-STA`) |
| `-Consola` o cualquier acción de consola (`-Diagnostico`, `-Listar`, `-Aplicar`, `-Deshacer`, `-ListarSesiones`) | Modo consola, como hasta ahora |
| `-MostrarConsola` | En modo interfaz, no oculta la consola (depuración) |
| `-RenderizadoSoftware` | Fuerza el renderizado por software (tiene prioridad sobre la preferencia guardada) |
| `-Demo` | Muestra el selector de datos simulados en la pestaña Diagnóstico (sección 11) |
| `-SinElevar` | Abre en modo limitado: sin carpeta de respaldos no se puede aplicar nada (el botón Aplicar se desactiva y lo explica) |

- **Consola oculta:** `Iniciar.cmd` lanza PowerShell con la ventana oculta, y el relanzado elevado usa `ProcessStartInfo.WindowStyle = Hidden`, salvo `-MostrarConsola`. No se oculta una consola que el usuario ya tenía abierta. Sin P/Invoke ni compilación.
- **Orden de arranque en modo interfaz** (para que algo aparezca cuanto antes): comprobación de administrador mínima y relanzado elevado **sin cargar `Core/`**, y en el proceso elevado lo primero es la ventana "Cargando…"; después se carga `Core/`, `Modules/` y `Tweaks/`. (En modo consola se mantiene el orden actual.)
- **Preferencia de renderizado:** archivo pequeño en `%ProgramData%\OptiLow\` (por ejemplo `ui.json`, UTF-8 sin BOM, `ConvertTo-Json -Depth 100`); es una preferencia de la interfaz, no un cambio del sistema, así que no pasa por el journal.

## 4. Arranque rápido y errores sin WPF

1. **Pantalla de "Cargando…" independiente de WPF** (propuesta técnica a confirmar al empezar): un formulario mínimo de Windows Forms (sin bordes, sin efectos, texto "Cargando OptiLow…") en su propio hilo STA, porque cargar WPF (`PresentationFramework`) es lo más lento en un HDD. Se cierra cuando la ventana principal hace su primer dibujo. Si no puede crearse, se continúa sin ella.
2. Carga de las librerías WPF → lectura y construcción del XAML → ventana principal → primer dibujo (`ContentRendered`) → se cierra la pantalla de carga.
3. La ventana principal ya muestra la lista de optimizaciones (las definiciones están en memoria) con el estado "comprobando…", y rellena el diagnóstico y los estados con trabajos en segundo plano.
4. **Errores de arranque sin WPF:** un `try/catch` que envuelve todo el arranque de la interfaz. Si falla la carga de WPF, el XAML o cualquier cosa antes de que la ventana exista: se escribe en el log (o, si el log aún no está listo, en `%TEMP%\OptiLow-error.log`) y se muestra un cuadro con `WScript.Shell.Popup`. (V) Si el Windows Script Host estuviera deshabilitado por directiva, la cadena de respaldo es: `System.Windows.Forms.MessageBox` → `msg.exe` → solo log.
5. **Medición:** se cronometra desde el inicio del proceso (`Process.StartTime`) y se desglosa en aparición de la pantalla de carga, carga de WPF, XAML y primer dibujo. Se escribe en el log, se muestra en la barra de estado ("Abierto en X,X s") y la prueba automática lo imprime.

## 5. Estructura de la ventana

- **Cabecera** compacta (unos 36 de alto): nombre, indicadores de administrador y de journal listo, banners (sección 9).
- **Navegación lateral** (unos 160 de ancho): Diagnóstico, Optimizaciones, Programas de inicio, Respaldo y restauración, Registro.
- **Barra de estado** (unos 24 de alto): trabajo en curso ("Trabajando…" con texto, sin animación), "Abierto en X,X s", modo de renderizado y nivel gráfico (V `RenderCapability.Tier`).
- **Diagnóstico:** datos del equipo en bloques, perfil con su motivo, recomendaciones coloreadas por nivel (Crítico, Aviso, Info, Consejo), optimizaciones recomendadas con su motivo, duración y consultas lentas o fallidas, botón "Actualizar diagnóstico".
- **Optimizaciones:** grupos por categoría; cada fila con casilla, nombre, riesgo, "Reinicio" o "Cerrar sesión" si aplica, estado (Aplicado, Pendiente, No aplica, Error), marca de recomendada con su motivo, y descripción completa (con el efecto secundario) en un panel de detalle de la fila seleccionada. Las filas ya aplicadas o que no aplican no se seleccionan. Botones "Seleccionar recomendadas" (omite las ya aplicadas), "Quitar selección", "Aplicar seleccionadas" y la opción "Omitir el punto de restauración (no recomendado)".
- **Programas de inicio:** marcador "disponible en la fase 6".
- **Respaldo y restauración (mínimo):** lista de sesiones (`Get-JournalSesiones`: id, inicio, estado, entradas, optimizaciones), "Actualizar" y "Deshacer última sesión" (confirmación, resultado con restauradas y fallidas, y refresco de los estados).
- **Registro:** vista del log con color por nivel (máximo unas 2000 líneas en pantalla), "Copiar", "Abrir carpeta de logs" y "Limpiar vista".

### Flujo de "Aplicar seleccionadas" (máquina de estados en la interfaz)
1. Comprobar que el journal está listo (si no, explicarlo; el botón ya viene desactivado).
2. Diálogo de confirmación con la lista de cambios y descripción de cada uno; advertencia **aparte** si hay riesgo Alto o no reversibles; el banner de escritorio de otro usuario se repite en el diálogo si aplica.
3. Trabajo "Preparar": sesión nueva del journal + punto de restauración (salvo que se haya marcado omitirlo).
4. Decisiones del usuario con diálogos, igual que en la consola: protección desactivada o sin espacio → ofrecer activarla avisando de que **usa espacio en disco**; ya existe un punto reciente → mostrar fecha y descripción y ofrecer continuar con ese o cancelar; error → preguntar si continuar sabiendo que el journal sigue funcionando.
5. Trabajo "Aplicar" (`Invoke-TweaksLote`), en **la misma sesión** del journal y el mismo runspace.
6. Resumen con estado por optimización y aviso de reiniciar o cerrar sesión; refresco de estados.

## 6. Trabajos en segundo plano

- **Un runspace de trabajo de larga vida**, creado al arrancar y en segundo plano: carga el proyecto con el mismo cargador, recibe la cola de log compartida (`ConcurrentQueue`) y escribe en ella (`LogDestino = 'Cola'`). La sesión del journal vive en ese runspace y se conserva entre trabajos.
- Los comandos se pasan **como texto** (`AddScript`), nunca como scriptblock. Los resultados vuelven por la colección de salida.
- **`DispatcherTimer` de ~200 ms** en el hilo de la interfaz: vacía la cola (con tope de líneas por vuelta), actualiza el texto "Trabajando…" y detecta el final del trabajo; los manejadores de final se ejecutan en el hilo de la interfaz.
- **Un trabajo a la vez:** mientras corre, se desactivan los botones de acción.
- **Cerrar con un trabajo en curso:** confirmación; si el usuario insiste, se cierra avisando de que lo aplicado a medias queda en el journal y puede deshacerse. No se cancela un trabajo a la mitad.
- Trabajos previstos: inicialización del runspace, diagnóstico, estados de todas las optimizaciones, recomendadas para un hardware dado, preparar (sesión + punto), activar protección, aplicar, listar sesiones, deshacer, y un trabajo de prueba (sin efectos) para medir si la interfaz se congela.

## 7. Pantallas pequeñas y escalas

Con la barra de tareas (~40 px) el área de trabajo de 1366x768 es 1366x728 px:

| Escala | Unidades lógicas útiles |
|---|---|
| 100 % | 1366 x 728 |
| 125 % | 1093 x 582 |
| 150 % | 911 x 485 |

- **Tamaño inicial:** 1000x600 recortado al área de trabajo. **Mínimo: 860 x 460** (se reduce el alto mínimo previsto de 560 a 460 para que quepa a 150 %: 911x485).
- **Qué pasa a 150 %:** todo el contenido vive dentro de `ScrollViewer`; cabecera (~36), barra de estado (~24) y navegación lateral siempre visibles; la barra de acciones de Optimizaciones queda fija y el resto se desplaza. Nada de anchos fijos grandes: botones en `WrapPanel`, textos largos con recorte y tooltip. Fuente de 13 px como mínimo.
- **Prueba automática:** abre la ventana a 1093x582, 911x485 y 860x460 (y 1366x728), recorre las cinco pestañas y comprueba: sin desbordamiento horizontal (extensión ≤ ventana), los botones de acción alcanzables (visibles o a un desplazamiento), cabecera, navegación y barra de estado visibles, y que a 911x485 y 860x460 el contenido se desplaza verticalmente en vez de cortarse.
- DPI: WPF escala con el DPI del sistema; comprobar en la VM con 100, 125 y 150 % que el texto no sale borroso ni cortado. (V) comportamiento de DPI dentro de `powershell.exe`.

## 8. Sin efectos pesados en la propia interfaz

- Prohibido: `DropShadowEffect`, `BlurEffect`, cualquier `Effect`, `AllowsTransparency`, `Storyboard`, animaciones, imágenes de mapa de bits e iconos de fuentes especiales. Todo en colores sólidos; `UseLayoutRounding` y `SnapsToDevicePixels`.
- Indicador de trabajo: texto que cambia con el temporizador, no `ProgressBar` indeterminada.
- **Verificación estática:** la prueba busca esos elementos en el XAML y falla si aparece alguno.

## 9. Banners (visibles, no solo log)

- **Escritorio de otro usuario:** `Test-EscritorioDeOtroUsuario` al arrancar; si es distinto, banner fijo (no se puede cerrar) con el texto del CLAUDE.md: los cambios de `HKCU` y `%APPDATA%` se aplicarían a la cuenta equivocada. Se repite en el diálogo de confirmación de aplicar.
- **Sin carpeta de respaldos / sin administrador:** banner que explica por qué no se puede aplicar nada.
- **Simulado** (solo con `-Demo`): banner "SIMULADO – solo para ver".

## 10. Teclado

- Orden de Tab lógico y coherente con el orden visual (cabecera, navegación, contenido, barra de acciones); `IsTabStop` y `Focusable` en todo control interactivo; indicador de foco visible con borde sólido (sin efectos).
- Enter y Espacio activan botones; Espacio marca y desmarca las casillas de las filas; flechas en la navegación lateral y entre filas; Enter y Esc en los diálogos (`IsDefault` / `IsCancel`); teclas de acceso (Alt+letra) en los botones principales.
- Prueba automática: todos los controles interactivos son enfocables, `TabIndex` monótono respecto al orden visual, los botones de diálogo tienen `IsDefault`/`IsCancel`. Prueba manual: recorrer todo solo con teclado.

## 11. Selector de datos simulados (`-Demo`)

- Solo aparece con `-Demo`, en la pestaña Diagnóstico: "Datos: Este equipo / Simulado Bajo / Simulado Medio / Simulado Alto".
- Con un perfil simulado: banner "SIMULADO"; se activa `SimulacionActiva` (en la interfaz y en el runspace de trabajo), así `Assert-JournalListo` rechaza cualquier escritura o deshacer aunque algo fallara en la interfaz; **Aplicar y Deshacer quedan desactivados** con la explicación; "Seleccionar recomendadas" sí funciona para ver qué se marcaría.
- Volver a "Este equipo" desactiva la simulación. Sin `-Demo` el selector no existe. `-PerfilSimulado` sigue siendo un parámetro de consola.

## 12. Renderizado por software

- `RenderOptions.ProcessRenderMode = SoftwareOnly` debe fijarse **antes de crear la primera ventana**. (V) Confirmar la semántica y el efecto en la documentación.
- Orden de prioridad: `-RenderizadoSoftware` > preferencia guardada > automático. La casilla de la interfaz guarda la preferencia y pide reabrir.
- **Reintento automático:** si crear la ventana lanza una excepción con el modo normal, se reintenta una vez en modo software y se avisa en el log.
- **Modo seguro:** `Iniciar (modo seguro).cmd` abre ya en software, para el caso de ventana negra o con basura donde no se puede ni tocar la casilla.
- La barra de estado muestra el modo y el nivel gráfico (V `RenderCapability.Tier`), y el log los registra.

## 13. Pruebas

### Automática: `Pruebas/Probar-Fase5.ps1` (VM; no aplica nada real)
Comprueba, abriendo la ventana en el propio proceso y manejándola con el dispatcher:
1. Existen todos los controles con `x:Name` y las cinco pestañas; navegación entre ellas.
2. Diseño a 1366x728, 1093x582, 911x485 y 860x460 (sección 7).
3. XAML sin efectos pesados (sección 8).
4. La interfaz **no se congela** durante un trabajo: mide los huecos entre ticks del temporizador con un trabajo de prueba y exige que ninguno pase de 250 ms.
5. La cola de log se vacía en la vista; los botones se desactivan durante un trabajo y se reactivan al terminar; solo un trabajo a la vez.
6. Lógica de cierre con trabajo en curso.
7. Flujo de aplicar con funciones de prueba en el runspace (sin tocar el sistema): confirmación, decisiones del punto de restauración, una sola sesión.
8. Bloqueo del modo simulado (Aplicar y Deshacer desactivados y rechazados por el motor).
9. Teclado (sección 10) y banners (sección 9).
10. Tiempo de apertura desglosado, en modo normal y en software; capturas PNG de cada pestaña en `%TEMP%\OptiLow-capturas\` para revisar a ojo o enviar.

### Manual en la VM (con snapshot)
- Resoluciones 1366x768 con escala 100, 125 y 150 %.
- Abrir con `Iniciar.cmd`, con `Iniciar (modo seguro).cmd` y con `-RenderizadoSoftware`; comparar tiempo de apertura y fluidez.
- VM con 1 CPU y 1-2 GB de RAM para acercarse a un equipo viejo.
- Recorrer las cinco pestañas solo con teclado.
- Aplicar una optimización real y deshacerla desde la pestaña Respaldo; comprobar el aviso de reinicio.
- Simular un error de arranque (por ejemplo renombrar `UI\MainWindow.xaml`): debe aparecer el cuadro sin WPF y quedar en el log.
- Con `-Demo`, probar los tres perfiles simulados y que no se puede aplicar nada.
- Probar `-SinElevar` (modo limitado).

## 14. Fuera de alcance (fase 6) y riesgos conocidos
- Fuera de alcance: contenido real de Programas de inicio, Respaldo y restauración completo (puntos de restauración, restaurar sesiones concretas, deshacer un solo tweak), más tweaks, bloatware, Discord y navegadores.
- Riesgos: coste de cargar WPF en HDD (se mide y se informa, no se puede eliminar); el hilo de la pantalla de carga en Windows Forms añade su propia carga (se mide); ocultar la consola dificulta ver errores de arranque (por eso el cuadro sin WPF y `-MostrarConsola`); WSH podría estar bloqueado por directiva; enlace de datos de WPF con objetos de PowerShell (se evita con elementos creados desde código).

## 15. Datos técnicos a verificar antes de usarlos (V)
- Semántica de `RenderOptions.ProcessRenderMode` y cuándo debe fijarse; significado de `RenderCapability.Tier`.
- Comportamiento de DPI de WPF dentro de `powershell.exe` (escala del sistema, nitidez).
- Disponibilidad y límites de `WScript.Shell.Popup` y alternativas si WSH está bloqueado.
- Crear un formulario de Windows Forms en otro hilo STA y cerrarlo desde el hilo principal de forma segura.

## 16. Resultado de la verificación de los datos (V) y de la medición (hecha al empezar la fase)
- **`RenderOptions.ProcessRenderMode`** (Microsoft Learn): `SoftwareOnly` fuerza el renderizado por software en el proceso; es una **preferencia** y "otras partes del sistema pueden forzar software igualmente"; prioridad: clave de registro `DisableHWAcceleration` > `ProcessRenderMode` > `RenderMode` de cada ventana. La documentación no dice que deba fijarse antes de la primera ventana: se hace así por prudencia. Se fija y se lee de vuelta sin problema.
- **`RenderCapability.Tier`**: palabra alta del valor (`Tier -shr 16`); 0 = sin aceleración o DirectX < 9, 1 y 2 = con aceleración (2 pide más VRAM y sombreadores). **Medido: con `SoftwareOnly` sigue devolviendo 2**; informa de la capacidad, no del modo en uso. La barra de estado muestra los dos datos por separado.
- **`WScript.Shell.Popup`**: `Popup(texto, segundos, título, tipo)`; `tipo` como `MessageBox` (16 = error, 48 = aviso); devuelve el botón pulsado o -1 si se agotó el tiempo. Funciona desde 5.1 en este equipo. Cadena de respaldo implementada: `MessageBox` de Windows Forms -> `msg.exe` -> solo archivo.
- **DPI dentro de `powershell.exe`**: `IsProcessDPIAware` es False al arrancar y pasa a True al crear la primera ventana WPF (a 96 DPI no se puede ver la nitidez; queda para la VM con 125 y 150 %).
- **Windows Forms en otro hilo STA**: se puede crear y cerrar de forma limpia desde el hilo principal con `BeginInvoke`, pero no se usa (ver el estado al principio).
