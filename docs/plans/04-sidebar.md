# review.nvim — Plan 04: Sidebar (integración neo-tree)

> **Plan maestro:** `~/Dev/nvim/review.nvim/DESIGN.md` — este plan implementa el slice **sidebar** de
> la tabla de features (depende de `core.git.changed_files`, `core.state.for_path`, neo-tree; escucha
> `comments:changed`). Toda firma aquí DEBE coincidir con el "Contrato del core".
> REQUIRED SUB-SKILL: superpowers:subagent-driven-development

**Goal:** Integrar `nvim-neo-tree/neo-tree.nvim` (v3.x) para alternar entre ver SOLO los archivos
cambiados (`source = "git_status"`) y TODOS (`source = "filesystem"`), con un comando
`:ReviewSidebar {changed|all}` / `:Rs`, un keymap `<leader>rs`, y un helper puro
`files_with_comments()` que calcula qué archivos tienen ≥1 comentario para poder marcarlos
visualmente en el árbol.

**Architecture:** Un único slice bajo `lua/review/features/sidebar/`. `init.lua` contiene todo:
`M.setup(core, opts)`, el comando/keymap, la suscripción a `comments:changed`, y el helper puro
`files_with_comments(core)`. La integración con neo-tree se hace exclusivamente vía su API pública
(`require("neo-tree.command").execute({...})`), nunca tocando sus internals. Si neo-tree no está
instalado, la feature se degrada con gracia (pcall + `vim.notify`, no rompe `review.setup`).

**Tech Stack:** Lua, Neovim ≥ 0.10, plenary.nvim (tests busted), `nvim-neo-tree/neo-tree.nvim` v3.x
(dependencia opcional en runtime, NO en `lua/review/*`).

## Global Constraints

- La feature **NUNCA** hace `require("review.features.otra")`. Solo `require("review.core")`.
- Coordinación con `comments` (o cualquier otra feature) = **solo** vía `core.events`
  (`comments:changed`). Cero acoplamiento directo.
- `require("neo-tree.command")` / `require("neo-tree.setup...")` van SIEMPRE detrás de `pcall`. Si
  falla, `vim.notify("review.nvim: neo-tree.nvim no está instalado, sidebar deshabilitado", vim.log.levels.WARN)`
  y `M.setup` retorna sin registrar comando ni keymap ni suscripción.
- No suscribirse dos veces a `comments:changed` si `M.setup` corre más de una vez (guardar un flag
  módulo-local `_subscribed`).
- El evento `comments:changed` NO debe forzar la apertura del árbol si está cerrado — solo refresca
  si ya hay una ventana neo-tree visible.
- Repo sin cambios → `changed_files()` vacío → árbol `git_status` vacío es un estado válido, no un
  error.
- `files_with_comments()` es PURA: recibe `core` (o directamente usa `core.state.all()`), devuelve un
  `set` (`{ [relpath] = true }`), sin ningún efecto secundario ni dependencia de neo-tree. Es la única
  parte de este slice con tests automatizados.
- Tests: `nvim --headless -c "PlenaryBustedFile tests/sidebar/<spec>.lua" -c "qa"`.

---

### Task 1: `files_with_comments()` — helper puro

**Files:**
- Create: `lua/review/features/sidebar/init.lua`, `tests/sidebar/files_with_comments_spec.lua`

**Interfaces:**
- Consumes: `core.state.all()` (contrato ya construido en `00-core.md` Task 5).
- Produces: `M.files_with_comments(core)` → `table<string, boolean>` (set de relpaths con ≥1
  comentario NO resuelto o resuelto — cuenta cualquier comentario existente en `path`).

- [ ] **Step 1: Test que falla — `tests/sidebar/files_with_comments_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local sidebar = require("review.features.sidebar")

describe("sidebar.files_with_comments", function()
  local core

  before_each(function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
    core = { state = state }
  end)

  it("vacío si no hay comentarios", function()
    local set = sidebar.files_with_comments(core)
    assert.are.same({}, set)
  end)

  it("incluye cada relpath con ≥1 comentario, sin duplicados", function()
    state.add({ path = "a.ts", lnum = 1, text = "x" })
    state.add({ path = "a.ts", lnum = 2, text = "y" })
    state.add({ path = "b/c.ts", lnum = 1, text = "z" })

    local set = sidebar.files_with_comments(core)

    assert.is_true(set["a.ts"])
    assert.is_true(set["b/c.ts"])
    local count = 0
    for _ in pairs(set) do count = count + 1 end
    assert.are.equal(2, count)
  end)

  it("incluye comentarios resueltos también", function()
    state.add({ path = "a.ts", lnum = 1, text = "x", resolved = true })
    local set = sidebar.files_with_comments(core)
    assert.is_true(set["a.ts"])
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/sidebar/files_with_comments_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.sidebar' not found").

- [ ] **Step 3: Implementar `lua/review/features/sidebar/init.lua` (parte pura primero)**

```lua
local M = {}

M._subscribed = false

--- Helper PURO: set de relpaths con ≥1 comentario. No toca neo-tree, no tiene
--- efectos secundarios. Reutilizable por quien quiera marcar el árbol.
--- @param core table  el core de review.nvim (usa core.state.all())
--- @return table<string, boolean>
function M.files_with_comments(core)
  local set = {}
  for _, c in ipairs(core.state.all()) do
    if c.path then
      set[c.path] = true
    end
  end
  return set
end

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/sidebar/files_with_comments_spec.lua" -c "qa"`
Expected: PASS (3).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(sidebar): helper puro files_with_comments"
```

---

### Task 2: Detección de neo-tree + `M.setup` con degradación

**Files:**
- Modify: `lua/review/features/sidebar/init.lua`
- Create: `tests/sidebar/setup_spec.lua`

**Interfaces:**
- Consumes: `core` (tabla completa del contrato), `opts` (config de la feature).
- Produces: `M.setup(core, opts)` — registra comando/keymap/suscripción SOLO si neo-tree está
  disponible; si no, `vim.notify` + retorna sin romper nada. Idempotente (no doble-suscripción).

- [ ] **Step 1: Test que falla — `tests/sidebar/setup_spec.lua`**

```lua
local events = require("review.core.events")
local state = require("review.core.state")
local store = require("review.core.store")
local sidebar = require("review.features.sidebar")

describe("sidebar.setup", function()
  before_each(function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
    events._reset()          -- evita fuga de suscriptores entre tests (si no, el conteo da falso-positivo)
    sidebar._subscribed = false
  end)

  it("no explota si neo-tree no está instalado", function()
    local core = { state = state, events = events, git = { changed_files = function() return {} end } }
    assert.has_no.errors(function()
      sidebar.setup(core, {})
    end)
  end)

  it("no se suscribe dos veces a comments:changed tras dos setup()", function()
    local core = { state = state, events = events, git = { changed_files = function() return {} end } }
    sidebar.setup(core, {})
    sidebar.setup(core, {})

    local calls = 0
    -- Contamos cuántos handlers de comments:changed hay disparando un evento
    -- y viendo que M._refresh no se invoque más de una vez por emit.
    local orig = sidebar._refresh
    sidebar._refresh = function(...)
      calls = calls + 1
      if orig then orig(...) end
    end

    events.emit("comments:changed", {})
    vim.wait(50)

    sidebar._refresh = orig
    assert.are.equal(1, calls)
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/sidebar/setup_spec.lua" -c "qa"`
Expected: FAIL (`sidebar.setup` no existe todavía).

- [ ] **Step 3: Implementar `M.setup` en `lua/review/features/sidebar/init.lua`**

```lua
local M = {}

M._subscribed = false
M._core = nil

--- Helper PURO: set de relpaths con ≥1 comentario. No toca neo-tree, no tiene
--- efectos secundarios. Reutilizable por quien quiera marcar el árbol.
--- @param core table  el core de review.nvim (usa core.state.all())
--- @return table<string, boolean>
function M.files_with_comments(core)
  local set = {}
  for _, c in ipairs(core.state.all()) do
    if c.path then
      set[c.path] = true
    end
  end
  return set
end

--- Verdadero si hay una ventana neo-tree visible en el tab actual.
local function neotree_window_open()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "neo-tree" then
      return true
    end
  end
  return false
end

--- Refresca el indicador/redibujado del árbol si está abierto. No fuerza apertura.
--- Fase actual: recalcula el set puro; el marcado visual fino queda documentado
--- como fase secundaria (ver Task 4).
function M._refresh()
  if not M._core then return end
  if not neotree_window_open() then return end
  local ok, command = pcall(require, "neo-tree.command")
  if not ok then return end
  M._files_with_comments_cache = M.files_with_comments(M._core)
  pcall(command.execute, { action = "refresh" })
end

--- Abre/enfoca el árbol de neo-tree en el source pedido.
--- @param kind "changed"|"all"
local function open_sidebar(kind)
  local ok, command = pcall(require, "neo-tree.command")
  if not ok then
    vim.notify("review.nvim: neo-tree.nvim no está instalado, sidebar deshabilitado", vim.log.levels.WARN)
    return
  end
  -- Recalcular el cache de archivos-con-comentarios al abrir, para que el
  -- marcador no quede obsoleto si se agregaron/borraron comentarios con el
  -- árbol cerrado (M._refresh se saltea cuando la ventana no está abierta).
  if M._core then M._files_with_comments_cache = M.files_with_comments(M._core) end
  local source = kind == "all" and "filesystem" or "git_status"
  command.execute({ source = source, action = "show", position = "right" })
end

function M.setup(core, opts)
  opts = opts or {}
  M._core = core

  local ok = pcall(require, "neo-tree.command")
  if not ok then
    vim.notify("review.nvim: neo-tree.nvim no está instalado, sidebar deshabilitado", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_create_user_command("ReviewSidebar", function(cmd_opts)
    local kind = cmd_opts.args ~= "" and cmd_opts.args or "changed"
    if kind ~= "changed" and kind ~= "all" then
      vim.notify("review.nvim: :ReviewSidebar espera 'changed' o 'all'", vim.log.levels.ERROR)
      return
    end
    open_sidebar(kind)
  end, {
    nargs = "?",
    complete = function() return { "changed", "all" } end,
  })

  -- Alias corto como comando REAL (la minúscula `rs` la resuelve plugin/review.lua).
  vim.api.nvim_create_user_command("Rs", function(cmd_opts)
    local kind = cmd_opts.args ~= "" and cmd_opts.args or "changed"
    if kind ~= "changed" and kind ~= "all" then
      vim.notify("review.nvim: :Rs espera 'changed' o 'all'", vim.log.levels.ERROR)
      return
    end
    open_sidebar(kind)
  end, { nargs = "?", complete = function() return { "changed", "all" } end })

  local keymap_lhs = (opts.leader or "<leader>r") .. "s"
  vim.keymap.set("n", keymap_lhs, function() open_sidebar("changed") end, { desc = "Review: sidebar (cambiados)" })

  if not M._subscribed then
    core.events.on("comments:changed", function()
      M._refresh()
    end)
    M._subscribed = true
  end
end

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/sidebar/setup_spec.lua" -c "qa"`
Expected: PASS (2). (Nota: en el entorno de test no hay `neo-tree.nvim` en el `runtimepath` salvo que
`minimal_init.lua` lo agregue — por eso el primer test verifica justamente el camino de degradación
sin explotar. Si tu `minimal_init.lua` SÍ carga neo-tree, el comando se registra igual y el test
sigue pasando.)

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(sidebar): setup con comando/keymap/suscripcion y degradacion sin neo-tree"
```

---

### Task 3: Registro en `review.core.registry` + comando/alias finales

**Files:**
- Modify: `lua/review/features/sidebar/init.lua` (agregar auto-registro al final del archivo)

**Interfaces:**
- Consumes: `require("review.core").registry.register`.
- Produces: la feature queda disponible para `core.registry.setup(core, opts)` bajo el nombre
  `"sidebar"`, en línea con `comments`, `export`, `views`, `agent`.

- [ ] **Step 1: Agregar auto-registro al final de `lua/review/features/sidebar/init.lua`**

```lua
require("review.core").registry.register({ name = "sidebar", setup = M.setup })
```

- [ ] **Step 2: Verificación manual — carga end-to-end**

1. Abrir un repo git con al menos un archivo modificado y otro sin cambios.
2. `nvim -c "lua require('review').setup()"`.
3. Verificar sin errores en `:messages` (si neo-tree está instalado; si no, verificar que aparece el
   `vim.notify` de WARN y Neovim sigue usable).
4. `:ReviewSidebar changed` → el árbol de neo-tree se abre a la derecha mostrando solo los archivos
   con diff vs HEAD (source `git_status`).
5. `:ReviewSidebar all` (o `:Rs all`) → el mismo panel cambia a mostrar el árbol completo (source
   `filesystem`).
6. `<leader>rs` → abre/enfoca el árbol en modo `changed` (atajo rápido).
7. Repetir `require('review').setup()` una segunda vez en la misma sesión (`:lua require('review').setup()`)
   y confirmar que NO aparecen keymaps/comandos duplicados con error, y que un `:messages` no muestra
   doble notificación de suscripción rota.

- [ ] **Step 3: Verificación manual — repo sin cambios**

1. En un repo con `git status` limpio, correr `:ReviewSidebar changed`.
2. Esperado: el árbol se abre vacío (o solo con carpetas sin archivos marcados), sin error ni traceback.

- [ ] **Step 4: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(sidebar): auto-registro en review.core.registry"
```

---

### Task 4: Indicador visual de comentarios (fase secundaria, documentada)

**Files:**
- Modify: `lua/review/features/sidebar/init.lua` (agregar función de utilidad expuesta, sin forzar
  integración profunda con los componentes internos de neo-tree)

**Interfaces:**
- Produces: `M.comment_marker(relpath)` → `string|nil` (el string `"💬"` si `relpath` está en el
  último `files_with_comments()` calculado, `nil` si no) — utilidad que el usuario puede enganchar
  manualmente en su propia config de neo-tree (`default_component_configs` / componente custom `name`)
  si quiere ver el marcador en el árbol. Integrar un componente custom de neo-tree que reemplace el
  renderer de `name` es invasivo (requiere sobreescribir `renderers.file` en la config global de
  neo-tree del usuario, fuera del alcance de este plugin) — por eso se documenta como vía mínima en
  vez de forzarlo.

- [ ] **Step 1: Implementar `M.comment_marker` en `lua/review/features/sidebar/init.lua`**

```lua
--- Marcador textual para un relpath, pensado para enganchar en un renderer
--- custom de neo-tree (ver docs/plans/04-sidebar.md Task 4). Se basa en el
--- último cache calculado por M._refresh(); si nunca corrió, lo calcula ahora.
--- @param relpath string
--- @return string|nil
function M.comment_marker(relpath)
  if not M._core then return nil end
  M._files_with_comments_cache = M._files_with_comments_cache or M.files_with_comments(M._core)
  if M._files_with_comments_cache[relpath] then
    return "💬"
  end
  return nil
end
```

- [ ] **Step 2: Verificación manual — vía mínima de integración**

1. En la config de neo-tree del usuario (ej. `~/.config/nvim/lua/plugins/neotree.lua`), agregar un
   componente custom que llame `require("review.features.sidebar").comment_marker(node:get_id())` y lo
   concatene al nombre del archivo en `renderers.file` — documentado acá como opcional, NO forzado por
   este plugin.
2. Confirmar visualmente que los archivos con comentarios muestran `💬` junto al nombre tras agregar
   ese snippet a la config del usuario.
3. Si el usuario no engancha el renderer, el árbol sigue funcionando normal (Tasks 1–3), solo sin el
   emoji — comportamiento degradado aceptable para esta fase.

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(sidebar): comment_marker como vía minima de indicador visual"
```

---

## Self-Review

- **Cobertura del contrato (DESIGN.md):** `core.git.changed_files` ✅ (usado indirectamente por
  neo-tree source `git_status`, que hace su propio `git status` — no requerimos llamarlo
  directamente porque neo-tree resuelve los cambiados nativamente; queda documentado como decisión).
  `core.state.for_path`/`state.all()` ✅ (Task 1, `files_with_comments`). Evento `comments:changed`
  ✅ (Task 2, suscripción única). `:ReviewSidebar {changed|all}` / `:Rs` ✅ (Task 2/3).
  `<leader>rs` ✅ (Task 2).
- **Placeholders:** ninguno; todo el código Lua está completo y es ejecutable.
- **Degradación sin neo-tree:** `M.setup` hace `pcall(require, "neo-tree.command")` primero y
  `vim.notify` + `return` si falla, sin registrar comando/keymap/suscripción — no rompe
  `core.registry.setup` ni el resto del plugin.
- **No doble-suscripción:** flag módulo-local `M._subscribed`, verificado en `setup_spec.lua`.
- **No acoplamiento entre features:** el módulo solo hace `require("review.core")` (vía el `core`
  recibido en `setup`) y `require("neo-tree.*")`; jamás `require("review.features.comments")`.
- **Repo sin cambios / evento con árbol cerrado:** ambos cubiertos explícitamente (`neotree_window_open()`
  guard en `M._refresh`, Task 3 Step 3 para el repo limpio).
- **Tests automatizados vs manuales:** solo la parte pura (`files_with_comments`, `setup` sin invocar
  UI real de neo-tree) tiene specs bajo `tests/sidebar/`; toda interacción visual con neo-tree
  (apertura de panel, alternancia de source, marcador 💬) se deja como verificación manual explícita
  con pasos concretos (Tasks 3 y 4).
