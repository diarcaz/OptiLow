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
├── Iniciar.cmd        Lanzador de doble clic (Windows PowerShell 5.1, ExecutionPolicy Bypass)
├── CLAUDE.md          Instrucciones del proyecto
├── Core/              Utilidades sin interfaz (no tocan WPF)
├── Modules/           Diagnóstico de hardware, programas de inicio
├── Tweaks/            Un archivo por categoría de optimización
├── Config/            Listas editables sin tocar código
├── UI/                MainWindow.xaml y su lógica
├── Pruebas/           Scripts de autopruebas para VM (el cargador nunca los carga)
└── docs/              Arquitectura, ideas
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
| Recomendar | No | Recibe el objeto de hardware y decide si se preselecciona |

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
  - **Método:** en Windows PowerShell 5.1 usar `Checkpoint-Computer -RestorePointType MODIFY_SETTINGS`; la clase CIM `SystemRestore` (`CreateRestorePoint`) queda solo como respaldo para PowerShell 7, donde `Checkpoint-Computer` no existe. **Motivo (probado en una VM con Windows 11 24H2):** con `SystemRestorePointCreationFrequency = 0`, `CreateRestorePoint` por CIM terminó en menos de un segundo sin crear el punto (había uno de las últimas 24 h), mientras que `Checkpoint-Computer` con el mismo ajuste sí lo creó. La causa exacta no está determinada; `Pruebas/Diagnostico-PuntoRestauracion.ps1` sirve para investigarla. Del método CIM se registra siempre el `ReturnValue`; nunca se asume S_OK.
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

### Modo consola

`OptiLow.ps1` acepta parámetros para usarse sin interfaz: listar tweaks y su estado, mostrar diagnóstico, aplicar una lista de IDs (o "recomendados"), y omitir el punto de restauración. Sirve para pruebas y automatización.

Parámetros actuales: `-Listar`, `-ListarSesiones`, `-Aplicar <ids separados por comas>` (hasta la fase 4 solo acepta Ids; "recomendados" necesita el diagnóstico de hardware), `-Deshacer` (por defecto la última sesión no restaurada; con `-Sesion <Id>` otra), `-SinPuntoRestauracion`, `-SinPreguntar`, `-SinElevar`. Códigos de salida: 0 bien, 1 fallos o error, 2 cancelado.

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

---

## No hacer

- No desactivar Windows Defender, Windows Update ni el archivo de paginación.
- No borrar entradas del registro ni archivos del usuario de forma irreversible (salvo el bloatware, con advertencia).
- No descargar ni ejecutar nada de internet.
- No aplicar ningún cambio automáticamente al abrir el programa.
- No usar ajustes "milagro" sin respaldo técnico (limpiadores de RAM, cambios aleatorios de TCP o "registry boosters").