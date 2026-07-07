# review.nvim — Plan 01: Comments (vertical slice)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps con checkbox (`- [ ]`).
> **Plan maestro:** `~/Dev/nvim/review.nvim/DESIGN.md` — este plan implementa el slice `comments` de la tabla "Features". Toda firma del core citada aquí (`core.git`, `core.store`, `core.state`, `core.ns`, `core.events`, `core.registry`) DEBE coincidir con `docs/plans/00-core.md`.

**Goal:** CRUD de comentarios anclados a línea vía extmarks, modo comentario (toggle + popup nui para agregar/editar), comandos y keymaps, con re-anclaje en escritura. Depende SOLO de `require("review.core")`.

**Architecture:** `lua/review/features/comments/{render,mode,commands,init}.lua`. `render.lua` es puro extmark + `core.state`; `mode.lua` contiene la lógica de UI (guicursor/nui) más un núcleo testeable sin UI (`_add`, `_delete_at`, `_resolve_at`); `commands.lua` registra `:ReviewCommentMode`/`:Rcm`, `:ReviewList`/`:Rl` y keymaps; `init.lua` conecta autocmds y se auto-registra en `core.registry`.

**Tech Stack:** Lua, Neovim ≥ 0.10, plenary.nvim (tests busted), nui.nvim (popup, solo en `mode.add_here`, no en el núcleo testeable).

## Global Constraints

- Nunca `require("review.features.<otra>")` — solo `require("review.core")`.
- `path` de comentario siempre relativo a la raíz git (`core.git.rel_path`). Si `rel_path` devuelve `nil` (buffer fuera del repo o sin nombre), toda operación de comments es no-op silencioso.
- `_extmark_id` es runtime: se setea en `render.lua`, nunca se manda a `core.state.persist` como campo persistido (ya lo filtra `state.persist`), y nunca se usa para decidir si un comentario existe.
- `lnum`/`end_lnum` siempre clampeados a `[1, nvim_buf_line_count(bufnr)]` antes de crear extmark o guardar.
- Si `core.state.for_path(rel)` devuelve `{}`, `render.render` no debe fallar ni crear nada.
- Tests: `nvim --headless -c "PlenaryBustedFile tests/comments/<spec>.lua" -c "qa"`. Suite completa: `nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`.

---

### Task 1: `render.lua` — extmarks + anclaje + sync_positions

**Files:**
- Create: `lua/review/features/comments/render.lua`, `tests/comments/render_spec.lua`

**Interfaces:**
- Consumes: `core.state.for_path(relpath)` → `comment[]`, `core.state.update(id, fields)`, `core.state.by_id(id)`, `core.git.rel_path(bufnr)`, `core.ns.comments`.
- Produces:
  - `render.render(core, bufnr)` — limpia extmarks del namespace `core.ns.comments` en `bufnr` y crea uno por cada comentario de `core.state.for_path(rel)`. El extmark ancla inicio (`row`) **y fin** (`end_row = end_lnum-1`) para preservar rangos multi-línea. `sign_text="💬"`, `virt_text` eol con el `text` truncado; abiertos con prefijo `💬 ` y hl `DiagnosticInfo`, resueltos con `✓ ` y hl `Comment`. Guarda el id en `c._extmark_id`. No-op si `core.git.rel_path(bufnr)` es `nil`.
  - `render.sync_positions(core, bufnr)` — para cada comentario con `_extmark_id`, relee el extmark con `{ details = true }` y actualiza **tanto `lnum` (pos[1]+1) como `end_lnum` (details.end_row+1)** vía `core.state.update`, preservando el rango. No-op si `rel_path` es `nil` o si el comentario no tiene `_extmark_id`.

- [ ] **Step 1: Test que falla — `tests/comments/render_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local render = require("review.features.comments.render")

local core = { state = state, git = git, ns = ns }

describe("comments.render", function()
  local root, bufnr

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    store.root_fn = function() return root end
    state._reset()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. "/foo.ts")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "l1", "l2", "l3", "l4", "l5" })
  end)

  it("no-op si el buffer está fuera del repo", function()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(other, "/fuera/x.ts")
    state.add({ path = "x.ts", lnum = 1, text = "hola" })
    assert.has_no.errors(function() render.render(core, other) end)
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(other, ns.comments, 0, -1, {}))
  end)

  it("no crea nada si no hay comentarios para el path", function()
    assert.has_no.errors(function() render.render(core, bufnr) end)
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(bufnr, ns.comments, 0, -1, {}))
  end)

  it("crea un extmark por comentario y setea _extmark_id", function()
    local c = state.add({ path = "foo.ts", lnum = 2, text = "ojo" })
    render.render(core, bufnr)
    assert.is_number(c._extmark_id)
    assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(bufnr, ns.comments, 0, -1, {}))
  end)

  it("anclaje: insertar línea arriba sube el lnum tras sync_positions", function()
    local c = state.add({ path = "foo.ts", lnum = 3, text = "ojo" })
    render.render(core, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "nueva" })
    render.sync_positions(core, bufnr)
    assert.are.equal(4, state.by_id(c.id).lnum)
  end)

  it("sync_positions no rompe si el comentario no tiene _extmark_id", function()
    state.add({ path = "foo.ts", lnum = 1, text = "sin render" })
    assert.has_no.errors(function() render.sync_positions(core, bufnr) end)
  end)

  it("preserva el rango multi-línea tras insertar arriba", function()
    local c = state.add({ path = "foo.ts", lnum = 2, end_lnum = 4, text = "rango" })
    render.render(core, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "nueva" })
    render.sync_positions(core, bufnr)
    local got = state.by_id(c.id)
    assert.are.equal(3, got.lnum)      -- 2 -> 3
    assert.are.equal(5, got.end_lnum)  -- 4 -> 5 (rango conservado, no colapsado)
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/render_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.comments.render' not found").

- [ ] **Step 3: Implementar `lua/review/features/comments/render.lua`**

```lua
local M = {}

local function clamp(bufnr, lnum)
  local last = vim.api.nvim_buf_line_count(bufnr)
  if last < 1 then return 1 end
  if lnum < 1 then return 1 end
  if lnum > last then return last end
  return lnum
end

function M.render(core, bufnr)
  local rel = core.git.rel_path(bufnr)
  if not rel then return end

  vim.api.nvim_buf_clear_namespace(bufnr, core.ns.comments, 0, -1)

  local comments = core.state.for_path(rel)
  for _, c in ipairs(comments) do
    local lnum = clamp(bufnr, c.lnum or 1)
    local end_lnum = clamp(bufnr, c.end_lnum or lnum)
    if end_lnum < lnum then lnum, end_lnum = end_lnum, lnum end
    local row = lnum - 1
    local text = c.text or ""
    if #text > 60 then text = text:sub(1, 57) .. "..." end

    -- hl distinto según estado: resueltos atenuados (Comment), abiertos DiagnosticInfo.
    local prefix = c.resolved and "✓ " or "💬 "
    local hl = c.resolved and "Comment" or "DiagnosticInfo"

    -- `end_row` ancla el FIN del rango además del inicio, para que los
    -- comentarios multi-línea conserven su rango cuando el código se mueve.
    local id = vim.api.nvim_buf_set_extmark(bufnr, core.ns.comments, row, 0, {
      end_row = end_lnum - 1,
      sign_text = "💬",
      sign_hl_group = hl,
      virt_text = { { prefix .. text, hl } },
      virt_text_pos = "eol",
    })
    c._extmark_id = id
  end
end

function M.sync_positions(core, bufnr)
  local rel = core.git.rel_path(bufnr)
  if not rel then return end

  local comments = core.state.for_path(rel)
  for _, c in ipairs(comments) do
    if c._extmark_id then
      -- `details=true` para recuperar `end_row` y preservar el rango.
      local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, core.ns.comments, c._extmark_id, { details = true })
      if ok and pos and pos[1] then
        local new_lnum = clamp(bufnr, pos[1] + 1)
        local details = pos[3]
        local new_end = new_lnum
        if details and details.end_row then
          new_end = clamp(bufnr, details.end_row + 1)
        end
        if new_end < new_lnum then new_lnum, new_end = new_end, new_lnum end
        if new_lnum ~= c.lnum or new_end ~= c.end_lnum then
          core.state.update(c.id, { lnum = new_lnum, end_lnum = new_end })
        end
      end
    end
  end
end

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/render_spec.lua" -c "qa"`
Expected: PASS (6).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): render extmarks con anclaje y sync_positions"
```

---

### Task 2: `mode.lua` — modo comentario, núcleo testeable (`_add`/`_delete_at`/`_resolve_at`) + toggle/popup

**Files:**
- Create: `lua/review/features/comments/mode.lua`, `tests/comments/mode_spec.lua`

**Interfaces:**
- Consumes: `core.git.rel_path(bufnr)`, `core.state.add`, `core.state.remove`, `core.state.update`, `core.state.for_path`, `core.state.persist`, `render.render` (Task 1).
- Produces:
  - `mode._add(core, bufnr, lnum, end_lnum, text)` → `comment|nil` — núcleo testeable sin UI. Resuelve `rel = core.git.rel_path(bufnr)`; si `nil`, no-op y devuelve `nil`. Clampea `lnum`/`end_lnum` a `[1, line_count]` y ordena (`lnum <= end_lnum`). Si `text` es `nil` o cadena vacía tras `vim.trim`, no-op y devuelve `nil`. Llama `core.state.add({ path=rel, lnum=lnum, end_lnum=end_lnum, text=text })`, luego `require("review.features.comments.render").render(core, bufnr)` y `core.state.persist()`. Devuelve el comentario creado.
  - `mode._delete_at(core, bufnr, lnum)` → `boolean` — busca en `core.state.for_path(rel)` el primer comentario cuyo rango `[lnum, end_lnum]` cubre `lnum` (clampeado), lo remueve con `core.state.remove(id)`, re-renderiza y persiste. `false` si no hay `rel` o no hay comentario en esa línea.
  - `mode._resolve_at(core, bufnr, lnum)` → `boolean` — mismo criterio de búsqueda; togglea `resolved` vía `core.state.update(id, { resolved = not c.resolved })`, re-renderiza y persiste. `false` si no hay `rel` o no hay comentario en esa línea.
  - `mode.toggle(core)` — togglea `_G.review_mode_active` (booleano, arranca `false`) y ajusta `vim.o.guicursor` (guarda el valor previo en un upvalue del módulo para poder restaurarlo al des-activar).
  - `mode.add_here(core, opts)` — usa `require("nui.popup")` para pedir texto sobre la línea (normal) o rango visual (`vim.fn.line("v")`/`vim.fn.line(".")`) del buffer actual; al confirmar (`<CR>` en modo normal dentro del popup, o keymap configurable en `opts`) llama `mode._add(core, bufnr, lnum, end_lnum, texto_del_popup)` y cierra el popup.
  - `mode.delete_here(core)` — `mode._delete_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))`.
  - `mode.resolve_here(core)` — `mode._resolve_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))`.

- [ ] **Step 1: Test que falla — `tests/comments/mode_spec.lua`** (solo el núcleo testeable, sin nui)

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local mode = require("review.features.comments.mode")

local core = { state = state, git = git, ns = ns }

describe("comments.mode core", function()
  local root, bufnr

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    store.root_fn = function() return root end
    state._reset()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. "/foo.ts")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "l1", "l2", "l3", "l4", "l5" })
  end)

  it("_add agrega, renderiza y persiste", function()
    local c = mode._add(core, bufnr, 2, 2, "revisar esto")
    assert.is_truthy(c)
    assert.are.equal(1, #state.for_path("foo.ts"))
    state._reset(); state.load()
    assert.are.equal(1, #state.for_path("foo.ts"))
  end)

  it("_add es no-op si el buffer está fuera del repo", function()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(other, "/fuera/x.ts")
    local c = mode._add(core, other, 1, 1, "algo")
    assert.is_nil(c)
  end)

  it("_add es no-op si el texto es vacío", function()
    local c = mode._add(core, bufnr, 1, 1, "   ")
    assert.is_nil(c)
    assert.are.equal(0, #state.for_path("foo.ts"))
  end)

  it("_add clampea lnum fuera de rango", function()
    local c = mode._add(core, bufnr, 999, 999, "fuera de rango")
    assert.are.equal(5, c.lnum)
    assert.are.equal(5, c.end_lnum)
  end)

  it("_delete_at borra el comentario que cubre la línea", function()
    local c = mode._add(core, bufnr, 3, 3, "borrar")
    assert.is_true(mode._delete_at(core, bufnr, 3))
    assert.is_nil(state.by_id(c.id))
  end)

  it("_delete_at devuelve false si no hay comentario en la línea", function()
    assert.is_false(mode._delete_at(core, bufnr, 1))
  end)

  it("_resolve_at togglea resolved", function()
    local c = mode._add(core, bufnr, 4, 4, "resolver")
    assert.is_true(mode._resolve_at(core, bufnr, 4))
    assert.is_true(state.by_id(c.id).resolved)
    assert.is_true(mode._resolve_at(core, bufnr, 4))
    assert.is_false(state.by_id(c.id).resolved)
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/mode_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.comments.mode' not found").

- [ ] **Step 3: Implementar `lua/review/features/comments/mode.lua`**

```lua
local render = require("review.features.comments.render")

local M = {}
local saved_guicursor = nil

local function clamp(bufnr, lnum)
  local last = vim.api.nvim_buf_line_count(bufnr)
  if last < 1 then return 1 end
  if lnum < 1 then return 1 end
  if lnum > last then return last end
  return lnum
end

local function find_at(core, rel, lnum)
  for _, c in ipairs(core.state.for_path(rel)) do
    local lo = math.min(c.lnum, c.end_lnum or c.lnum)
    local hi = math.max(c.lnum, c.end_lnum or c.lnum)
    if lnum >= lo and lnum <= hi then return c end
  end
  return nil
end

function M._add(core, bufnr, lnum, end_lnum, text)
  local rel = core.git.rel_path(bufnr)
  if not rel then return nil end

  if text == nil or vim.trim(text) == "" then return nil end

  lnum = clamp(bufnr, lnum or 1)
  end_lnum = clamp(bufnr, end_lnum or lnum)
  if end_lnum < lnum then
    lnum, end_lnum = end_lnum, lnum
  end

  local c = core.state.add({ path = rel, lnum = lnum, end_lnum = end_lnum, text = text })
  render.render(core, bufnr)
  core.state.persist()
  return c
end

function M._delete_at(core, bufnr, lnum)
  local rel = core.git.rel_path(bufnr)
  if not rel then return false end

  lnum = clamp(bufnr, lnum)
  local c = find_at(core, rel, lnum)
  if not c then return false end

  local ok = core.state.remove(c.id)
  render.render(core, bufnr)
  core.state.persist()
  return ok
end

function M._resolve_at(core, bufnr, lnum)
  local rel = core.git.rel_path(bufnr)
  if not rel then return false end

  lnum = clamp(bufnr, lnum)
  local c = find_at(core, rel, lnum)
  if not c then return false end

  local ok = core.state.update(c.id, { resolved = not c.resolved })
  render.render(core, bufnr)
  core.state.persist()
  return ok
end

function M.toggle(core)
  _G.review_mode_active = not _G.review_mode_active
  if _G.review_mode_active then
    saved_guicursor = vim.o.guicursor
    vim.o.guicursor = "a:blinkon0-Cursor/lCursor"
  else
    vim.o.guicursor = saved_guicursor or vim.o.guicursor
  end
end

function M.add_here(core, opts)
  opts = opts or {}
  local Popup = require("nui.popup")
  local bufnr = vim.api.nvim_get_current_buf()

  local mode_v = vim.fn.mode()
  local lnum, end_lnum
  if mode_v == "v" or mode_v == "V" or mode_v == "\22" then
    lnum = vim.fn.line("v")
    end_lnum = vim.fn.line(".")
    vim.cmd("normal! \27")
  else
    lnum = vim.fn.line(".")
    end_lnum = lnum
  end

  local popup = Popup({
    enter = true,
    focusable = true,
    border = { style = "rounded", text = { top = " Comentario " } },
    position = "50%",
    size = { width = 60, height = 5 },
    buf_options = { filetype = "markdown" },
  })

  popup:mount()

  local function confirm()
    local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
    local text = table.concat(lines, "\n")
    popup:unmount()
    M._add(core, bufnr, lnum, end_lnum, text)
  end

  local function cancel()
    popup:unmount()
  end

  popup:map("n", opts.confirm_key or "<CR>", confirm, { noremap = true })
  popup:map("n", opts.cancel_key or "<Esc>", cancel, { noremap = true })
end

function M.delete_here(core)
  return M._delete_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

function M.resolve_here(core)
  return M._resolve_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/mode_spec.lua" -c "qa"`
Expected: PASS (7).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): mode con nucleo testeable _add/_delete_at/_resolve_at + popup nui"
```

---

### Task 3: `commands.lua` — comandos, alias y keymaps

**Files:**
- Create: `lua/review/features/comments/commands.lua`, `tests/comments/commands_spec.lua`

**Interfaces:**
- Consumes: `mode.toggle`, `mode.add_here`, `mode.delete_here`, `mode.resolve_here` (Task 2), `core.state.all` y `core.git.root` (para `:ReviewList`).
- Produces: `commands.setup(core, opts)` — registra:
  - `:ReviewCommentMode` y alias `:Rcm` (ambos comandos reales) → `mode.toggle(core)`.
  - `:ReviewList` y alias `:Rl` (ambos comandos reales) → abre quickfix con `core.state.all()` (uno por comentario: `filename` = **ruta absoluta** `core.git.root().."/"..path`, `lnum`, `text` con prefijo `[✓] ` si `resolved`).
  - Keymaps con prefijo `opts.leader or "<leader>r"`: `<leader>rr` (toggle, normal), `<leader>rc` (add_here, normal y visual), `<leader>rd` (delete_here, normal), `<leader>rx` (resolve_here, normal).

- [ ] **Step 1: Test que falla — `tests/comments/commands_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local commands = require("review.features.comments.commands")

local core = { state = state, git = git, ns = ns }

describe("comments.commands", function()
  before_each(function()
    local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
  end)

  it("registra :ReviewCommentMode y :Rcm", function()
    commands.setup(core, { leader = "<leader>r" })
    assert.is_not_nil(vim.api.nvim_get_commands({})["ReviewCommentMode"])
    assert.is_true(vim.fn.exists(":Rcm") == 2)
  end)

  it("registra :ReviewList y :Rl", function()
    commands.setup(core, { leader = "<leader>r" })
    assert.is_not_nil(vim.api.nvim_get_commands({})["ReviewList"])
    assert.is_true(vim.fn.exists(":Rl") == 2)
  end)

  it(":ReviewList llena la quickfix con los comentarios", function()
    state.add({ path = "a.ts", lnum = 3, text = "revisar" })
    commands.setup(core, { leader = "<leader>r" })
    vim.cmd("ReviewList")
    local qf = vim.fn.getqflist()
    assert.are.equal(1, #qf)
    assert.are.equal(3, qf[1].lnum)
  end)

  it("mapea <leader>rr en modo normal", function()
    commands.setup(core, { leader = "<leader>r" })
    local maps = vim.api.nvim_get_keymap("n")
    local found = false
    for _, m in ipairs(maps) do
      if m.lhs == "<leader>rr" then found = true end
    end
    assert.is_true(found)
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/commands_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.comments.commands' not found").

- [ ] **Step 3: Implementar `lua/review/features/comments/commands.lua`**

```lua
local mode = require("review.features.comments.mode")

local M = {}

local function open_quickfix(core)
  -- Ruta ABSOLUTA: la quickfix resuelve `filename` contra el cwd, pero
  -- `c.path` es relativo a la raíz del repo. Sin esto, abrir nvim desde un
  -- subdirectorio abriría el archivo equivocado.
  local root = core.git.root() or ""
  local base = (root ~= "") and (root .. "/") or ""
  local items = {}
  for _, c in ipairs(core.state.all()) do
    local prefix = c.resolved and "[✓] " or ""
    table.insert(items, {
      filename = base .. c.path,
      lnum = c.lnum,
      text = prefix .. (c.text or ""),
    })
  end
  vim.fn.setqflist(items)
  vim.cmd("copen")
end

function M.setup(core, opts)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"

  local function toggle() mode.toggle(core) end
  local function list() open_quickfix(core) end

  -- Comando largo + alias corto (ambos comandos REALES). La versión en
  -- minúscula (`rcm`/`rl`) la resuelve `plugin/review.lua` (core Task 7)
  -- vía cnoreabbrev apuntando a estos comandos reales.
  vim.api.nvim_create_user_command("ReviewCommentMode", toggle, {})
  vim.api.nvim_create_user_command("Rcm", toggle, {})
  vim.api.nvim_create_user_command("ReviewList", list, {})
  vim.api.nvim_create_user_command("Rl", list, {})

  vim.keymap.set("n", leader .. "r", function() mode.toggle(core) end, { desc = "Review: toggle comment mode" })
  vim.keymap.set("n", leader .. "c", function() mode.add_here(core, {}) end, { desc = "Review: add comment" })
  vim.keymap.set("v", leader .. "c", function() mode.add_here(core, {}) end, { desc = "Review: add comment (range)" })
  vim.keymap.set("n", leader .. "d", function() mode.delete_here(core) end, { desc = "Review: delete comment here" })
  vim.keymap.set("n", leader .. "x", function() mode.resolve_here(core) end, { desc = "Review: resolve comment here" })
end

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/commands_spec.lua" -c "qa"`
Expected: PASS (4).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): comandos ReviewCommentMode/ReviewList + keymaps"
```

---

### Task 4: `init.lua` — autocmds + registro en `core.registry`

**Files:**
- Create: `lua/review/features/comments/init.lua`, `tests/comments/init_spec.lua`

**Interfaces:**
- Consumes: `render.render`, `render.sync_positions` (Task 1), `commands.setup` (Task 3), `core.registry.register` (contrato del core, `00-core.md` Task 1/6).
- Produces: `M.setup(core, opts)` — registra autocmds `BufReadPost`/`BufEnter` → `render.render(core, bufnr)`; `BufWritePost` → `render.sync_positions(core, bufnr)` seguido de `core.state.persist()`. Llama `commands.setup(core, opts)`. Al final del archivo (fuera de `setup`, a nivel de módulo): `require("review.core").registry.register({ name = "comments", setup = M.setup })`.

- [ ] **Step 1: Test que falla — `tests/comments/init_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")

package.loaded["review.features.comments.init"] = nil
local comments = require("review.features.comments.init")

local core = { state = state, git = git, ns = ns }

describe("comments.init", function()
  local root, bufnr

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    store.root_fn = function() return root end
    state._reset()
    bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, root .. "/foo.ts")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "l1", "l2", "l3" })
  end)

  it("se auto-registra en review.core.registry con name=comments", function()
    local core_mod = require("review.core")
    local feats = core_mod.registry.features()
    assert.is_not_nil(feats.comments)
    assert.are.equal(comments.setup, feats.comments.setup)
  end)

  it("setup registra comandos y autocmds sin errores", function()
    assert.has_no.errors(function() comments.setup(core, { leader = "<leader>r" }) end)
    assert.is_not_nil(vim.api.nvim_get_commands({})["ReviewCommentMode"])
  end)

  it("BufWritePost sincroniza posiciones y persiste", function()
    comments.setup(core, { leader = "<leader>r" })
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x" })
    require("review.features.comments.render").render(core, bufnr)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "nueva" })
    vim.cmd("silent! write! " .. vim.fn.fnameescape(vim.api.nvim_buf_get_name(bufnr)))
    vim.wait(50)
    assert.are.equal(3, state.by_id(c.id).lnum)
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/init_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.comments.init' not found").

- [ ] **Step 3: Implementar `lua/review/features/comments/init.lua`**

```lua
local render = require("review.features.comments.render")
local commands = require("review.features.comments.commands")

local M = {}

function M.setup(core, opts)
  opts = opts or {}

  local group = vim.api.nvim_create_augroup("ReviewComments", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = group,
    callback = function(args)
      render.render(core, args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      render.sync_positions(core, args.buf)
      core.state.persist()
    end,
  })

  commands.setup(core, opts)
end

require("review.core").registry.register({ name = "comments", setup = M.setup })

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/init_spec.lua" -c "qa"`
Expected: PASS (3).

- [ ] **Step 5: Suite completa de comments**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedDirectory tests/comments {minimal_init='tests/minimal_init.lua'}" -c "qa"`
Expected: PASS (render 6, mode 7, commands 4, init 3 = 20).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): autocmds de render/sync + auto-registro en core.registry"
```

---

## Self-Review

- **Cobertura del alcance pedido:** `render.lua` (render + sync_positions + `_extmark_id`) ✅ T1; `mode.lua` (`toggle`, `add_here` con nui, `delete_here`, `resolve_here`, núcleo testeable `_add`/`_delete_at`/`_resolve_at`) ✅ T2; `commands.lua` (`:ReviewCommentMode`/`:Rcm`, `:ReviewList`/`:Rl`, keymaps `<leader>rr/rc/rd/rx`, prefijo configurable) ✅ T3; `init.lua` (`setup(core, opts)`, autocmds `BufReadPost`/`BufEnter`/`BufWritePost`, `registry.register`) ✅ T4.
- **Edge cases cubiertos:** buffer fuera del repo (`rel_path` nil → no-op) en `render.render`, `render.sync_positions`, `mode._add/_delete_at/_resolve_at` (tests dedicados en T1 y T2); `lnum`/`end_lnum` clampeados a `[1, line_count]` vía `clamp()` local en `render.lua` y `mode.lua` (test "clampea lnum fuera de rango" en T2); `_extmark_id` nunca se persiste (delegado a `state.persist`, ya filtrado en `00-core.md` Task 5, y verificado indirectamente por el round-trip de T2 Step 1); sin comentarios → `render.render` y `mode._delete_at/_resolve_at` no rompen (tests "no crea nada..." en T1 y "devuelve false si no hay comentario..." en T2).
- **Placeholders:** ninguno — todo el código Lua de cada step de implementación está completo y es ejecutable.
- **Consistencia de firmas con el contrato del core (`00-core.md`):** `core.git.rel_path(bufnr)`, `core.state.for_path(relpath)`, `core.state.add(comment)`, `core.state.remove(id)`, `core.state.update(id, fields)`, `core.state.by_id(id)`, `core.state.all()`, `core.state.persist()`, `core.ns.comments`, `core.registry.register({ name, setup })` se usan exactamente con esas firmas, sin inventar parámetros nuevos. `mode.lua` y `render.lua` reciben siempre `core` como primer argumento (nunca hacen `require("review.core")` directamente salvo `init.lua`, que sí puede porque es el punto de entrada de la feature y solo lo usa para `registry.register`).
- **Dependencia entre features:** ningún archivo de este plan hace `require("review.features.<otra>")`; toda coordinación futura (p.ej. `sidebar`) pasaría por `core.events` (`comments:changed`, ya emitido por `core.state` según el contrato), no implementada aquí porque no es responsabilidad de este slice.
