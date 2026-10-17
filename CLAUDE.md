# CLAUDE.md — OptiLow (nombre provisional)

Utilidad de optimización de Windows en PowerShell + WPF/XAML, inspirada en WinUtil de Chris Titus.
Enfoque principal: equipos de bajos recursos (CPU de 2–4 núcleos antiguos, 4 GB de RAM, discos HDD, gráficos integrados viejos), con recomendaciones que se adaptan a gama media y alta.

Idioma: toda la interfaz, los mensajes de log, los comentarios del código y la documentación van en **español**.

---

## Forma de trabajar en este proyecto

- Trabaja **por fases**, una a la vez. Al terminar cada fase, resume qué hiciste, qué falta y cómo probarlo, y espera mi confirmación antes de seguir.
- Antes de cambios grandes de arquitectura, propón el plan primero y no escribas código hasta que lo apruebe.
- No agregues funcionalidades que no estén en la fase actual. Si se te ocurre una mejora, anótala en `docs/IDEAS.md` en lugar de implementarla.
- Si un dato técnico (ruta de registro, nombre de servicio, clave de configuración) no es seguro, dilo y verifícalo en documentación oficial; no lo inventes.

### Fases

1. Estructura de carpetas, cargador, verificación de administrador y logging.
2. Funciones comunes de registro, servicios, tareas programadas y archivos, con respaldo automático (journal). Punto de restauración.
3. Motor de tweaks y 2–3 tweaks de prueba ejecutables desde consola (sin interfaz).
4. Módulo de diagnóstico de hardware y recomendaciones.
5. Interfaz XAML y conexión de eventos.
6. Resto de tweaks, pestaña de programas de inicio y pestaña de respaldo/restauración.
7. Documentación (`README.md` y `docs/ARQUITECTURA.md`).

**Al empezar una sesión nueva, lee primero `docs/ESTADO.md` (qué fases están terminadas, resultados en la VM, pendientes y cómo se prueba todo) y el plan de la fase en curso (la fase 5 está escrita y su plan, `docs/PLAN-FASE5.md`, queda como referencia de las decisiones; la fase 6 aún no tiene plan).** Espera mi orden antes de empezar a escribir código de una fase.

---

## Entorno objetivo

- **Windows PowerShell 5.1** es el objetivo principal, porque viene en todos los equipos. Todo debe funcionar ahí. Compatible con PowerShell 7 cuando sea posible, pero nunca a costa de 5.1.
- No usar sintaxis exclusiva de PowerShell 7: ni operador ternario, ni `??`, ni `ConvertFrom-Json -AsHashtable`, ni `Join-Path` con más de dos argumentos.
- Windows 10 y Windows 11.
- Sin dependencias externas, sin compilar, sin instalar módulos. Solo lo que trae Windows.
- **Codificación: todos los `.ps1` en UTF-8 con BOM.** Sin BOM, PowerShell 5.1 rompe acentos y "ñ". Los `.xaml`, `.md`, `.txt` y `.json` del proyecto en UTF-8.

---

## Estructura de carpetas

```
Proyecto_Patata/       Raíz del repositorio
├── OptiLow.ps1        Punto de entrada: admin, STA, modo consola o interfaz
├── Iniciar.cmd        Lanzador de doble clic (Windows PowerShell 5.1, ExecutionPolicy Bypass; consola oculta sin argumentos)
├── Iniciar (modo seguro).cmd  Igual, con el renderizado por software forzado
├── CLAUDE.md          Instrucciones del proyecto
├── Core/              Utilidades sin interfaz (no tocan WPF)
├── Modules/           Diagnóstico de hardware, programas de inicio
├── Tweaks/            Un archivo por categoría de optimización
├── Config/            Listas editables sin tocar código
├── UI/                MainWindow.xaml, Interfaz.ps1 (ventana, eventos, vistas), Trabajos.ps1 (runspace, cola, temporizador) e Inicio.ps1 (arranque)
├── Pruebas/           Scripts de autopruebas para VM (el cargador nunca los carga)
└── docs/              Arquitectura, ideas, ESTADO.md (dónde vamos) y PLAN-FASEn.md (plan de la fase en curso)
```

Datos en tiempo de ejecución (logs y respaldos) en `%ProgramData%\OptiLow\`, nunca dentro de la carpeta del programa.

### Reglas de capas

- `Core/`, `Modules/` y `Tweaks/` **no deben conocer la interfaz**. Deben poder usarse desde consola.
- `UI/` solo llama a funciones de las otras capas; no contiene lógica de optimización.
- Un único cargador (`Core/Loader.ps1`) carga todo en orden. Los archivos de `Tweaks/` cuyo nombre empiece con `_` (plantillas) no se cargan.
- `Core/` se carga en un **orden fijo declarado** en el cargador (Paths antes que Logging), no alfabético. Un fallo en `Core/` es **fatal**: se detiene el programa con un mensaje claro.
- `Modules/` y `Tweaks/` toleran fallos: si un archivo tiene un error, se registra en el log y el resto del programa sigue funcionando.
- Las funciones de cada archivo cargado se promueven al ámbito global, para que sigan disponibles aunque la carga ocurra dentro de una función (por ejemplo, en el runspace de la interfaz).
- Si `%ProgramData%\OptiLow\logs` no se puede escribir (p. ej. con `-SinElevar`), se usa `%TEMP%\OptiLow\logs` como respaldo y se avisa.

---

## Contrato de una optimización (tweak)

Cada optimización se registra como una definición declarativa con estos campos:

| Campo | Obligatorio | Descripción |
|---|---|---|
| Id | Sí | Minúsculas, números y guiones. Único. Ej.: `discord-hwaccel-off` |
| Nombre | Sí | Texto corto para la interfaz |
| Categoría | Sí | Agrupa en la interfaz |
| Descripción | Sí | Qué hace, por qué ayuda y **qué efecto secundario tiene** |
| Riesgo | Sí | Bajo / Medio / Alto |
| Requiere | No | Nada / Cerrar sesión / Reiniciar |
| Reversible | No | Por defecto sí. Falso si el journal no puede deshacerlo |
| Aplicar | Sí | Bloque que hace el cambio |
| Comprobar | No | Devuelve aplicado (verdadero), pendiente (falso) o "no aplica" (nulo, p. ej. si el programa no está instalado) |
| Recomendar | No | Recibe el objeto de hardware (`param($Hardware)`) y decide si se preselecciona. Devuelve `$true`/`$false` o, mejor, `New-Recomendacion -Si <bool> -Motivo '<por qué>'`: el motivo se muestra al usuario ("GPU antigua detectada: …"). Sin este bloque el tweak nunca se recomienda |

Reglas:

- **Toda escritura al sistema dentro de un tweak pasa por las funciones comunes de `Core/`** (registro, servicios, tareas, archivos, plan de energía). Nunca escribir directo con `Set-ItemProperty`, `Set-Service`, etc. Así todo queda en el journal y se puede deshacer.
- Si el valor ya es el deseado, no se escribe ni se registra en el journal.
- Los bloques no dependen de variables externas; si necesitan datos compartidos, usan una función auxiliar.
- Los bloques no usan `Write-Host`; solo la función de log del proyecto.
- Debe existir `Tweaks/_Plantilla.ps1` comentada para crear tweaks nuevos.
- **Motor (`Core/Tweaks.ps1`):** `Register-Tweak` valida el contrato y **rechaza** el tweak (con un ERROR en el log, sin impedir que se cargue el resto del archivo) si el Id no es válido o está repetido, si la descripción es demasiado corta o si `Aplicar`/`Comprobar`/`Recomendar` usan comandos prohibidos (escritura directa, `sc.exe`, `powercfg`, `Write-Host`...). Los bloques se guardan como texto y se recrean al ejecutarlos.
- `Aplicar` solo deja salir lo que devuelven las funciones de `Core/` (`Cambiado`, `SinCambios`, `NoAplica`, `Fallido`). `Comprobar` verifica la **configuración**, no el estado en ejecución (cambiar un servicio a Disabled no lo detiene: por eso `telemetria-servicios-off` es `Requiere = Reiniciar`) y devuelve `$true`/`$false`/`$null`; con varios elementos usa `Join-EstadosTweak`.
- Resultado de un tweak con varios elementos: `Aplicado` si todos los que existen quedaron bien, `NoAplica` solo si no existe ninguno, `Parcial` si alguno falló (p. ej. acceso denegado), `Fallido` si todos fallaron. Una excepción en un bloque se registra y no detiene a los demás tweaks.
- Cada entrada del journal guarda el `TweakId` del tweak que la generó (permite deshacer un solo tweak más adelante desde la interfaz). Una ejecución de aplicar es **una sola sesión** del journal, aunque incluya varios tweaks. El resumen final avisa de qué tweaks piden reiniciar o cerrar sesión.

### Criterios de Recomendar de los tweaks actuales

| Tweak | Se recomienda cuando | No se recomienda |
|---|---|---|
| `efectos-transparencia-off` | perfil Bajo, **GPU antigua (nivel 1)** o GPU sin driver; el motivo lo dice | resto |
| `telemetria-tareas-off` | el disco del sistema es un HDD fiable, o el perfil es Bajo (esas tareas son las que más cargan un HDD) | SSD y perfil no Bajo |
| `telemetria-servicios-off` | el equipo NO está administrado (`PartOfDomain`, `DomainJoined`, `AzureAdJoined` y `EnterpriseJoined` falsos) | administrado -> no, con Info y advertencia (Intune/MDM); si `dsregcmd` no da datos -> no, por precaución |

Criterios ya fijados para tweaks futuros: aceleración por hardware (Discord, Chromium) solo con GPU antigua (nivel 1) o sin driver; SysMain solo en HDD; WSearch nunca automático; plan de energía "Alto rendimiento" solo en equipos sin batería; bloatware nunca automático. Si un criterio no está aquí ni en "Datos técnicos verificados", se propone al usuario antes de implementarlo.

---

## Journal de respaldo (deshacer)

- **El journal es obligatorio.** Si `DirRespaldos` es `$null` (sin administrador, `-SinElevar`, o permisos incorrectos), el programa se niega a aplicar cualquier cambio y lo explica.
- Antes de cada cambio se guarda el estado original en un JSON en `%ProgramData%\OptiLow\backups\`, un archivo por sesión.
- **Seguridad de `backups\`:** solo se crea elevado. Propietario Administradores (`S-1-5-32-544`), sin herencia de `ProgramData`, y acceso (también de lectura) únicamente para Administradores y SYSTEM; los permisos se heredan a los archivos de dentro. Se identifican por SID, no por nombre. Con `-SinElevar` no se crea. Antes de cada sesión y antes de deshacer se verifica; si falla, se niega. Una carpeta preexistente con permisos incorrectos y contenido se renombra a `backups.sin-verificar-<fecha>` (nunca se usa para deshacer ni se borra; se indica su ruta en el log).
- Tipos de entrada: Registro (incluye si el valor existía, su tipo y su dato, y qué claves creamos), Servicio (valor `Start` y `DelayedAutostart` originales), Tarea programada, Archivo (copia de respaldo con hash), Json (una sola clave de un JSON; al deshacer se restaura solo esa clave y se conserva lo que el usuario cambió después; la copia completa queda como respaldo de emergencia) y Plan de energía. También hay entradas tipo Nota para cambios no reversibles.
- Registro: soporta DWORD, QWORD, String, ExpandString (se guarda sin expandir variables), MultiString y Binary. Se abre siempre con `RegistryView.Registry64` (sin redirección a `WOW6432Node`). Si la clave o el valor no existían, el deshacer los elimina, pero solo si los creamos nosotros (y una clave solo si queda vacía).
- Las funciones de escritura devuelven `Cambiado`, `SinCambios`, `NoAplica` o `Fallido`; un fallo se registra en el log (con el nombre del objeto) y no detiene el resto.
- **Un cambio que falla sin haber tocado nada no queda en el journal** (se quita la entrada). Si pudo quedar a medias, la entrada se conserva como `Fallida` para que el deshacer lo revierta.
- **Todo `ConvertTo-Json` del proyecto lleva `-Depth 100`** (journal incluido): en Windows PowerShell 5.1 el valor por defecto es 2 y convierte los objetos anidados en texto como `System.Collections.Hashtable`, lo que dañaría archivos como el `settings.json` de Discord.
- Las entradas que ya se revirtieron en el momento (p. ej. el ajuste temporal de la frecuencia de puntos de restauración) se marcan `Restaurada`; el deshacer las omite y lo explica en el log.
- El archivo se guarda después de cada entrada, no al final, para sobrevivir a un cierre inesperado.
- "Deshacer última sesión" recorre las entradas en orden inverso y luego marca el archivo como restaurado para no repetirlo.
- La restauración no se registra a sí misma en un journal nuevo.
- Si alguna entrada falla al restaurar, el archivo se marca como **restauración parcial** e indica qué entradas fallaron (no como restaurado completo), y el resto de entradas se siguen procesando.

---

## Seguridad

- Verificar administrador al inicio. Si no lo es, relanzar elevado con UAC (`-Verb RunAs`, `-ExecutionPolicy Bypass`, `-STA`), usando el ejecutable del mismo PowerShell (`$PSHOME`) y no el del host (ISE o VS Code).
- **Punto de restauración** activado por defecto antes de aplicar:
  - **Método:** en Windows PowerShell 5.1 usar `Checkpoint-Computer -RestorePointType MODIFY_SETTINGS`; la clase CIM `SystemRestore` (`CreateRestorePoint`) queda solo como respaldo para PowerShell 7, donde `Checkpoint-Computer` no existe. **Motivo (probado en una VM con Windows 11 24H2):** con `SystemRestorePointCreationFrequency = 0`, `CreateRestorePoint` por CIM terminó en menos de un segundo sin crear el punto (había uno de las últimas 24 h), mientras que `Checkpoint-Computer` con el mismo ajuste sí lo creó. `Pruebas/Diagnostico-PuntoRestauracion.ps1` (misma VM) mostró que CIM sí creó el punto en otra ocasión (tipos 12 y 0, `ReturnValue = 0`, unos 5 s), así que el fallo es **inconsistente**. **Hipótesis (no confirmada):** el proveedor de `SystemRestore` lee la frecuencia al cargarse y, en la primera prueba, ya estaba cargado (por la comprobación de la protección) antes de ajustarla a 0. Con `Invoke-WmiMethod` los argumentos posicionales siguen el orden que devuelve WMI (`Description`, `EventType`, `RestorePointType`, comprobado), no el de la documentación; la variante de prueba los pasaba intercambiados. Tema cerrado: `Checkpoint-Computer` en 5.1, CIM solo como respaldo en PowerShell 7. Del método CIM se registra siempre el `ReturnValue`; nunca se asume S_OK, y el éxito se comprueba con los `SequenceNumber`.
  - Windows limita a uno cada 24 h (y en ese caso **omite el punto sin dar error**): ajustar temporalmente `SystemRestorePointCreationFrequency = 0` (a través del journal) y restaurar el valor original en un bloque `finally`. Comprobar que el punto se creó comparando los `SequenceNumber` antes y después. Si Windows lo omite igualmente, el motivo es `YaExisteReciente` e indica la fecha, hora y descripción del punto reciente, para que la consola o la interfaz ofrezcan continuar con ese punto o cancelar.
  - **`Core/` no activa la Protección del sistema por su cuenta.** `New-PuntoRestauracion` devuelve un motivo claro (protección desactivada, sin espacio asignado, bloqueada por directiva, otro error). La consola o la interfaz preguntan al usuario antes de llamar a `Enable-ProteccionSistema`, avisando de que usa espacio en disco.
  - Si falla, preguntar al usuario si desea continuar, explicando que el journal sigue funcionando.
- Mostrar confirmación antes de aplicar, con la lista de cambios, y advertencia aparte si hay cambios de riesgo Alto o no reversibles.
- Detectar si el escritorio pertenece a otro usuario distinto del que corre el script (caso de elevación con credenciales de otra cuenta) y avisar que los cambios de `HKCU` y `%APPDATA%` se aplicarán a la cuenta equivocada.
- Nada se aplica sin acción explícita del usuario. El diagnóstico solo lee.

---

## Interfaz (WPF/XAML)

- Tema oscuro, colores definidos como recursos en el XAML, sin librerías externas.
- Navegación lateral con pestañas: Diagnóstico, Optimizaciones, Programas de inicio, Respaldo y restauración, Registro (log).
- La lista de optimizaciones **se genera dinámicamente** a partir de los tweaks registrados, agrupada por categoría, mostrando riesgo, si requiere reinicio y su estado actual.
- Botones: "Seleccionar recomendadas" (según el hardware, omitiendo las ya aplicadas), "Quitar selección", "Aplicar seleccionadas".
- **La interfaz nunca se congela**: diagnóstico, comprobación de estados, punto de restauración y aplicación de tweaks se ejecutan en un runspace en segundo plano.
  - El runspace carga el proyecto con el mismo cargador.
  - Los bloques de código se pasan como texto, no como scriptblock, para que no se ejecuten en el hilo de la interfaz.
  - Un temporizador en el hilo de la interfaz vacía una cola compartida de log y detecta cuando termina el trabajo.
  - Solo un trabajo a la vez; los botones se deshabilitan mientras tanto.
  - Si se intenta cerrar la ventana con un trabajo en curso, pedir confirmación.
- Los controles con nombre se obtienen a partir de sus `x:Name` del XAML; el estado compartido en una sola variable global, no en variables sueltas.
- Opción para forzar renderizado por software (útil con drivers de video rotos), ya que WPF también usa la GPU.
- **El plan aprobado de la fase 5 (decisiones y ajustes del usuario) está en `docs/PLAN-FASE5.md`; manda sobre estas viñetas generales.** Resumen: la consola de PowerShell va oculta en modo interfaz (`-MostrarConsola` para depurar) y los errores de arranque se muestran sin depender de WPF; pantalla de "Cargando…" lo antes posible; funciona en 1366x768 con escala del 100, 125 y 150 %; sin sombras, desenfoques ni animaciones; renderizado por software con preferencia guardada, reintento automático y lanzador "Iniciar (modo seguro).cmd"; el selector de perfil simulado solo existe con `-Demo` y es solo para ver; banner visible si el escritorio es de otro usuario; navegación completa con teclado; la pestaña de Respaldo es mínima (listar y deshacer la última) y Programas de inicio es un marcador hasta la fase 6.
- **Fase 5 implementada** (decisiones en `docs/PLAN-FASE5.md`; lo siguiente es lo que quedó distinto o se midió):
  - **Sin pantalla de "Cargando…" aparte.** Se midió el formulario de Windows Forms en otro hilo (aprobado con la condición de medirlo): aparece ~100 ms DESPUÉS de lo que tarda en cargar WPF (15-90 ms con el disco en caché) y, al crearse antes que la primera ventana WPF, saldría borroso con escala del 125-150 % (`powershell.exe` no declara DPI hasta que WPF crea su primera ventana: `IsProcessDPIAware` pasa de False a True). Por eso la propia ventana principal aparece enseguida con un panel "Cargando…" (parte del XAML) y `Core/`, `Modules/` y `Tweaks/` se cargan archivo por archivo dejando pintar entre uno y otro (`Invoke-BombearUI`). No hay hilo ni formulario que cerrar. Los tiempos por etapa (desde el inicio del proceso) van al log y a la barra de estado ("Abierto en X,X s"); no se pudo medir un HDD frío.
  - **Arranque en modo interfaz** (`OptiLow.ps1` sin acción de consola ni `-Consola`): solo se cargan `Paths`, `Logging` y `Admin` para comprobar el administrador y relanzar (la consola del proceso elevado va oculta con `ProcessWindowStyle.Hidden`, salvo `-MostrarConsola`); si el proceso no es STA se relanza con `-STA`; el resto de `Core/` lo carga `UI/Inicio.ps1` con la ventana ya abierta. Un error de arranque se muestra con `Show-ErrorSinWpf` (en `OptiLow.ps1`): log y `%TEMP%\OptiLow-error.log`, `WScript.Shell.Popup` (documentado: `Popup(texto, segundos, título, tipo)`, devuelve el botón pulsado o -1 si se agotó el tiempo), `MessageBox` de Windows Forms, `msg.exe`.
  - **Renderizado por software:** `RenderOptions.ProcessRenderMode = SoftwareOnly` se fija antes de crear la primera ventana; la documentación dice que es una **preferencia** (el sistema puede forzar software igualmente) y que la clave de registro `DisableHWAcceleration` tiene prioridad. `RenderCapability.Tier` (palabra alta: 0 sin aceleración o DirectX < 9, 1 y 2 con aceleración) informa de la **capacidad del equipo y NO cambia con `SoftwareOnly`** (medido: sigue en 2); por eso la barra de estado muestra el modo y el nivel por separado. Prioridad: `-RenderizadoSoftware` > preferencia guardada (`%ProgramData%\OptiLow\ui.json`, UTF-8 sin BOM) > automático; si crear la ventana lanza una excepción se reintenta una vez en software. Una ventana negra sin excepción solo se resuelve con `Iniciar (modo seguro).cmd`.
  - **Instancia única y aviso de apertura (tras la VM):** `Enter-InstanciaUnica` (mutex `Global\OptiLow_Interfaz`, en `Core/Admin.ps1`) se toma en `OptiLow.ps1` ANTES de pedir el UAC (así un doble clic rápido no pide dos UAC); el proceso elevado espera hasta 8 s al que lo lanzó. Un segundo arranque llama a `Show-YaAbierto`: trae al frente la ventana existente con `AppActivate` o, si no puede (otro nivel de permisos, o aún se está abriendo), muestra un aviso de 8 s y sale. `Iniciar.cmd` lanza PowerShell oculto con `start` y su propia ventana muestra «Abriendo OptiLow, puede tardar unos segundos…» hasta que existe `%TEMP%\OptiLow-abierto.flag` (lo crea `Write-SenalApertura` cuando la ventana ya es visible o cuando un error/aviso la sustituye; tope de 2 minutos).
  - **Diagnóstico a prueba de datos raros:** cada parte se pinta aislada (`Invoke-SeccionDiagUI`): si una falla se omite, se registra y el resto se pinta; si falla el trabajo, no devuelve datos o falla todo el pintado, la pestaña lo dice con un mensaje claro y las recomendaciones y los botones se actualizan igualmente. Las líneas pueden ir sin etiqueta.
  - **Cierre en cualquier momento:** `Invoke-BombearUI` no bombea si la ventana se cerró o el distribuidor terminó (`$ui.Cerrada`, fijada por un `Closed` temprano): lanza la señal interna `OPTILOW-VENTANA-CERRADA` y `Start-OptiLowInterfaz` sale con 0 sin avisos. Antes, cerrar tras `Initialize-ContenidoUI` (cuando ya está el `InvokeShutdown`) hacía fallar el siguiente `PushFrame` con «se cerró el distribuidor» y salía el cuadro de error. Prueba: `-SoloArranque -CerrarEn <etapa>`.
  - **Usabilidad:** Enter activa casillas y botones de opción como el clic (`Invoke-EnterControlUI`); los botones desactivados explican por qué en su tooltip (`ToolTipService.ShowOnDisabled` + `Set-AyudaControlUI`); el menú lateral mide 190 y el texto salta de línea; el registro salta de línea; Optimizaciones explica que lo aplicado se deshace desde «Respaldo y restauración» (deshacer una sola optimización desde su fila queda para la fase 6, `docs/PLAN-FASE6.md`).
  - **Trabajos:** un runspace de larga vida (`UI/Trabajos.ps1`, textos de trabajo en `$global:OptiLowScriptsTrabajo`), `DispatcherTimer` de 200 ms, un trabajo a la vez, cola de log compartida; el estado de la interfaz está en `$global:OptiLowUI` y los controles en `$global:OptiLowUI.C` (de los `x:Name` del XAML, ignorando los de `<Window.Resources>`). Los diálogos son ventanas propias (`Show-DialogoOptiLow`, sustituible en pruebas); «Aplicar» encadena los trabajos `preparar` → (decisión del usuario sobre el punto de restauración) → `aplicar`, con las mismas decisiones que la consola.

### Modo consola

`OptiLow.ps1` acepta parámetros para usarse sin interfaz: listar tweaks y su estado, mostrar diagnóstico, aplicar una lista de IDs (o "recomendados"), y omitir el punto de restauración. Sirve para pruebas y automatización.

Parámetros actuales: `-Consola`, `-MostrarConsola`, `-RenderizadoSoftware`, `-Demo` (los tres últimos, del modo interfaz; ver arriba), `-Diagnostico`, `-PerfilSimulado Bajo|Medio|Alto` (solo con `-Diagnostico`), `-Listar`, `-ListarSesiones`, `-Aplicar <ids separados por comas y/o la palabra recomendados>`, `-Deshacer` (por defecto la última sesión no restaurada; con `-Sesion <Id>` otra), `-SinPuntoRestauracion`, `-SinPreguntar`, `-SinElevar`. Códigos de salida: 0 bien, 1 fallos o error, 2 cancelado.

`-Aplicar recomendados` ejecuta el diagnóstico REAL, evalúa el bloque `Recomendar` de cada tweak con ese objeto, **muestra por qué** se recomienda o no cada uno, omite los ya aplicados o que no aplican, y sigue el flujo normal (confirmación, punto de restauración, una sola sesión del journal). Se puede combinar con Ids explícitos.

**`-PerfilSimulado` es solo para ver.** Bloqueo estricto: con un perfil simulado `Assert-JournalListo` rechaza cualquier escritura o deshacer, y la combinación con `-Aplicar` o `-Deshacer` se rechaza antes de pedir elevación.

`-SinPreguntar` usa siempre la opción segura: nunca activa la Protección del sistema por su cuenta y, si el punto de restauración falla (o ya existe uno reciente y Windows omite otro), cancela, salvo que también se pase `-SinPuntoRestauracion`. Las preguntas y la presentación de la consola viven en `Core/Consola.ps1`; la interfaz gráfica usará directamente el motor (`Core/Tweaks.ps1`, `Journal.ps1`, `PuntoRestauracion.ps1`) sin pasar por ese archivo.

---

## Diagnóstico de hardware

Detectar con CIM:

- **CPU**: nombre, núcleos e hilos.
- **RAM**: total instalada, ranuras usadas y libres, velocidad.
- **GPU**: nombre, versión y fecha del driver. Excluir adaptadores virtuales o remotos.
- **Disco del sistema**: tipo HDD/SSD, modelo, espacio libre y salud. Si `MediaType` viene como "Unspecified", inferirlo por bus NVMe, modelo o velocidad de giro.
- **Otros**: si es portátil (batería), tiempo encendido y cantidad de programas de inicio.

Perfil calculado: **Bajo** (≤4 GB de RAM, ≤2 hilos, o HDD con ≤8 GB), **Alto** (≥16 GB, ≥8 hilos y SSD) o **Medio**.

Las GPUs antiguas se identifican con patrones de texto en `Config/legacy-gpu-patterns.txt` (editable). Además se detecta "Microsoft Basic Display Adapter" como "sin driver".

**Implementación del diagnóstico (fase 4):**

- Vive en `Modules/Hardware.ps1` y `Modules/Recomendaciones.ps1`; **solo lee** (no escribe nada en el sistema ni en el journal). `Get-Diagnostico` devuelve UN objeto que la interfaz usa tal cual (con `DuracionMs` y la lista `Consultas`).
- **Tolerante a fallos:** cada consulta va aislada con cronómetro; si falla o se pasa del tiempo queda como Desconocido (`Error` o `TiempoAgotado` en `Consultas`) y el resto sigue. Límite de tiempo con `Get-CimInstance -OperationTimeoutSec` (verificado en Windows PowerShell 5.1: corta una consulta CIM local; `New-CimSession` con timeout NO cortó y no se usa). **Nunca `Win32_Product`.** Se mide y se muestra cuánto tarda el diagnóstico.
- **Detección de VM:** no solo por fabricante ("Microsoft Corporation" también fabrica las Surface): Hyper-V exige fabricante `Microsoft Corporation` **y** modelo exacto `Virtual Machine`; VMware, VirtualBox, QEMU, Parallels, Xen y nubes por fabricante/modelo; la BIOS solo corrobora. `HypervisorPresent` NO sirve (es verdadero en un host con Hyper-V o VBS). En una VM se muestra un Info y se **suprimen** las alertas de GPU, tipo de disco, ranuras de RAM y salud del disco (los valores virtuales no son fiables).
- **Tres listas en `Config/`** (texto que contiene, o `re:expresión`; `#` comentarios): `legacy-gpu-patterns.txt` = "GPU antigua" (nivel 1, la ÚNICA que recomienda desactivar la aceleración por hardware: GMA/Express Chipset, "Intel HD Graphics" sin número y 2000/2500/3000/4000, GeForce 6-9/100-300/400-500, ATI y Radeon HD 2000-6000, S3/SiS/VIA/Matrox); `unsupported-gpu-patterns.txt` = drivers sin soporte activo del fabricante (nivel 2: Haswell/Broadwell, Kepler, Radeon HD 7000/8000 y R5-R9; nivel 3 comentado: Intel 6.ª-10.ª gen), **solo Info**, nunca recomienda desactivar la aceleración (una HD 4600 o una GT 730 aceleran bien el navegador); `virtual-gpu-patterns.txt` = adaptadores virtuales o remotos (se excluyen). Los patrones se prueban contra nombres reales en `Pruebas/Probar-Fase4.ps1`, con casos que sí y que NO deben coincidir.
- **RAM:** capacidad instalada = suma de `Win32_PhysicalMemory.Capacity` (`TotalPhysicalMemory` no es exacta); velocidad = `ConfiguredClockSpeed` (MHz) y, si falta, `Speed` (la documentación dice nanosegundos pero devuelve MHz). Ranuras = `Win32_PhysicalMemoryArray.MemoryDevices` menos los módulos.
- **Disco del sistema:** letra de la unidad del sistema -> `MSFT_Partition.DiskNumber` -> `MSFT_Disk.UniqueId` -> `MSFT_PhysicalDisk` (respaldo: `DeviceId` igual al número de disco; ese vínculo no está documentado, se observó). `MediaType` 3 = HDD, 4 = SSD, 5 = SCM; si es 0 (Unspecified) se infiere por bus NVMe (17), `SpindleSpeed` (0 = SSD, `0xFFFFFFFF` = rotacional de velocidad desconocida, otro valor = HDD) y modelo. Salud: Warning/Unhealthy = Crítico; Unknown = solo Info.
- **GPU principal:** la no virtual con salida activa (`CurrentHorizontalResolution`); se listan todas. Alerta de driver viejo (> 3 años): el texto manda revisar la página oficial del fabricante del equipo o de la GPU o Windows Update (Actualizaciones opcionales) y avisa de que **no se usen programas de "actualizar drivers"**.
- **Administración (`telemetria-servicios-off`):** bloquean la recomendación `PartOfDomain`, `DomainJoined`, `AzureAdJoined` y `EnterpriseJoined` (de `dsregcmd /status`, con límite de tiempo; claves en inglés y valores `YES`/`NO` aunque Windows esté en otro idioma). `WorkplaceJoined` NO bloquea: OptiLow corre elevado (no es fiable) y puede ser un equipo personal con una cuenta del trabajo; solo genera un aviso Info. No se mira la inscripción MDM del registro (falsos positivos). Si no se puede leer `dsregcmd`, por precaución no se recomienda ese tweak y se explica.
- **Umbrales:** más de 10 programas de inicio habilitados, más de 7 días sin reiniciar (`LastBootUpTime` no se actualiza con el inicio rápido), menos del 15 % de espacio libre. El conteo de programas de inicio descuenta los deshabilitados con `StartupApproved` (la asociación Run <-> `Run`/`Run32`/`StartupFolder` se valida en la VM comparando con el Administrador de tareas).
- **Perfil:** Bajo si se cumple CUALQUIERA de RAM ≤ 4 GB, ≤ 2 hilos, o HDD con RAM ≤ 8 GB; Alto si se cumplen TODAS (RAM ≥ 16 GB, ≥ 8 hilos y SSD, todas conocidas); Medio el resto. Un dato desconocido no cuenta para Bajo y hace imposible Alto.

Recomendaciones con niveles Crítico, Aviso, Info y Consejo, por ejemplo:

- GPU sin driver (crítico), GPU antigua, driver de video de más de 3 años.
- 4 GB de RAM, indicando si hay ranuras libres.
- Disco HDD: el cambio a SSD es la mayor mejora posible.
- Poco espacio libre (<15 %), salud del disco distinta de "Healthy" (crítico).
- Muchos programas de inicio, muchos días sin reiniciar (el "Apagar" con inicio rápido no reinicia).
- Consejos manuales que no se automatizan: un solo antivirus, ahorro de memoria del navegador, limpieza de polvo y pasta térmica en equipos viejos, no desactivar el archivo de paginación con 4 GB.

---

## Datos técnicos verificados (no cambiar sin verificar)

### Discord
- Archivo: `%APPDATA%\discord\settings.json`. También existen `discordptb` y `discordcanary`.
- La clave es **`enableHardwareAcceleration`** (no `hardwareAcceleration`), con valor `false`.
- Discord reescribe el archivo al cerrarse: **cerrar el proceso antes de editar**.
- Respaldar el archivo antes de modificarlo y escribir el JSON en UTF-8 **sin BOM**.

### Navegadores Chromium
- Directiva `HardwareAccelerationModeEnabled` (DWORD) con valor `0`, en:
  - `HKLM\SOFTWARE\Policies\Google\Chrome`
  - `HKLM\SOFTWARE\Policies\Microsoft\Edge`
  - `HKLM\SOFTWARE\Policies\BraveSoftware\Brave`
- Aplicar solo a navegadores instalados (detectar por `App Paths` en HKLM y HKCU).
- Efecto secundario: el navegador mostrará "Administrado por tu organización". Indicarlo en la descripción. Requiere reiniciar el navegador.

### Criterio para recomendar desactivar la aceleración por hardware
Solo con GPU antigua o sin driver. **No** recomendarla automáticamente solo por tener poca RAM o CPU débil: en CPUs de 2 núcleos, desactivarla pasa la decodificación de video a la CPU y puede empeorar YouTube.

**Niveles de GPU y por qué (decidido con el usuario):** "GPU antigua" NO significa "sin soporte del fabricante". Una HD 4600 o una GT 730 sin drivers nuevos aceleran bien el navegador y el video, y desactivarles la aceleración en un CPU débil empeora el rendimiento. Por eso: **nivel 1** (`Config/legacy-gpu-patterns.txt`) = "GPU antigua", la ÚNICA lista que recomienda desactivar la aceleración; **nivel 2** (`Config/unsupported-gpu-patterns.txt`) = "drivers sin soporte activo del fabricante", solo Info y nunca recomienda desactivarla; **nivel 3** (comentado en el mismo archivo del nivel 2: Intel 6.ª-10.ª generación) no se muestra salvo que se descomente. Los patrones se prueban en `Pruebas/Probar-Fase4.ps1` con nombres reales de `Win32_VideoController`, incluidos los que NO deben coincidir (GTX 750 Ti, GTX 960, GTX 1660, RTX 3060, RX 580, UHD 620, Iris Xe, Radeon Vega 8, "AMD Radeon(TM) Graphics").

### Efectos visuales
- Transparencias: `EnableTransparency = 0` en `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`.
- "Mejor rendimiento": preferir la configuración personalizada (`VisualFXSetting = 3`) que apaga animaciones y sombras **pero conserva el suavizado de fuentes**. Requiere cerrar sesión.

### Servicios
- Cambiar el tipo de inicio con `sc.exe config` (no `sc`, que en PowerShell es un alias de `Set-Content`) y comprobar el código de salida. No redirigir stderr de programas nativos con `2>&1` en 5.1.
- Leer el estado original desde `HKLM\SYSTEM\CurrentControlSet\Services\<nombre>` (`Start` y `DelayedAutostart`) para poder restaurar incluso el inicio automático retrasado.
- Si `sc.exe` devuelve acceso denegado (servicio protegido), registrar un fallo claro con el nombre del servicio y continuar con lo demás.
- **SysMain**: recomendar desactivarlo solo en HDD; en SSD ayuda.
- **WSearch**: nunca recomendado automáticamente, solo opción manual (riesgo Medio: búsqueda más lenta, Outlook afectado).
- **DiagTrack** y **dmwappushservice**: desactivar. Advertir que no se use en equipos administrados por empresa (Intune/MDM).

### Telemetría
- `AllowTelemetry = 0` en `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection`. Aclarar en la descripción que en Home y Pro el mínimo real es "Datos requeridos".
- Tareas programadas que más cargan un HDD: Microsoft Compatibility Appraiser, ProgramDataUpdater, CEIP Consolidator, UsbCeip, DiskDiagnosticDataCollector. Si una no existe en esa versión de Windows, omitirla sin error.
- Desactivar el ID de publicidad y las sugerencias o apps promocionadas de `ContentDeliveryManager`.

### Apps en segundo plano
`GlobalUserDisabled = 1` en `HKCU\...\BackgroundAccessApplications`. Riesgo Medio: algunas apps de la Store dejan de enviar notificaciones.

### Programas de inicio
- Fuentes: `Run` de HKCU, HKLM y WOW6432Node, y las carpetas de Inicio del usuario y común.
- **No borrar entradas.** Deshabilitarlas mediante `...\Explorer\StartupApproved\Run`, `Run32` y `StartupFolder` (valor binario: primer byte `03` = deshabilitado, `02` = habilitado), igual que el Administrador de tareas. Así es reversible y queda en el journal.

### Plan de energía
"Alto rendimiento" solo recomendado en equipos de escritorio (sin batería). Si el plan no existe (común en portátiles con Modern Standby), avisar y no fallar silenciosamente.

### Bloatware
- Lista editable en `Config/bloatware.txt`, conservadora (noticias, clima, Solitaire, Get Started, Feedback Hub, etc.). Xbox y apps útiles van comentadas.
- Riesgo Alto, **no reversible** desde el journal (se reinstala desde Microsoft Store), nunca recomendado automáticamente.
- Obtener la lista de paquetes aprovisionados una sola vez, no dentro del bucle (es lento en HDD).
- En PowerShell 7 el módulo Appx requiere compatibilidad con Windows PowerShell.

---

## Logging

- Formato: `[HH:mm:ss] [NIVEL] mensaje`, con niveles INFO, OK, WARN, ERROR y DEBUG.
- Archivo diario en `%ProgramData%\OptiLow\logs\`, escrito con bloqueo porque escriben dos hilos.
- En modo interfaz, el log va a una cola compartida; en consola, a pantalla con colores.
- Cada tweak registra qué cambió exactamente (ruta, valor anterior y nuevo).

---

## Pruebas

- **Nunca probar en mi equipo principal.** Usar una máquina virtual con snapshot o Windows Sandbox.
- Cada tweak se prueba en tres pasos: aplicar, comprobar estado y deshacer con el journal. Al final, verificar que el sistema quedó como estaba.
- Probar en Windows PowerShell 5.1 y, si es posible, en Windows 10 y en Windows 11.
- Probar sin Discord instalado y sin Chrome o Brave: el estado debe ser "no aplica", sin errores.
- Comprobar que todo parsea sin errores de sintaxis antes de dar una fase por terminada.
- Scripts de `Pruebas/` (el cargador nunca los carga): `Probar-Fase2.ps1`, `Probar-Fase3.ps1` (VM, administrador, piden confirmar y crean y borran objetos ficticios o aplican de verdad), `Probar-Fase4.ps1` (solo lectura, sin administrador), `Probar-Fase5.ps1` (interfaz: abre la ventana real en el propio proceso con `-STA`, no aplica nada real, redirige `%ProgramData%` a una carpeta temporal y guarda capturas PNG en `%TEMP%\OptiLow-capturas\`; no necesita administrador), `Probar-Core-SinAdmin.ps1` y `Probar-Motor-SinAdmin.ps1` (sin administrador; se niegan a correr elevados) y `Diagnostico-PuntoRestauracion.ps1`. Cada fase se da por cerrada cuando su script pasa en la VM con 0 fallos.

---

## Notas de desarrollo y trampas de PowerShell 5.1 (aprendidas probando)

Flujo: una fase cada vez; plan primero y aprobación antes de escribir código; al terminar, resumen y espera; commit por fase (y por cada corrección tras la VM); se sube a GitHub solo cuando el usuario lo pide. Los datos técnicos dudosos se verifican en Microsoft Learn y se informa del resultado antes de usarlos. Los resultados de la VM se anotan en `docs/ESTADO.md`.

**Codificación:** las herramientas de edición escriben `.ps1` SIN BOM. Después de editar o crear scripts, volver a escribirlos con BOM y comprobar el parseo:

```
$enc = New-Object Text.UTF8Encoding($true)
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object { [IO.File]::WriteAllText($_.FullName, [IO.File]::ReadAllText($_.FullName), $enc) }
```

Trampas encontradas (todas dieron fallos reales):

- `0 -eq ''` es **verdadero**: un 0 es un dato válido (0 días encendido, 0 ranuras libres). Comparar con `$null` y con `$Valor -is [string] -and $Valor.Length -eq 0`.
- Una lista o arreglo **vacío es "falso"** en un `if`: usar `$null -ne $lista`, no `if ($lista)` (la lista de consultas del diagnóstico nunca se llenaba).
- `"$variable:texto"` se interpreta como unidad o ámbito: escribir `${variable}:texto`.
- `[System.IO.File]::Replace(a, b, $null)` falla porque PowerShell pasa una cadena vacía: usar `[NullString]::Value`.
- `ConvertTo-Json` sin `-Depth` usa 2 y aplasta los objetos anidados. Siempre `-Depth 100`.
- `Start-Process -Verb RunAs` pierde el `Win32Exception` (código 1223 = UAC cancelado): usar `[Process]::Start` con `UseShellExecute` y recorrer la cadena de `InnerException` (PowerShell la envuelve en `MethodInvocationException`).
- Programas nativos: no usar `2>&1` en 5.1; para capturar salida y errores por separado, `Process` con `RedirectStandardOutput/Error`, y para comandos que escriben en stderr, `cmd /c "... >nul 2>nul"`.
- `Sort-Object` no es estable en 5.1: ordenar por (clave, índice original).
- Un literal numérico como argumento de comando conserva su texto (`0.0` queda "0.0"): en pruebas, usar `[double]0`.
- `Invoke-WmiMethod -ArgumentList` sigue el orden de parámetros que devuelve WMI (`Description`, `EventType`, `RestorePointType`), no el de la documentación.
- Variables de prueba con el mismo nombre que un contador (`$ok` pisó a `$script:ok`) y parámetros/variables que solo difieren en mayúsculas (`$Ids` y `$ids` son la misma): cuidado.
- Una variable con el mismo nombre que un parámetro tipado hereda su tipo: `$titulo = New-TextoUI ...` dentro de una función con `[string]$Titulo` convierte el TextBlock a texto, y `Children.Add` falla con "No se encuentra ninguna sobrecarga para Add". Nombrarlas distinto (`$tbTitulo`).
- WPF no tiene `Thickness.Parse`: usar `New-EspesorUI` o el constructor. Un ListBox no es tabulable en sí (`IsTabStop` falso: Tab entra en el elemento seleccionado).
- `TextBlock.Text` devuelve cadena vacía cuando el texto está en `Inlines` (Run): en pruebas, leer también `Inlines`. Un valor que viene vacío a un parámetro `Mandatory [string]` falla con "cadena vacía": usar `[AllowEmptyString()]` (así falló el diagnóstico en la VM).
- Un manejador de eventos de WPF escrito como scriptblock debe llamar a funciones globales y llevar su `try/catch` (`Invoke-ManejadorUI`); las variables sueltas del script que lo creó no existen cuando se dispara.
- `Dispatcher.InvokeShutdown()` es definitivo para el hilo: tras cerrar una ventana no se puede abrir otra en el mismo proceso. Las pruebas que necesitan otro arranque lo hacen en un proceso aparte.
- `Win32_PhysicalMemory.Speed` dice nanosegundos en la documentación pero devuelve MHz; usar `ConfiguredClockSpeed`. `TotalPhysicalMemory` no es exacta: sumar `Capacity`. `HypervisorPresent` es verdadero en un host con Hyper-V o VBS.
- `New-CimSession -OperationTimeoutSec` no cortó una consulta lenta; `Get-CimInstance -OperationTimeoutSec` sí (verificado). Para programas nativos, `Process` con `WaitForExit(timeout)` y `Kill`.
- El cargador promueve a global también las funciones **redefinidas** al recargar un archivo (necesario para sustituirlas en pruebas con funciones de prueba).
- Los arneses que sustituyen `Assert-JournalListo` o `Get-Diagnostico` deben restaurar las funciones reales al terminar (`Import-OptiLowArchivo` del archivo original).

---

## No hacer

- No desactivar Windows Defender, Windows Update ni el archivo de paginación.
- No borrar entradas del registro ni archivos del usuario de forma irreversible (salvo el bloatware, con advertencia).
- No descargar ni ejecutar nada de internet.
- No aplicar ningún cambio automáticamente al abrir el programa.
- No usar ajustes "milagro" sin respaldo técnico (limpiadores de RAM, cambios aleatorios de TCP o "registry boosters").