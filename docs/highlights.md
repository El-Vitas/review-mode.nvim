# Colores (highlight groups)

Todos los grupos se definen con `default = true`, así que **puedes
sobreescribirlos** en tu config (después de cargar el plugin, o en un autocmd
`ColorScheme`). Los tonos por defecto están pensados para temas oscuros
(catppuccin macchiato). El plugin los re-aplica en `ColorScheme`.

## Comentarios (columna de signos, fondo de rango, badge)

| Grupo | Uso | Default |
|---|---|---|
| `ReviewCommentLine` | fondo del rango (comentario par) | `bg #2c3a52` (azul) |
| `ReviewCommentLine2` | fondo del rango (comentario impar, alterna) | `bg #26436b` |
| `ReviewCommentLineResolved` | fondo de rango resuelto | `bg #2a2b38` |
| `ReviewCommentAgent` | fondo del rango (comentario del agente) | `bg #3a2c52` (violeta) |
| `ReviewCommentStale` | fondo del rango (anclaje incierto, ⚠) | `bg #4a3a1d` (ámbar) |
| `ReviewCommentSign1..6` | corchete del gutter (color cíclico por comentario) | blue/green/mauve/peach/teal/yellow |
| `ReviewCommentSignAgent` | corchete del gutter para comentario del agente | `fg #c6a0f6` (violeta) |
| `ReviewCommentSignResolved` | corchete de resuelto | `fg #6e738d` |
| `ReviewCommentBadge` / `…Edge` | chip al final de línea + su borde | `bg #3b4b71` |
| `ReviewCommentBadgeAgent` / `…EdgeAgent` | chip del agente + su borde | `bg #3a2c52` (violeta) |
| `ReviewCommentBadgeResolved` / `…EdgeResolved` | chip resuelto | `bg #33343f` |

**Autoría / hilos / stale:** los comentarios del agente (`author ~= "user"`) se pintan con fondo
violeta e ícono 🤖; los que tienen respuestas muestran un sufijo `↩N` en el badge; los marcados
`stale` (la línea anclada cambió en disco) se pintan ámbar con ⚠. El peek (`<leader>rp`) muestra el
hilo completo: el comentario padre y, sangradas debajo, las respuestas con su autor.

## Peek inline

| Grupo | Uso | Default |
|---|---|---|
| `ReviewPeekNormal` | fondo del bloque del peek | `bg #1e2030` |
| `ReviewPeekBorder` | barra izquierda del peek | `fg #8aadf4` |
| `ReviewPeekHeader` | encabezado (estado · rango · autor) | `bg #2c3a52 fg #8aadf4` |
| `ReviewPeekSep` | separador | `fg #5b6078` |

## Split (diff) — colores por columna

El diff nativo pinta ambos lados con los mismos grupos; los remapeamos **por
ventana** con `winhighlight` para que la columna HEAD (izq) sea roja y la del
archivo (der) verde. Distingue **línea modificada** (fondo amarillo suave) del
**texto exacto que cambió** (rojo/verde fuerte). **Solo fondo** (sin fg/bold).

| Grupo | Uso | Default |
|---|---|---|
| `ReviewDiffChange` | línea modificada (ambas columnas) | `bg #44401d` (amarillo) |
| `ReviewDiffDelLine` | línea borrada entera (izq) | `bg #37202a` (rojo oscuro) |
| `ReviewDiffDelText` | texto quitado dentro de la línea (izq) | `bg #54232f` (rojo) |
| `ReviewDiffAddLine` | línea agregada entera (der) | `bg #21331f` (verde oscuro) |
| `ReviewDiffAddText` | texto agregado dentro de la línea (der) | `bg #2c4a30` (verde) |
| `ReviewDiffFiller` | relleno de alineación | `bg #2a2b38` |

## Ejemplos de override

```lua
-- Comentarios en otro tono
vim.api.nvim_set_hl(0, "ReviewCommentLine",  { bg = "#2e3440" })
vim.api.nvim_set_hl(0, "ReviewCommentLine2", { bg = "#3b4252" })

-- Diff: línea modificada azulada en vez de amarilla
vim.api.nvim_set_hl(0, "ReviewDiffChange", { bg = "#2b3350" })

-- Rojos/verdes del split
vim.api.nvim_set_hl(0, "ReviewDiffDelText", { bg = "#54232f" })
vim.api.nvim_set_hl(0, "ReviewDiffAddText", { bg = "#2c4a30" })
```