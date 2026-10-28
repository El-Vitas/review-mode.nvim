# Rendimiento y RAM

review corre lógica en eventos muy frecuentes (`BufEnter`, `TextChanged`,
render). Estas son las optimizaciones para que sea rápido y liviano, y cómo se
evitan las fugas de memoria.

## Caches

| Cache | Dónde | Clave | Se libera |
|---|---|---|---|
| Raíz del repo | `core/git.lua` `root_cache` | directorio | `FocusGained` (`git.clear_cache`) |
| Renames vs base | `core/git.lua` `rename_maps` | repo + base (+ huella `repo_stamp`) | `set_base`; se recalcula en segundo plano si cambia la huella (B22) |
| Raíz por cwd | `core/store.lua` `_root_by_cwd` | cwd | `DirChanged` (`clear_root_cache`) |
| HEAD (inline) | `views/inline.lua` `_head_cache` | bufnr | `BufReadPost`, `BufDelete`, `BufWipeout`, `FocusGained` |
| HEAD y hunks (scrollbar) | `views/scrollbar.lua` `_head`, `_hunks` | bufnr (+ changedtick) | `BufReadPost`, `BufDelete/Wipeout`, `base:changed`, `FocusGained` |
| HEAD (split) | sesión `split._session.head` | por sesión | al cerrar/cambiar de archivo |
| Ranking/color gutter | `comments/gutter.lua` `_cache` | bufnr | `comments:changed` (reset total), `BufDelete/Wipeout` |
| statuscolumn previo | `comments/gutter.lua` `_prev` | winid | `WinClosed` |

`FocusGained` vacía la raíz y los HEAD porque un commit, `git mv` o `checkout`
hechos fuera de Neovim los dejan viejos sin tocar los archivos abiertos
(decisions.md D26). El mapa de renames no se vacía: cuesta dos `git diff -M` de
~115 ms en un repo grande, así que solo se recalcula, en segundo plano, si cambió
la huella del index, de HEAD o del reflog (B22).

**Verificado:** abrir y cerrar 40 archivos deja **1 entrada** en cada cache (no
40), y 1 solo buffer HEAD vivo (el scratch usa `bufhidden=wipe`).

## Optimización clave: cache de la raíz del repo

`git rev-parse` es un subproceso, y `rel_path()`/`root()` se llaman en cada
render/BufEnter/sync. Cachear la raíz por directorio bajó el sync de reuso del
split de **3.26 ms a 0.020 ms (≈163×)**. Beneficia a TODAS las features (todas
resuelven `rel_path`).

## Split: no re-diffear en reuso

El diff nativo de Neovim se **actualiza solo en vivo** al editar. Nuestro código
NO re-diffea en el mismo archivo:

- En reuso del mismo archivo solo se chequea (vía `changedtick`, sin leer el
  buffer si no cambió) si volvió a quedar idéntico a HEAD (→ una columna). Sin
  git, sin re-diff.
- El split re-sincroniza solo en `TextChanged` (al terminar un cambio), no por
  cada tecla en insert (el diff nativo ya es live ahí).
- Al **cambiar de archivo** se rearma con `diffoff!` + scratch fresco (reusar el
  scratch dejaba estado de diff residual y desalineaba — ver decisions.md).

## Inline: HEAD cacheado por buffer

`inline.render` corre en cada `TextChanged/TextChangedI`. Antes hacía `git show`
por tecla; ahora cachea el contenido HEAD por buffer (el HEAD no cambia mientras
editás), invalidado al recargar/cerrar el buffer.

## Sin fugas de recursos

- Scratch del split: `bufhidden = wipe` → se destruye al cerrar la ventana.
- Autocmds `BufDelete/BufWipeout/WinClosed` liberan las entradas de cache por
  buffer/ventana.
- Cierre de ventanas desde autocmds (`WinClosed`) se **difiere** con
  `vim.schedule` para no disparar `E855` (no se pueden cerrar ventanas dentro de
  `WinClosed`).

## Edge-cases verificados sin error

Archivo fuera del repo, archivo nuevo sin HEAD, buffer especial (neo-tree/nofile),
archivo grande (pnpm-lock.yaml), 20 cambios de modo seguidos, 30 archivos en
inline, cerrar el buffer con el split abierto, ida y vuelta entre archivos.