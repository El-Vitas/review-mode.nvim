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

### D21 — agent RPC pendiente
La feature `agent` (puente RPC nativo) tiene plan escrito pero NO se implementó
por decisión del usuario (no prioritario; expone superficie de escritura remota,
iría deshabilitada por defecto).
</content>
