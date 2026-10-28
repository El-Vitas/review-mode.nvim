# Registro de decisiones

Decisiones de arquitectura, diseño, UX y optimización tomadas durante el
desarrollo, con su contexto y porqué. Ordenadas por tema.

## Arquitectura y modelo

### D1 — Nativo en Neovim, sin salir del editor
Traer el flujo de review de tuicr DENTRO de Neovim. La "vista" es solo cómo se
pinta el código (decoraciones), nunca tabs nuevas ni buffers modificados. El
buffer sigue siendo el archivo real y editable.

### D2 — Core + vertical slices
Un `core/` estable (única dependencia) + features independientes que solo
dependen del contrato del core y coordinan por eventos. Permite implementar las
features en paralelo y testearlas solas. Regla dura: una feature nunca requiere
otra feature.

### D3 — Storage en `.git/review.nvim/comments.json`
Por-repo, fuera del código, nunca commiteado. Todo el I/O pasa por `core.store`
(única puerta al filesystem). `state` es la fuente de verdad en memoria y emite
`comments:changed`.

### D4 — Comentarios anclados con extmarks (con `end_row`)
Cada comentario tiene un extmark ancla que sigue la línea al editar; el rango se
preserva con `end_row`. En `BufWritePost` se re-sincronizan posiciones. `lnum`
se recalcula desde el extmark; `_extmark_id` es runtime y no se persiste.

### D5 — Comparar contra HEAD (último commit)
Las vistas comparan `buffer actual (en memoria) vs HEAD`. Muestra todo lo no
commiteado (staged + unstaged + sin guardar). Decisión explícita del usuario
sobre "índice" o "rama base". Nota: no coincide con gitsigns, que compara contra
el índice.

## Vistas

### D6 — Sin diffview (feo), diff nativo de Neovim para el split
El usuario rechazó el plugin diffview. El split usa el **modo diff nativo**
(`:diffthis`), que alinea con relleno, resalta y sincroniza scroll/mouse por
hunks, y se re-diffea solo en vivo.

### D7 — Alineación estilo VSCode: `linematch` + `histogram` + `inline:char`
Sin `linematch`, el diff apila el bloque borrado y el agregado sin alinear las
líneas comunes ("todo cambiado" visual). Forzamos en `diffopt` (preservando las
flags del usuario): `linematch`, `algorithm:histogram`, `indent-heuristic`,
`inline:char` (para resaltar el texto exacto que cambió). `filler` para el
relleno.

### D8 — Peek como VIRTUAL LINES, no flotante
Iteración larga: un floating window SIEMPRE flota y "sigue" al usuario. Se
cambió a **virtual lines insertadas debajo del bloque** (estilo GitHub inline):
es parte del flujo del código, ocupa espacio, se mueve con el scroll y no sigue
al cursor. `<leader>rp` es toggle por comentario; varios a la vez.

### D9 — Modo de vista GLOBAL y permanente
El modo (normal/inline/split) es global (aplica a todos los archivos, estilo
VSCode) y sigue al archivo activo. Review es un modo **permanente**: las 3
vistas son sus modos, no hay "salir de review". Se eliminó el flag `active`.

### D10 — Panel HEAD con `winfixbuf`
En el split, el panel HEAD (izquierda) es un scratch readonly con `winfixbuf`
para que NO se le puedan abrir archivos. Bug original: al cambiar de archivo se
"secuestraba" la columna con foco. Ahora los archivos siempre se abren en la
columna de edición y el HEAD sigue al archivo.

### D11 — Nunca compactar líneas: folds abiertos en el repo
El diff nativo pliega las líneas sin cambios ("+-- N lines"), y el plugin de
folds del usuario también. En archivos del repo se fuerza `foldenable=false` +
`foldlevel=99` en las 3 vistas. Es plugin-agnóstico (opciones nativas), no toca
el plugin de folds. Fuera del repo no se toca nada.

## Comentarios: visual y UX

### D12 — Distinguir comentarios: color de fondo alternado + corchete por color
El fondo solo no distinguía comentarios pegados. Se alterna el tono
(`ReviewCommentLine`/`Line2`) y el corchete del gutter usa una paleta cíclica de
6 colores (uno por comentario).

### D13 — Gutter con corchetes anidados vía `statuscolumn`
La columna de signos solo admite 1 signo/línea → no sirve para anidamiento. Se
reemplaza el `statuscolumn` de las ventanas del repo para dibujar un corchete
por CADA comentario que cubre la línea, apilados por profundidad. Preserva
signos (gitsigns) y número. Solo en `buftype==""` del repo; nunca toca buffers
especiales (neo-tree/terminal) para no romperlos (bug del `<leader>e`).

### D14 — Popup multi-línea: enviar con Enter (sin Ctrl)
El popup arranca en insert, Enter hace saltos de línea; se envía con **Enter en
modo normal**, se cancela con `q`. Antes `<Esc>` cancelaba (borraba lo escrito);
se sacó. El usuario pidió explícitamente Enter y evitar `<C-...>`.

### D15 — Lista con acciones y filtro
La quickfix de `:Rl/:Rlf` permite `Enter` (ir y cerrar), `d` (borrar), `x`
(resolver), `f` (filtrar todos/abiertos/resueltos), `q` (cerrar), con winbar de
atajos.

### D16 — Colores de diff: solo fondo, distinguir modificado de texto exacto
Sin fg ni bold (saturaba). Línea modificada = amarillo suave (`DiffChange`);
texto exacto que cambió = rojo (izq, quitado) / verde (der, agregado) vía
`DiffText`; línea borrada/agregada entera = roja/verde. Colores por columna con
`winhighlight`.

## Bugs importantes y sus causas

### B1 — Raíz del repo por cwd (no por archivo)
`git rev-parse` usaba el cwd de Neovim, no el directorio del archivo → "buffer
fuera del repo" al abrir archivos cuyo repo no era el cwd. Fix: `git.root(bufnr)`
resuelve desde el directorio del archivo, con fallback a cwd.

### B2 — CRLF: "todo cambiado"
`git show HEAD:archivo` devuelve `\r` en archivos CRLF, pero Neovim lo quita en
`fileformat=dos` → cada línea difería por el `\r` → todo marcado como cambio.
Fix: `head_content` normaliza CRLF (quita `\r` final).

### B3 — Diff desalineado al cambiar de archivo
Al reusar el buffer HEAD y re-diffear tras cambiar de archivo, quedaba estado de
diff residual en el tab → el diff emparejaba mal (líneas idénticas como cambio).
Fix: `diffoff!` limpia el tab antes de rearmar, y siempre se usa un scratch
fresco. Además, no se re-diffea en reuso del mismo archivo.

### B4 — `E855` al cerrar buffer con split abierto
Cerrar una ventana dentro del autocmd `WinClosed` aborta el comando. Fix:
diferir el cierre con `vim.schedule`.

### B5 — Fugas de cache por buffers cerrados
Los caches por `bufnr` crecían con cada archivo abierto. Fix: liberarlos en
`BufDelete/BufWipeout` (y `_prev` en `WinClosed`).

### B6 — Scroll del split
Iteración: `scrollbind` no propagaba la rueda del mouse; el sync manual por
`WinScrolled` daba tirones/rebotes. El diff nativo (D6) resolvió el scroll
nativamente y se descartó el sync manual.

## Otras decisiones

### D17 — Sidebar reusa neo-tree, no lo reimplementa
`changed` = `git_status`, `all` = `filesystem`. `<leader>rs` togglea. Abre con
las carpetas cerradas (`close_all_nodes`). Expandir/cerrar/revelar se hacen con
neo-tree nativo (`z`/`Z`, `:Neotree reveal`); review no los envuelve para no
crecer de más.

### D18 — Export agrupado por archivo
Markdown agent-ready: `## <path>` por grupo, ordenado por archivo+línea,
numeración continua, ancla `path:lnum`, excluye resueltos.

### D19 — Textos de usuario en inglés
Todo lo visible al usuario (notificaciones, hints, winbar, títulos) en inglés, y
las instrucciones dicen "Enter" (no "CR"). Los comentarios del código quedan en
español.

### D20 — Alias en minúscula centralizados
`plugin/review.lua` define `cnoreabbrev` (rcm, rl, rv, rs, …) en un solo lugar,
no en cada feature. Los comandos capitalizados y sus alias `:Rx` son comandos
reales; las minúsculas son abbrevs.

### D21 — agent RPC (implementado)
La feature `agent` (puente RPC nativo) quedó implementada según `roadmap.md` §1 /
`plans/05-agent.md`. Sigue **deshabilitada por defecto** (`features.agent.enabled`)
por exponer superficie de escritura remota.

### D22 — Reconciliación AUTO por patch mínimo por diff
El código lo escribe el agente en disco (fuera de nvim); solo los comentarios
pasan por nvim. Para que Neovim se entere de los cambios en disco y re-ancle los
comentarios, se eligió **AUTO** (no `:edit!` manual como tuicr): un watcher
`vim.uv.fs_event` con debounce detecta el cambio y aplica un **patch mínimo**
(`vim.diff` result_type=indices → `nvim_buf_set_lines` de abajo hacia arriba). Así
los extmarks se re-anclan solos por gravity, sin remapeo manual. Nunca se pisan
cambios sin guardar (`modified` → `conflict`, con `:ReviewReload` como fallback).
Malla de seguridad: `anchor_text` marca `stale` si la línea anclada dejó de
coincidir. Coordinación con `comments` por el evento `buffer:reconciled` (regla de
no-dependencia entre features intacta).

### D23 — Re-render de comentarios en `comments:changed`
`comments` se suscribe a `comments:changed` para re-renderizar los buffers del
repo abiertos (antes solo lo hacía en `BufEnter`), así los comentarios que agrega
el agente por RPC aparecen en vivo. Antes de repintar hace `sync_positions` para
no reubicar extmarks en su `lnum` viejo y perder el desplazamiento por gravity.

### D24 — Cerrar a mano una columna del split pasa a la vista normal
Decisión del usuario (2026-10-28). Cerrar a mano cualquiera de las dos columnas
del split (la HEAD, la de edición, la pestaña que las contiene o la ventana de
código que tenía el par) se toma como "no quiero split": se cierra la otra
columna y la vista global pasa a `normal`. Antes el par reaparecía en el
siguiente `BufEnter` (cambiar de foco o de archivo), o sea que la acción del
usuario se deshacía sola. Los cierres que hace el propio plugin (`teardown` al
cambiar de vista o de archivo) no cuentan: sueltan la sesión antes de cerrar la
ventana, así que `on_win_closed` no la reconoce. Verificado por
`tests/e2e/split_windows.lua` (W10-W16).

### D25 — El peek es una tarjeta flotante (reemplaza a D8)
D8 describía el peek como virtual lines; el código lo volvió a hacer flotante y
centrado (`comments/mode.lua`, `open_peek_float`), y así lo documenta
`commands.md`. Una sola tarjeta a la vez; `x`, `d` y `e` actúan sobre el
comentario que muestra, por id.

### D26 — Los caches de git se invalidan al volver el foco
`git commit`, `git mv`, `git add` o un `checkout` hechos fuera de Neovim cambian
el HEAD o los renames sin tocar los archivos abiertos, y los caches (raíz por
directorio, mapa de renames, HEAD de inline y scrollbar) quedaban viejos: la
vista seguía marcando como cambio lo ya commiteado. En `FocusGained` se vacían
y se reaplica la vista. Costo: un `git show` por buffer visible al volver. El
mapa de renames dejó de vaciarse en B22: se recalcula solo si git cambió.

## Revisión de calidad (2026-10-28)

Bugs encontrados por `lua-language-server`, `jscpd` y una revisión por ejes
(seguridad, integridad, rendimiento, duplicación, prácticas), corregidos con test.

### B7 — comments.json no atómico y corrupto tratado como vacío
`io.open(p, "w")` trunca antes de escribir: un corte a mitad dejaba el archivo
vacío, `load()` lo tomaba por "sin comentarios" y el siguiente `persist()` lo
pisaba. Fix: `write_json` escribe a `.tmp` y hace `fs_rename` (atómico),
comprobando `write`/`close`; un JSON ilegible se aparta como
`comments.json.corrupt-<fecha>` con aviso. Tests: `tests/core/store_spec.lua`.

### B8 — Los comentarios se guardaban en el repo del cwd del momento
`store.path()` resolvía el cwd en cada guardado: tras `:cd` a otro repo, la lista
del repo A se escribía en el B. Con nvim abierto fuera de un repo, `persist()`
fallaba en silencio. Fix: `state` fija la raíz al cargar y guarda ahí;
`DirChanged` guarda el repo anterior y carga el nuevo (`state.switch_root`); un
guardado que falla avisa una vez. Tests: `tests/core/state_spec.lua`.

### B9 — Dos `git diff -M` por cada archivo nuevo
`rename_source` lanzaba dos diffs completos por archivo (120-150 ms en FastCase
con base `HEAD~20`) y se quedaba solo con la entrada de ese archivo. Fix: un
mapa destino→origen por repo y base, calculado una vez. Tests:
`tests/core/git_spec.lua`.

### B10 — La API RPC del agente no validaba la entrada
Un `lnum` texto, tabla o `null` se guardaba y rompía el render (y el gutter, que
Neovim reseteaba con E5108) en cada arranque; `context()` leía archivos fuera del
repo con `../` y recorría rangos sin tope (2e7 líneas = 741 ms y 60 MB); el
cliente podía fijar `id`, `resolved` o firmar como `user`. Fix: validación en el
borde (tipos, rangos, rutas relativas sin `..`, texto ≤ 64 KB, autor ≠ `user`),
lista blanca de campos, `realpath` confinado al repo y tope de 500 líneas;
`buf_for_path` compara por `rel_path` (symlinks y raíz por archivo, como B1).
Tests: `tests/agent/rpc_spec.lua`.

### B11 — Acciones por cursor con comentarios solapados, y peek de archivo
`find_at` devolvía el primer comentario por orden de inserción y el peek el más
específico: la `e` del peek editaba otro comentario. El peek de un comentario de
archivo fallaba concatenando `lnum = nil`. Fix: un solo criterio (el más
específico), edición por id desde popup y peek, título "file". Tests:
`tests/comments/mode_spec.lua`.

### B12 — `cnoreabbrev` expandía en cualquier posición
`:%s/rl/x/g` pasaba a `:%s/Rl/x/g` y `:g/rt/d` borraba las líneas con "Rt". Fix:
abreviatura `<expr>` que solo expande cuando la línea de comandos es el alias.

### B13 — Opciones de ventana del split filtradas al global
`vim.wo[win].x = v` sin `[0]` cambia también el valor global: las ventanas
nuevas nacían con los folds y el resaltado del split, contra D11. Además
`restore_main` restauraba `foldenable=false` como `true` (`false or true`). Fix:
`vim.wo[win][0]` y restauración explícita. Tests:
`tests/e2e/split_windows.lua` (W7).

### B14 — Watcher del agente muerto, conflicto silencioso, latin1 corrupto
Si el archivo desaparecía más de 150 ms (checkout), el `fs_event` no se
re-armaba y quedaba registrado, así que nunca se reparaba. Un conflicto (cambios
sin guardar) se descartaba sin aviso. `readfile()` en un archivo latin1 metía
bytes inválidos al buffer. Fix: reintentos al re-armar y `detach` si no vuelve;
aviso de conflicto una vez por buffer; los archivos no UTF-8 no se reconcilian.
Tests: `tests/agent/watch_spec.lua`.

### B16 — El export mezclaba respuestas con pendientes y cambiaba de orden
Las respuestas del agente salían como ítems numerados, así que al pegar `:Rya` el
agente recibía sus propias respuestas como tareas; `table.sort` no es estable y
varios comentarios en la misma línea cambiaban de número entre exportaciones.
Fix: las respuestas van sangradas bajo su comentario (`↳ autor: texto`) y el
orden desempata por creación. Tests: `tests/export/markdown_spec.lua`.

### B17 — comments.json se reescribía al abrir o guardar cualquier archivo
`BufReadPost` y `BufWritePost` llamaban a `persist()` siempre, aunque el archivo
no tuviera comentarios. Fix: solo si el buffer tiene comentarios.

### B18 — Un comentario nuevo caía en la línea vieja si el archivo cambiaba
El popup capturaba `lnum` al abrirse; si el agente insertaba líneas mientras se
escribía, el comentario se anclaba al número viejo. Fix: el rango se ancla con
extmarks temporales mientras el popup está abierto. Tests:
`tests/comments/mode_spec.lua`.

### B19 — Neovim se caía (SIGSEGV) al cerrar una columna del split con markdown
Reportado por el usuario el 2026-10-28: en split, cambiar de archivo cerró
Neovim. Core dump: `f_win_findbuf` ← autocmd `DiffUpdated` ← `ex_diffupdate` ←
`diff_check_with_linestatus` ← `win_close`. Mecanismo: `diff_check` corre
`ex_diffupdate()` si el diff de la pestaña está invalidado, antes de mirar si
la ventana está en modo diff; al cerrar una ventana (la HEAD del plugin, o
cualquier ventana diff con `:q`), Neovim redimensiona la vecina, recalcula el
diff y dispara `DiffUpdated` con la lista de ventanas a medio cambiar. El
callback de render-markdown (adjunto al buffer markdown) llama a `win_findbuf`
ahí y Neovim lee memoria inválida. Es un bug de Neovim: reproducido en 0.12.1 y
0.12.6, y con el código de review-mode y de render-markdown anteriores a la
revisión de calidad; sin el autocmd de render-markdown no se cae.
Fix de nuestro lado, en dos lugares:
- `close_head_win`: antes de cerrar la columna HEAD apaga su diff, recalcula con
  `:diffupdate` en un momento seguro y cierra con `DiffUpdated` en
  `eventignore` solo durante el cierre.
- `guard_diff_close`: en `WinClosed` (corre antes de sacar la ventana del
  layout) de cualquier ventana en modo diff, ignora `DiffUpdated` hasta el
  próximo tick. Cubre el `:q` del usuario, que no pasa por el plugin.
Tests: `tests/e2e/split_markdown.lua` (cambiar de archivo en ambos sentidos,
cambiar de vista desde cada columna, cerrar cada columna, cerrar la pestaña;
y que `eventignore` quede limpio).

### B20 — Un archivo volvía en modo diff después de salir del split
Reportado el 2026-10-28: tras salir del split, `<leader>rn/ri/rv` "no cambiaban
la vista". `'diff'` y las opciones de ventana se guardan por buffer en cada
ventana. Si el par se desarmaba porque la ventana pasó a mostrar otro archivo,
el `diffoff` apagaba el diff del archivo NUEVO; el del archivo del par quedaba
guardado y volvía encendido (con el resaltado verde del split) cuando ese
archivo regresaba a la ventana, así que en normal o inline seguía viéndose como
diff. Estaba también en el código previo a la revisión de calidad; antes no se
llegaba a ver porque Neovim se caía en ese mismo cambio de archivo (B19).
Fix: al desarmar el par, si la ventana ya muestra otro archivo, se anota
`[ventana][buffer del par]`; cuando ese buffer vuelve a esa ventana,
`clear_stale` apaga su diff y restaura folds y resaltado. Solo se tocan diffs
que puso el split: un `:diffthis` del usuario no se apaga. Tests:
`tests/e2e/split_windows.lua` (W18-W20).

### B21 — Un archivo nuevo respecto de la base no se marcaba
Reportado el 2026-10-28 en FastCase con la base `efe1a41`: un archivo creado
después de la base (ya commiteado) no cambiaba con ninguna vista y el árbol de
archivos no le ponía letra. gitsigns lo pintaba entero en verde y la statusline
lo contaba, así que cada superficie decía algo distinto.
- `head_content` devuelve nil si el archivo no está en la base, e inline y la
  barra de desplazamiento lo tomaban como "nada que comparar". Ahora usan
  `git.base_lines`, que para un archivo nuevo devuelve `{}`: inline lo pinta
  entero como agregado. Los archivos ignorados por git siguen sin marcarse.
- Split no cambia: con un archivo nuevo sigue en una columna, porque una columna
  de base vacía no aporta nada (regla BR-c517e19).
- El árbol de archivos (`filesystem`) consultaba `git status` plano, y en la
  base el archivo ya estaba commiteado. `neotree_exec` ahora pasa `git_base` a
  los dos modos del árbol y `base:changed` re-aplica la base al que está a la
  vista. El archivo muestra `N`. `<leader>e` midió 13-68 ms (antes 7-53 ms, con
  el mismo ruido de la primera apertura).
Tests: `tests/core/git_spec.lua` y `tests/views/inline_spec.lua`.

### B22 — Abrir un archivo nuevo respecto de la base trababa hasta 700 ms
Reportado el 2026-10-28 ("a veces demora mucho al cambiar de archivo").
`rename_source` necesita el mapa de renombrados de la base, y armarlo cuesta dos
`git diff -M` de ~115 ms cada uno en FastCase contra `efe1a41`. Se corrían de
forma sincrónica la primera vez que se abría un archivo que no existe en la base,
y `FocusGained` tiraba el mapa, así que al volver del navegador se pagaban otra
vez: 272–708 ms.
- El mapa ya no se tira al volver el foco. Lleva una huella (`repo_stamp`): mtime
  y tamaño del index, de HEAD y del reflog de HEAD, leídos con `fs_stat` sin
  lanzar procesos. Un `git mv`, un commit, un checkout o un reset hechos afuera
  la cambian, y el mapa se recalcula. Editar archivos no la cambia, ni hace falta,
  porque un rename sin `git add` no es rename para git.
- `prefetch_renames` lanza los diffs en segundo plano (`vim.system` con callback)
  después de restaurar la base en el arranque, al cambiar de base y al volver el
  foco si la huella cambió. `rename_source` usa el mapa si está listo; si el
  cálculo está en curso, espera a esos mismos procesos en vez de lanzar otros.
- Resultado: abrir `pagination.constants.ts` por primera vez pasó de 319–493 ms
  a 12–25 ms, y al volver del navegador de hasta 708 ms a 8–10 ms.
Tests: `tests/core/git_spec.lua` (huella, foco sin cambios, `git mv` y commit
hechos afuera, cálculo reusado).

### D27 — Vista inline con debounce en insert
`inline.render` recalcula el diff de todo el buffer: 40 ms por tecla con 10 000
líneas muy cambiadas. En `TextChangedI` se agrupa con un solo temporizador de
80 ms; en `TextChanged` (fuera de insert) sigue siendo inmediato.

### B15 — Borrado al final del archivo pintado encima de la última línea
La vista inline anclaba las líneas borradas encima de `new_start`, recortado a la
última línea: "d" borrada del final aparecía antes de "c". Fix: debajo de la
última línea. Tests: `tests/views/inline_spec.lua`.
