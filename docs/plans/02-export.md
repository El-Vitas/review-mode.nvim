# review.nvim — Plan 02: Export (markdown agent-ready + yank)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps con checkbox (`- [ ]`).
> **Plan maestro:** `~/Dev/nvim/review.nvim/DESIGN.md` — este plan implementa el slice `export` de la tabla "Features". Toda firma aquí DEBE coincidir con el "Contrato del core" (ver `docs/plans/00-core.md`).

**Goal:** Construir el vertical slice `export`: formateo de comentarios a markdown agent-ready (con anclas `path:lnum`) y comandos de yank al registro `+` (`:ReviewYankFile`/`:Ryf`, `:ReviewYankAll`/`:Rya`). Depende SOLO de `core.state` (y `core.git.rel_path` para resolver el archivo actual en `commands.lua`).

**Architecture:** Módulos Lua bajo `lua/review/features/export/`. `markdown.lua` es lógica pura (sin I/O, sin `vim.fn.setreg`) — testeable con plenary sin mocks de registro. `commands.lua` es el borde con Neovim: registra `:ReviewYankFile`/`:ReviewYankAll`, resuelve el buffer actual vía `core.git.rel_path(0)`, llama a `markdown.lua` y copia con `vim.fn.setreg("+", ...)`. `init.lua` es el punto de entrada de la feature: `M.setup(core, opts)` registra comandos/keymaps, y al final del archivo se auto-registra en `core.registry`.

**Tech Stack:** Lua, Neovim ≥ 0.10, plenary.nvim (tests busted).

## Global Constraints

- La feature **NUNCA** hace `require("review.features.otra")`. Solo `require("review.core")`.
- `markdown.lua` es lógica pura: recibe listas de `comment` ya resueltas por el caller (`state.for_path`/`state.all`), no llama a `core.state` directamente salvo en `file()`/`all()` (helpers finos que delegan a `core.state.for_path`/`core.state.all`).
- Comentarios **resueltos** (`resolved == true`) se excluyen siempre del markdown.
- Ancla: `` `path:lnum` `` si `lnum == end_lnum`, `` `path:lnum-end_lnum` `` si `end_lnum > lnum`.
- Lista vacía (o todo resuelto) → `markdown()` devuelve `""` (string vacío, sin header suelto).
- `commands.lua` nunca lanza error si `core.git.rel_path(0)` devuelve `nil` (buffer sin archivo o fuera del repo): notifica con `vim.notify` y no ejecuta el yank.
- Comandos capitalizados (`:ReviewYankFile`, `:ReviewYankAll`); los alias cortos (`:Ryf`, `:Rya`) se declaran como `vim.api.nvim_create_user_command` adicionales (no dependen de `cnoreabbrev`, que es responsabilidad de `plugin/review.lua` para las versiones en minúscula `ryf`/`rya` — fuera de alcance de este plan).
- Keymaps `<leader>rf` (yank file) y `<leader>ra` (yank all), con prefijo configurable vía `opts.leader` (default `M.config.leader` del plan 00, típicamente `<leader>r`).
- Tests: `nvim --headless -c "PlenaryBustedFile tests/export/<spec>.lua" -c "qa"`. Patrón busted igual al de `00-core.md`: `store.root_fn` override + `state._reset()` + `state.add(...)`.

---

### Task 1: `features/export/markdown.lua` — formateo puro a markdown

**Files:**
- Create: `lua/review/features/export/markdown.lua`, `tests/export/markdown_spec.lua`

**Interfaces:**
- Consumes: `core.state.for_path(relpath)`, `core.state.all()` (Task 5 de `00-core.md`).
- Produces:
  - `markdown.markdown(list)` → `string` — recibe un `comment[]`, filtra resueltos, devuelve markdown numerado con ancla. `""` si no queda nada.
  - `markdown.file(core, relpath)` → `string` — `markdown.markdown(core.state.for_path(relpath))`.
  - `markdown.all(core)` → `string` — `markdown.markdown(core.state.all())`.

- [ ] **Step 1: Test que falla — `tests/export/markdown_spec.lua`**

```lua
local md = require("review.features.export.markdown")

describe("features.export.markdown", function()
  describe("markdown(list)", function()
    it("lista vacía devuelve string vacío", function()
      assert.are.equal("", md.markdown({}))
    end)

    it("línea simple: ancla path:lnum sin rango", function()
      local list = {
        { id = "1", path = "src/a.ts", lnum = 10, end_lnum = 10, text = "ojo con esto", resolved = false },
      }
      local out = md.markdown(list)
      assert.is_truthy(out:match("^1%. "))
      assert.is_truthy(out:match("`src/a%.ts:10`"))
      assert.is_falsy(out:match("`src/a%.ts:10-10`"))
      assert.is_truthy(out:match("ojo con esto"))
    end)

    it("rango: ancla path:lnum-end_lnum cuando end_lnum > lnum", function()
      local list = {
        { id = "1", path = "src/b.ts", lnum = 5, end_lnum = 8, text = "revisar bloque", resolved = false },
      }
      local out = md.markdown(list)
      assert.is_truthy(out:match("`src/b%.ts:5-8`"))
    end)

    it("excluye comentarios resueltos", function()
      local list = {
        { id = "1", path = "a.ts", lnum = 1, end_lnum = 1, text = "visible", resolved = false },
        { id = "2", path = "a.ts", lnum = 2, end_lnum = 2, text = "resuelto", resolved = true },
      }
      local out = md.markdown(list)
      assert.is_truthy(out:match("visible"))
      assert.is_falsy(out:match("resuelto"))
    end)

    it("todo resuelto devuelve string vacío (sin header suelto)", function()
      local list = {
        { id = "1", path = "a.ts", lnum = 1, end_lnum = 1, text = "resuelto", resolved = true },
      }
      assert.are.equal("", md.markdown(list))
    end)

    it("numera correctamente varios comentarios no resueltos", function()
      local list = {
        { id = "1", path = "a.ts", lnum = 1, end_lnum = 1, text = "uno", resolved = false },
        { id = "2", path = "a.ts", lnum = 2, end_lnum = 2, text = "dos", resolved = true },
        { id = "3", path = "a.ts", lnum = 3, end_lnum = 3, text = "tres", resolved = false },
      }
      local out = md.markdown(list)
      assert.is_truthy(out:match("1%. .*uno"))
      assert.is_truthy(out:match("2%. .*tres"))
      assert.is_falsy(out:match("3%. "))
    end)

    it("colapsa saltos de línea del texto (no rompe la numeración)", function()
      local list = {
        { id = "1", path = "a.ts", lnum = 1, end_lnum = 1, text = "línea1\nlínea2", resolved = false },
        { id = "2", path = "a.ts", lnum = 2, end_lnum = 2, text = "otro", resolved = false },
      }
      local out = md.markdown(list)
      local n = select(2, out:gsub("\n", "\n")) + 1  -- cantidad de líneas
      assert.are.equal(2, n)                          -- exactamente 2 líneas numeradas
      assert.is_truthy(out:match("1%. .*línea1 línea2"))
    end)
  end)

  describe("file/all", function()
    local store, state
    before_each(function()
      store = require("review.core.store")
      state = require("review.core.state")
      local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
      store.root_fn = function() return tmp end
      state._reset()
    end)

    it("file(core, relpath) delega en state.for_path", function()
      local core = { state = state }
      state.add({ path = "a.ts", lnum = 1, text = "solo a" })
      state.add({ path = "b.ts", lnum = 1, text = "solo b" })
      local out = md.file(core, "a.ts")
      assert.is_truthy(out:match("solo a"))
      assert.is_falsy(out:match("solo b"))
    end)

    it("all(core) delega en state.all", function()
      local core = { state = state }
      state.add({ path = "a.ts", lnum = 1, text = "solo a" })
      state.add({ path = "b.ts", lnum = 1, text = "solo b" })
      local out = md.all(core)
      assert.is_truthy(out:match("solo a"))
      assert.is_truthy(out:match("solo b"))
    end)

    it("all(core) sin comentarios devuelve string vacío", function()
      local core = { state = state }
      assert.are.equal("", md.all(core))
    end)
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/export/markdown_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.export.markdown' not found").

- [ ] **Step 3: Implementar `lua/review/features/export/markdown.lua`**

```lua
local M = {}

local function anchor(c)
  if c.end_lnum and c.end_lnum > c.lnum then
    return string.format("`%s:%d-%d`", c.path, c.lnum, c.end_lnum)
  end
  return string.format("`%s:%d`", c.path, c.lnum)
end

-- Colapsa saltos de línea del texto del comentario a un espacio: cada comentario
-- DEBE ocupar exactamente una línea numerada, o `table.concat("\n")` rompería la
-- numeración del markdown agent-ready.
local function oneline(text)
  return ((text or ""):gsub("[\r\n]+", " "))
end

--- Formatea una lista de comentarios a markdown numerado, agent-ready.
--- Excluye los comentarios resueltos. Devuelve "" si no queda ninguno.
--- @param list table[] lista de comment (id, path, lnum, end_lnum, text, resolved, ...)
--- @return string
function M.markdown(list)
  list = list or {}
  local lines = {}
  local n = 0
  for _, c in ipairs(list) do
    if not c.resolved then
      n = n + 1
      table.insert(lines, string.format("%d. %s %s", n, anchor(c), oneline(c.text)))
    end
  end
  if n == 0 then return "" end
  return table.concat(lines, "\n")
end

--- Markdown de los comentarios de un solo archivo.
--- @param core table tabla core (usa core.state.for_path)
--- @param relpath string path relativo a la raíz git
--- @return string
function M.file(core, relpath)
  return M.markdown(core.state.for_path(relpath))
end

--- Markdown de todos los comentarios del repo.
--- @param core table tabla core (usa core.state.all)
--- @return string
function M.all(core)
  return M.markdown(core.state.all())
end

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/export/markdown_spec.lua" -c "qa"`
Expected: PASS (10).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(export/markdown): formateo agent-ready con anclas path:lnum"
```

---

### Task 2: `features/export/commands.lua` — comandos de yank

**Files:**
- Create: `lua/review/features/export/commands.lua`, `tests/export/commands_spec.lua`

**Interfaces:**
- Consumes: `core.git.rel_path(bufnr)`, `core.state.*` (vía `markdown.lua`, Task 1).
- Produces: `commands.setup(core, opts)` — registra `:ReviewYankFile`/`:Ryf`, `:ReviewYankAll`/`:Rya` y los keymaps `<leader>rf`/`<leader>ra` (prefijo `opts.leader or "<leader>r"`).

- [ ] **Step 1: Test que falla — `tests/export/commands_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local commands = require("review.features.export.commands")

describe("features.export.commands", function()
  local core, tmp

  before_each(function()
    tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
    core = { state = state, git = git }
    vim.fn.setreg("+", "")
    pcall(vim.api.nvim_del_user_command, "ReviewYankFile")
    pcall(vim.api.nvim_del_user_command, "ReviewYankAll")
    pcall(vim.api.nvim_del_user_command, "Ryf")
    pcall(vim.api.nvim_del_user_command, "Rya")
  end)

  it("registra comandos y alias", function()
    commands.setup(core, {})
    local cmds = vim.api.nvim_get_commands({})
    assert.is_truthy(cmds["ReviewYankFile"])
    assert.is_truthy(cmds["ReviewYankAll"])
    assert.is_truthy(cmds["Ryf"])
    assert.is_truthy(cmds["Rya"])
  end)

  it(":ReviewYankFile copia solo los comentarios del archivo actual al registro +", function()
    commands.setup(core, {})
    state.add({ path = "a.ts", lnum = 1, text = "de a" })
    state.add({ path = "b.ts", lnum = 1, text = "de b" })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, tmp .. "/a.ts")
    vim.api.nvim_set_current_buf(buf)

    vim.cmd("ReviewYankFile")
    local reg = vim.fn.getreg("+")
    assert.is_truthy(reg:match("de a"))
    assert.is_falsy(reg:match("de b"))
  end)

  it(":ReviewYankAll copia todos los comentarios al registro +", function()
    commands.setup(core, {})
    state.add({ path = "a.ts", lnum = 1, text = "de a" })
    state.add({ path = "b.ts", lnum = 1, text = "de b" })

    vim.cmd("ReviewYankAll")
    local reg = vim.fn.getreg("+")
    assert.is_truthy(reg:match("de a"))
    assert.is_truthy(reg:match("de b"))
  end)

  it(":ReviewYankFile con buffer fuera del repo no rompe y no toca el registro", function()
    commands.setup(core, {})
    state.add({ path = "a.ts", lnum = 1, text = "de a" })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "/otro/lugar/x.ts")
    vim.api.nvim_set_current_buf(buf)

    vim.fn.setreg("+", "sin-tocar")
    assert.has_no.errors(function() vim.cmd("ReviewYankFile") end)
    assert.are.equal("sin-tocar", vim.fn.getreg("+"))
  end)

  it(":ReviewYankAll con lista vacía notifica y no rompe", function()
    commands.setup(core, {})
    vim.fn.setreg("+", "sin-tocar")
    assert.has_no.errors(function() vim.cmd("ReviewYankAll") end)
    assert.are.equal("sin-tocar", vim.fn.getreg("+"))
  end)

  it("respeta opts.leader en los keymaps", function()
    commands.setup(core, { leader = "<leader>z" })
    local found = {}
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.lhs == "<leader>zf" then found.f = true end
      if m.lhs == "<leader>za" then found.a = true end
    end
    assert.is_true(found.f)
    assert.is_true(found.a)
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/export/commands_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.export.commands' not found").

- [ ] **Step 3: Implementar `lua/review/features/export/commands.lua`**

```lua
local markdown = require("review.features.export.markdown")

local M = {}

local function yank(text)
  if not text or text == "" then
    vim.notify("review.nvim: sin comentarios", vim.log.levels.INFO)
    return
  end
  vim.fn.setreg("+", text)
  vim.notify("review.nvim: comentarios copiados al registro +", vim.log.levels.INFO)
end

local function yank_file(core)
  local relpath = core.git.rel_path(0)
  if not relpath then
    vim.notify("review.nvim: el buffer actual no pertenece al repo", vim.log.levels.WARN)
    return
  end
  yank(markdown.file(core, relpath))
end

local function yank_all(core)
  yank(markdown.all(core))
end

function M.setup(core, opts)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"

  vim.api.nvim_create_user_command("ReviewYankFile", function() yank_file(core) end, {})
  vim.api.nvim_create_user_command("ReviewYankAll", function() yank_all(core) end, {})
  vim.api.nvim_create_user_command("Ryf", function() yank_file(core) end, {})
  vim.api.nvim_create_user_command("Rya", function() yank_all(core) end, {})

  vim.keymap.set("n", leader .. "f", function() yank_file(core) end, { desc = "Review: yank comments of current file" })
  vim.keymap.set("n", leader .. "a", function() yank_all(core) end, { desc = "Review: yank all comments" })
end

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/export/commands_spec.lua" -c "qa"`
Expected: PASS (6).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(export/commands): ReviewYankFile/ReviewYankAll + keymaps"
```

---

### Task 3: `features/export/init.lua` — entrypoint + auto-registro

**Files:**
- Create: `lua/review/features/export/init.lua`, `tests/export/init_spec.lua`

**Interfaces:**
- Consumes: `commands` (Task 2), `core.registry.register` (`00-core.md` Task 1).
- Produces: `M.setup(core, opts)` (delega en `commands.setup`); al `require`, la feature se auto-registra en `core.registry` como `{ name = "export", setup = M.setup }`.

- [ ] **Step 1: Test que falla — `tests/export/init_spec.lua`**

```lua
describe("features.export.init", function()
  it("se auto-registra en core.registry al requerirse", function()
    local core = require("review.core")
    require("review.features.export")
    local features = core.registry.features()
    assert.is_truthy(features["export"])
    assert.is_function(features["export"].setup)
  end)

  it("M.setup delega en commands.setup y no rompe sin opts", function()
    local export = require("review.features.export")
    local store = require("review.core.store")
    local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    local core = require("review.core")
    pcall(vim.api.nvim_del_user_command, "ReviewYankFile")
    pcall(vim.api.nvim_del_user_command, "ReviewYankAll")
    assert.has_no.errors(function() export.setup(core, {}) end)
    local cmds = vim.api.nvim_get_commands({})
    assert.is_truthy(cmds["ReviewYankFile"])
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/export/init_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.export' not found").

- [ ] **Step 3: Implementar `lua/review/features/export/init.lua`**

```lua
local commands = require("review.features.export.commands")

local M = {}

--- Entrypoint de la feature export. Registra comandos y keymaps.
--- @param core table tabla core (git, store, state, ns, events, registry)
--- @param opts table opciones de la feature (leader, etc.)
function M.setup(core, opts)
  commands.setup(core, opts or {})
end

require("review.core").registry.register({ name = "export", setup = M.setup })

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/export/init_spec.lua" -c "qa"`
Expected: PASS (2).

- [ ] **Step 5: Suite completa de export**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedDirectory tests/export/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`
Expected: PASS (markdown 10, commands 6, init 2).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(export): entrypoint init.lua + auto-registro en core.registry"
```

---

## Self-Review

- **Cobertura del contrato (DESIGN.md tabla Features → export):** `markdown` agent-ready ✅ (T1), `:ReviewYankFile`/`:Ryf` ✅ (T2), `:ReviewYankAll`/`:Rya` ✅ (T2). Dependencia declarada `state.*` ✅ (T1 vía `for_path`/`all`), más `git.rel_path` usado solo dentro de `commands.lua` para resolver el archivo actual — no viola "depende solo del contrato del core", ya que `git` también es parte del contrato del core.
- **Regla de no-dependencia cruzada:** ningún `require("review.features.<otra>")` en todo el slice; solo `require("review.core")` y submódulos internos de `export`.
- **Edge cases cubiertos:** lista vacía → `""` sin header suelto (T1, tests "lista vacía" y "todo resuelto"); resueltos excluidos (T1); rango `end_lnum == lnum` se muestra sin sufijo `-end_lnum` (T1, test "línea simple"); rango real `end_lnum > lnum` (T1, test "rango"); buffer fuera del repo (`rel_path` nil) → `vim.notify` + no-op, sin tocar el registro (T2, test "buffer fuera del repo"); lista vacía en comandos → notifica "sin comentarios" y no rompe (T2, test "lista vacía notifica").
- **Placeholders:** ninguno; todo el código Lua está completo y es el que se espera correr tal cual.
- **Consistencia de firmas:** `markdown.markdown(list)`, `markdown.file(core, relpath)`, `markdown.all(core)` (usan `core.state.for_path`/`core.state.all` tal como en el contrato); `commands.setup(core, opts)`; `M.setup(core, opts)` en `init.lua` con auto-registro `core.registry.register({ name = "export", setup = M.setup })`, igual al patrón de `00-core.md`.
- **Storage:** esta feature no toca `core.store` directamente (correcto: export es solo lectura de `state` + formateo + registro de Neovim, ningún I/O de disco propio).
</content>
