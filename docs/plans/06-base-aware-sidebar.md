# Base-aware sidebar — keep neo-tree design, reflect the review base

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development o executing-plans. Steps con checkbox.
> **Contexto:** `docs/commands.md` (sección Base), `features/base/init.lua` (selector + evento `base:changed`), `features/sidebar/init.lua` (abre neo-tree). Regla dura: features coordinan por eventos del core, nunca `require` de otra feature.

**Goal:** que `<leader>s` (sidebar "changed" de review) muestre los archivos cambiados **respecto de la base seleccionada** con `:ReviewBase` (`core.git.base_ref`: `HEAD`, `:` index, o un commit), **manteniendo IDÉNTICO** el diseño/UX actual de neo-tree (árbol, íconos, guías de indentación, expanders `z`/`Z`, columna de git status, marcador `●` de archivos abiertos, fondo morado del archivo actual, highlights). Al cambiar la base (`base:changed`), el sidebar se refresca solo.

**Architecture:** neo-tree ya sabe renderizar el árbol de git status; lo único que le falta es **con qué base** comparar. Su API `require("neo-tree.git").status(path, base_lookup, …)` y `.status_async(path, base_lookup, opts)` aceptan un `base_lookup` = `table<worktree_root, ref>`, pero los sources de neo-tree lo llaman con `nil` (ver `sources/filesystem/lib/fs_scan.lua:58-62` y el source `git_status`). La estrategia preferida (Route 1) es **inyectar** ese `base_lookup` con la base de review, sin tocar el diseño. Route 2 (fallback) es un source propio si el render vs-base no funciona.

**Tech Stack:** Lua, Neovim 0.12, neo-tree v3.x (en `~/.local/share/nvim/lazy/neo-tree.nvim`), review-mode.

## Global Constraints
- **NO cambiar el diseño**: renderers, `opened_marker` (●), fondo morado del archivo actual (`after_render` + `NeoTreeCurrentFileBg`), highlights (onedarkpro), hijack netrw, toggle changed/all — todo queda igual. Están en `~/.config/nvim/lua/plugins/neotree.lua` y `~/.config/nvim/lua/plugins/onedarkpro.lua`.
- **No romper el default** (base = `HEAD`): con base HEAD/index el sidebar debe verse y comportarse EXACTALMENTE como hoy.
- review-mode: la lógica base-aware vive en `features/sidebar` (que ya abre neo-tree) o en un módulo nuevo de review; coordina por `core.events` (`base:changed`). Nunca `require` de otra feature.
- Textos de usuario en inglés. Commits solo El-Vitas, sin trailers. Tras cada cambio correr los tests (`nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`, deben quedar verdes — hoy 105).

## Archivos a leer primero (estado actual)
- `lua/review/core/git.lua` — `base_ref`, `set_base`, `head_content`, `changed_files` (YA base-aware).
- `lua/review/features/base/init.lua` — modal selector; emite `core.events.emit("base:changed", {ref})`.
- `lua/review/features/sidebar/init.lua` — `open_sidebar(kind)`: changed → neo-tree source `git_status`; all → `filesystem`; `<leader>s` togglea.
- `lua/review/features/views/init.lua` + `views/scrollbar.lua` — ya reaccionan a `base:changed` (modelo a imitar).
- `~/.config/nvim/lua/plugins/neotree.lua` — el DISEÑO (renderers, `opened_marker`, `after_render` fondo morado, hijack, refresh autocmds).
- neo-tree internals:
  - `~/.local/share/nvim/lazy/neo-tree.nvim/lua/neo-tree/git/init.lua` — `M.status(path, base_lookup, …)`, `M.status_async(path, base_lookup, opts)`, `change_worktree_git_status(root, status, base, status_diff_base)` guarda `worktree.status_diff[base]`.
  - `.../sources/git_status/init.lua` y `.../sources/filesystem/lib/fs_scan.lua` — llaman a `git.status(_async)` con `base_lookup = nil`.

---

### Task 1 (SPIKE): ¿neo-tree renderiza el status vs base si le pasamos base_lookup?
Sin esto no sabemos si Route 1 alcanza.

- [ ] **Step 1:** Con un repo de prueba y neo-tree cargado, llamar manualmente:
  `require("neo-tree.git").status(worktree_root, { [worktree_root] = "<commit-viejo>" })` y luego abrir el source git_status; inspeccionar el `state.git_status` / `worktree.status_diff[base]` (ver `change_worktree_git_status`). Confirmar si el árbol muestra los archivos que difieren vs `<commit-viejo>` (no solo `git status`).
- [ ] **Step 2:** Determinar el punto exacto donde el render decide qué status usar (plain vs `status_diff[base]`). Buscar en `sources/git_status` y en el componente `git_status` del renderer cómo lee `state.git_status`.
- [ ] **Decisión:** si el render usa `status_diff[base]` cuando hay base → **Route 1**. Si ignora la base al renderizar → **Route 2**.

---

### Task 2 — Route 1 (preferida): inyectar base_lookup en el git status de neo-tree
Objetivo: que neo-tree calcule el status vs `core.git.base_ref` sin tocar el diseño.

**Files:** `lua/review/features/sidebar/init.lua` (o nuevo `features/sidebar/base_patch.lua`).

- [ ] **Step 1:** En el `setup` del sidebar, envolver (wrap) `require("neo-tree.git").status` y `.status_async` UNA sola vez: si `base_lookup` viene `nil` y `core.git.base_ref ~= "HEAD"`, construir `base_lookup = { [worktree_root] = ref }` (ref = `base_ref`, y para `:` la base index — verificar cómo lo espera `diff_name_status_job`; si index no aplica, tratar `:` como "sin base" = git status normal). Guardar la función original y delegar. Idempotente (no doble-wrap).
- [ ] **Step 2:** El `worktree_root` para el base_lookup: derivarlo del `path`/cwd como hace neo-tree (`find_worktree_info`) o de `core.git.root()`.
- [ ] **Step 3:** Suscribir a `core.events.on("base:changed", …)` → si hay una ventana neo-tree del source git_status visible, `Neotree refresh` (recomputa con la nueva base). Reusar el patrón de views/scrollbar.
- [ ] **Step 4 (verificación manual):** repo con varios commits. `<leader>s` (changed) con base HEAD → idéntico a hoy. `:ReviewBase` → elegir un commit viejo → `<leader>s`/refresh muestra los archivos cambiados **desde ese commit**, con el MISMO diseño (íconos, `●`, fondo morado, status M/A/D). Volver a HEAD → vuelve a git status normal.
- [ ] **Step 5:** Confirmar que `base = ":"` (index) y `base = HEAD` no rompen (comportamiento actual intacto). Correr la suite (105 verde).

---

### Task 2' — Route 2 (fallback): source propio `review_changed`
Solo si Task 1 concluye que el render NO respeta la base.

**Files:** `lua/review/features/sidebar/source.lua` (nuevo), `features/sidebar/init.lua`.

- [ ] **Step 1:** Implementar un source de neo-tree (interfaz: `name`, `display_name`, `setup(config, global_config)`, `navigate(state, path)`, `default_config`). Construir el árbol desde `git diff --name-status <base>` (+ untracked) → nodos file/directory con su status (M/A/D). REUSAR los renderers/components del source `filesystem`/`git_status` para que el diseño sea idéntico (indent, icon, name, `opened_marker`, git_status, diagnostics).
- [ ] **Step 2:** Registrar el source en la config de neo-tree del usuario: `sources = { "filesystem", "git_status", "review_changed" }` (+ su `review_changed = {...}`). Como es config del usuario, documentar el snippet en `docs/commands.md` y en `~/.config/nvim` (el plan lo aplica ahí).
- [ ] **Step 3:** `features/sidebar/init.lua`: `open_sidebar("changed")` abre el source `review_changed` en vez de `git_status`. Mantener `all` = filesystem y el toggle `<leader>s`.
- [ ] **Step 4:** `base:changed` → refrescar el source. Verificación manual igual que Route 1 Step 4. Suite verde.

---

### Task 3 — Integración y toggle
- [ ] Mantener `<leader>s` toggle changed↔all y el auto-cierre/comportamiento actual.
- [ ] Asegurar que el `●` (opened_marker) y el fondo morado del archivo actual siguen funcionando en el sidebar base-aware (mismos componentes/`after_render`).

### Task 4 — Docs
- [ ] `docs/commands.md`: nota de que el sidebar `changed` ahora respeta la base.
- [ ] `docs/decisions.md`: D nueva — cómo se hizo base-aware el sidebar (Route elegida y por qué).

## Verificación / Self-review
- Diseño idéntico con base=HEAD (comparar visualmente con hoy).
- Con base=commit: el árbol muestra los cambios vs ese commit, mismo look.
- `base:changed` refresca el sidebar sin flicker ni fugas.
- Suite 105/105 verde. Sin romper views/scrollbar/gitsigns (que ya son base-aware).
- Preferir Route 1 (mínimamente invasiva, diseño garantizado). Route 2 solo si el spike lo exige.
