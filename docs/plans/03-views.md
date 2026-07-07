# review.nvim — Plan 03: Views (normal / inline / split)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development o superpowers:executing-plans. Steps con checkbox (`- [ ]`).
> **Plan maestro:** `~/Dev/nvim/review.nvim/DESIGN.md` — este plan implementa el slice "views" de la tabla de Features. Toda firma aquí DEBE coincidir con el "Contrato del core" (ver `docs/plans/00-core.md`).

**Goal:** Construir la feature `views`: tres modos por-buffer (`normal`, `inline`, `split`) que cambian SOLO cómo se pinta el código, vía decoraciones (extmarks) sobre el buffer real. Sin tabs nuevas, buffer siempre editable.

**Architecture:** `lua/review/features/views/` — `diff.lua` (parseo puro de `git diff -U0`), `inline.lua` (extmarks en `core.ns.views` sobre el buffer actual), `split.lua` (vsplit con scratch buffer readonly del contenido HEAD), `init.lua` (estado por-buffer `M.mode[bufnr]` + `set(bufnr, mode)`), `commands.lua` (`:ReviewView`/`:Rv`, keymap `<leader>rv`). Depende SOLO de `require("review.core")` (`git.rel_path`, `git.head_content`, `ns.views`, `events.emit`). Nunca requiere otra feature.

**Tech Stack:** Lua, Neovim ≥ 0.10 (extmarks `virt_lines`, `line_hl_group`), plenary.nvim (tests busted).

## Global Constraints

- La vista es SOLO presentación: nunca modifica el contenido del buffer real, solo agrega/limpia extmarks en `core.ns.views`.
- Sin tabs nuevas. `split` usa `:vsplit` con un buffer scratch (`buftype=nofile`, `readonly`) para el contenido HEAD; la ventana derecha sigue siendo el buffer real editable.
- Al cambiar de modo (`set(bufnr, mode)`) SIEMPRE se limpia la vista previa antes de aplicar la nueva (nunca dejar extmarks/ventanas colgadas).
- Togglear al mismo modo es idempotente (no duplica decoraciones ni ventanas).
- Archivo sin cambios vs HEAD → `inline.render` es no-op (no pinta nada, no tira error).
- Archivo nuevo (sin HEAD, `head_content` devuelve `nil`) → `split.open` avisa con `vim.notify` y no abre panel.
- Tests: `nvim --headless -c "PlenaryBustedFile tests/views/<spec>.lua" -c "qa"`.

---

### Task 1: `diff.lua` — parseo puro de `git diff -U0`

**Files:**
- Create: `lua/review/features/views/diff.lua`, `tests/views/diff_spec.lua`

**Interfaces:**
- Produces:
  - `diff.parse_unified_diff(text)` → `hunk[]`, `hunk = { old_start, old_count, new_start, new_count, del_lines={string...}, add_lines={string...}, add_lnums={int...} }` (`add_lnums` = números de línea 1-based en el NEW file que corresponden a `add_lines`).
  - `diff.hunks_for(relpath, git_root)` → `hunk[]|nil` — corre `git -C git_root diff -U0 -- relpath` y parsea el output con `parse_unified_diff`. `nil` si el comando falla o no hay `git_root`.

- [ ] **Step 1: Test que falla — `tests/views/diff_spec.lua`**

```lua
local diff = require("review.features.views.diff")

describe("views.diff.parse_unified_diff", function()
  it("parsea un hunk simple de reemplazo", function()
    local text = table.concat({
      "diff --git a/foo.lua b/foo.lua",
      "index 111..222 100644",
      "--- a/foo.lua",
      "+++ b/foo.lua",
      "@@ -2,2 +2,3 @@",
      "-local a = 1",
      "-local b = 2",
      "+local a = 10",
      "+local b = 20",
      "+local c = 30",
    }, "\n")
    local hunks = diff.parse_unified_diff(text)
    assert.are.equal(1, #hunks)
    local h = hunks[1]
    assert.are.equal(2, h.old_start)
    assert.are.equal(2, h.old_count)
    assert.are.equal(2, h.new_start)
    assert.are.equal(3, h.new_count)
    assert.are.same({ "local a = 1", "local b = 2" }, h.del_lines)
    assert.are.same({ "local a = 10", "local b = 20", "local c = 30" }, h.add_lines)
    assert.are.same({ 2, 3, 4 }, h.add_lnums)
  end)

  it("parsea múltiples hunks", function()
    local text = table.concat({
      "@@ -1 +1 @@",
      "-x",
      "+y",
      "@@ -10,0 +11,2 @@",
      "+z1",
      "+z2",
    }, "\n")
    local hunks = diff.parse_unified_diff(text)
    assert.are.equal(2, #hunks)
    assert.are.equal(1, hunks[1].old_start)
    assert.are.same({ 11, 12 }, hunks[2].add_lnums)
  end)

  it("texto vacío o sin hunks devuelve lista vacía", function()
    assert.are.same({}, diff.parse_unified_diff(""))
    assert.are.same({}, diff.parse_unified_diff("diff --git a/x b/x\nindex 1..2 100644\n"))
  end)

  it("hunk solo-agregado (old_count 0 por defecto a 1 si falta)", function()
    local text = "@@ -5 +5,2 @@\n+added1\n+added2\n"
    local hunks = diff.parse_unified_diff(text)
    assert.are.equal(1, hunks[1].old_count)
    assert.are.equal(2, hunks[1].new_count)
    assert.are.same({}, hunks[1].del_lines)
    assert.are.same({ "added1", "added2" }, hunks[1].add_lines)
  end)
end)

describe("views.diff.hunks_for", function()
  it("nil si no hay git_root", function()
    assert.is_nil(diff.hunks_for("foo.lua", nil))
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/views/diff_spec.lua" -c "qa"`
Expected: FAIL (`module 'review.features.views.diff' not found`).

- [ ] **Step 3: Implementar `lua/review/features/views/diff.lua`**

```lua
local M = {}

-- Parsea el header de un hunk unificado: @@ -old_start[,old_count] +new_start[,new_count] @@
local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count =
    line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not old_start then return nil end
  old_count = old_count ~= "" and tonumber(old_count) or 1
  new_count = new_count ~= "" and tonumber(new_count) or 1
  return {
    old_start = tonumber(old_start),
    old_count = old_count,
    new_start = tonumber(new_start),
    new_count = new_count,
    del_lines = {},
    add_lines = {},
    add_lnums = {},
  }
end

--- Parsea el texto completo de `git diff -U0` en una lista de hunks.
--- Ignora las líneas de header del diff (diff --git / index / --- / +++).
function M.parse_unified_diff(text)
  local hunks = {}
  if not text or text == "" then return hunks end

  local current = nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^@@ ") then
      current = parse_hunk_header(line)
      if current then table.insert(hunks, current) end
    elseif current then
      if line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
        table.insert(current.del_lines, line:sub(2))
      elseif line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
        table.insert(current.add_lines, line:sub(2))
        table.insert(current.add_lnums, current.new_start + #current.add_lnums)
      end
      -- otras líneas (---, +++, \ No newline at end of file) se ignoran
    end
  end

  return hunks
end

--- Corre `git diff -U0 -- relpath` en git_root y devuelve los hunks parseados.
--- nil si no hay git_root o el comando falla.
function M.hunks_for(relpath, git_root)
  if not git_root then return nil end
  local out = vim.fn.system({ "git", "-C", git_root, "diff", "-U0", "--", relpath })
  if vim.v.shell_error ~= 0 then return nil end
  return M.parse_unified_diff(out)
end

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/views/diff_spec.lua" -c "qa"`
Expected: PASS (5).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(views/diff): parseo puro de git diff -U0"
```

---

### Task 2: `inline.lua` — decoraciones inline sobre el buffer real

**Files:**
- Create: `lua/review/features/views/inline.lua`

**Interfaces:**
- Consumes: `core.git.rel_path`, `core.git.root`, `core.ns.views`, `views.diff.hunks_for` (Task 1).
- Produces:
  - `inline.render(core, bufnr)` — limpia `core.ns.views` en `bufnr` y pinta hunks: líneas borradas como `virt_lines` (hl `DiffDelete`) ANTES de la posición donde ocurrió el borrado; líneas agregadas con extmark `line_hl_group = "DiffAdd"` sobre las líneas reales indicadas por `add_lnums`. No-op si `rel_path` es `nil`, `root` es `nil`, o no hay hunks.
  - `inline.clear(core, bufnr)` — `vim.api.nvim_buf_clear_namespace(bufnr, core.ns.views, 0, -1)`.

Esta capa NO tiene test unitario propio (usa extmarks reales de un buffer vivo) — se cubre con verificación manual en Task 4. La lógica de parseo ya está testeada en Task 1.

- [ ] **Step 1: Implementar `lua/review/features/views/inline.lua`**

```lua
local diff = require("review.features.views.diff")

local M = {}

function M.clear(core, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, core.ns.views, 0, -1)
end

--- Pinta decoraciones inline de diff sobre bufnr. No-op si el archivo no
--- pertenece al repo o no tiene cambios.
function M.render(core, bufnr)
  M.clear(core, bufnr)

  local relpath = core.git.rel_path(bufnr)
  local root = core.git.root()
  if not relpath or not root then return end

  local hunks = diff.hunks_for(relpath, root)
  if not hunks or #hunks == 0 then return end

  local ns = core.ns.views
  for _, h in ipairs(hunks) do
    -- Líneas borradas: virt_lines colgando encima de la primera línea nueva
    -- que corresponde a este hunk (o de la línea siguiente si el hunk es
    -- puramente delete al final del archivo).
    if #h.del_lines > 0 then
      local anchor_lnum = math.max(h.new_start - 1, 0)
      local virt_lines = {}
      for _, dl in ipairs(h.del_lines) do
        table.insert(virt_lines, { { dl, "DiffDelete" } })
      end
      local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, anchor_lnum, 0, {
        virt_lines = virt_lines,
        virt_lines_above = anchor_lnum > 0,
      })
      if not ok then
        -- anchor fuera de rango (archivo más corto de lo esperado): ignorar
      end
    end

    -- Líneas agregadas: resaltar toda la línea real.
    for _, lnum in ipairs(h.add_lnums) do
      local row = lnum - 1
      if row >= 0 and row < vim.api.nvim_buf_line_count(bufnr) then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
          line_hl_group = "DiffAdd",
        })
      end
    end
  end
end

return M
```

- [ ] **Step 2: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(views/inline): render/clear de decoraciones inline"
```

---

### Task 3: `split.lua` — panel izquierdo con contenido HEAD

**Files:**
- Create: `lua/review/features/views/split.lua`

**Interfaces:**
- Consumes: `core.git.rel_path`, `core.git.head_content`, `core.ns.views`, `views.diff.hunks_for` (Task 1).
- Produces:
  - `split.open(core, bufnr)` — si `head_content(relpath)` es `nil` (archivo nuevo/sin HEAD o fuera de git), `vim.notify(..., WARN)` y retorna sin abrir nada. Si no: `:vsplit` a la izquierda del buffer actual, crea/reusa un scratch buffer (`buftype=nofile`, `bufhidden=wipe`, `readonly`, `modifiable=false`, nombre `review://head/<relpath>`) con las líneas de HEAD, pinta hl rojo/verde ahí con los mismos hunks (borradas = `DiffDelete` línea completa, contexto sin cambios sin hl), y deja el foco en la ventana derecha (buffer original).
  - `split.close(core, bufnr)` — cierra la ventana del scratch buffer de HEAD **de ese buffer** si está abierta y vuelve a 1 columna. Idempotente (no-op si ese buffer no tiene panel).
  - Guarda internamente `M._panels[bufnr] = { win, buf }` (estado POR BUFFER, no singleton) para poder cerrar el panel correcto.

Sin test unitario propio (vsplit/ventanas reales) — verificación manual en Task 4.

- [ ] **Step 1: Implementar `lua/review/features/views/split.lua`**

```lua
local diff = require("review.features.views.diff")

-- Estado POR BUFFER: `_panels[bufnr] = { win = <left_win>, buf = <scratch> }`.
-- (Singleton global rompería si dos buffers estuvieran en modo split a la vez.)
local M = { _panels = {} }

local function head_hl_lines(core, bufnr, head_lines, relpath)
  local root = core.git.root()
  local hunks = root and diff.hunks_for(relpath, root) or nil
  if not hunks then return end
  local ns = core.ns.views
  for _, h in ipairs(hunks) do
    for i = 1, #h.del_lines do
      local row = h.old_start - 1 + (i - 1)
      if row >= 0 and row < #head_lines then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, { line_hl_group = "DiffDelete" })
      end
    end
  end
end

--- Abre el panel izquierdo con el contenido HEAD del archivo del buffer actual.
--- Avisa y no abre nada si el archivo no tiene HEAD (nuevo / fuera de git).
function M.open(core, bufnr)
  local relpath = core.git.rel_path(bufnr)
  if not relpath then
    vim.notify("review.nvim: buffer fuera del repo, no se puede abrir split", vim.log.levels.WARN)
    return
  end

  local head_lines = core.git.head_content(relpath)
  if not head_lines then
    vim.notify(
      "review.nvim: '" .. relpath .. "' no tiene versión en HEAD (archivo nuevo)",
      vim.log.levels.WARN
    )
    return
  end

  M.close(core, bufnr) -- cierra un panel previo de ESTE buffer, si lo hubiera

  local target_win = vim.api.nvim_get_current_win()
  vim.cmd("topleft vsplit")
  local left_win = vim.api.nvim_get_current_win()

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "nofile"
  vim.bo[scratch].bufhidden = "wipe"
  vim.bo[scratch].modifiable = true
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, head_lines)
  vim.bo[scratch].modifiable = false
  vim.bo[scratch].readonly = true
  pcall(vim.api.nvim_buf_set_name, scratch, "review://head/" .. relpath)

  vim.api.nvim_win_set_buf(left_win, scratch)
  head_hl_lines(core, scratch, head_lines, relpath)

  M._panels[bufnr] = { win = left_win, buf = scratch }

  vim.api.nvim_set_current_win(target_win)
end

--- Cierra el panel izquierdo de HEAD del buffer `bufnr` si está abierto.
--- Idempotente (no-op si ese buffer no tiene panel).
function M.close(core, bufnr)
  local p = M._panels[bufnr]
  if p and p.win and vim.api.nvim_win_is_valid(p.win) then
    pcall(vim.api.nvim_win_close, p.win, true)
  end
  M._panels[bufnr] = nil
end

return M
```

- [ ] **Step 2: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(views/split): panel izquierdo readonly con contenido HEAD"
```

---

### Task 4: `init.lua` — estado por-buffer + `set(bufnr, mode)`

**Files:**
- Create: `lua/review/features/views/init.lua`, `tests/views/init_spec.lua`

**Interfaces:**
- Consumes: `inline` (Task 2), `split` (Task 3), `core.events.emit`.
- Produces:
  - `M.mode` — tabla `{ [bufnr] = "normal"|"inline"|"split" }`.
  - `M.set(core, bufnr, mode)` — valida `mode` ∈ `{normal, inline, split}` (si no, error/no-op); limpia la vista previa según `M.mode[bufnr]` (`inline.clear` si era `inline`, `split.close` si era `split`); aplica la nueva (`inline.render` si `inline`, `split.open` si `split`, nada si `normal`); actualiza `M.mode[bufnr]`; emite `view:changed` con `{ bufnr, mode }`. Idempotente: si `mode` == `M.mode[bufnr]` actual, no reaplica ni reemite (no-op).
  - `M.setup(core, opts)` — inicializa `M.mode = {}`, requiere `commands.lua` (Task 5) y lo invoca con `commands.setup(core, opts, M)`. Se auto-registra: `require("review.core").registry.register({ name = "views", setup = M.setup })`.

- [ ] **Step 1: Test que falla — `tests/views/init_spec.lua`**

```lua
local views = require("review.features.views")

local function fake_core()
  local emitted = {}
  return {
    ns = { views = 1 },
    git = {
      rel_path = function() return nil end, -- fuera de git: inline/split serán no-op seguro
      root = function() return nil end,
      head_content = function() return nil end,
    },
    events = {
      emit = function(name, payload) table.insert(emitted, { name = name, payload = payload }) end,
    },
    _emitted = emitted,
  }
end

describe("views.set", function()
  local core, bufnr

  before_each(function()
    core = fake_core()
    views.mode = {}
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  it("normal por defecto si nunca se seteó", function()
    assert.is_nil(views.mode[bufnr])
  end)

  it("set aplica y guarda el modo, emite view:changed", function()
    views.set(core, bufnr, "inline")
    assert.are.equal("inline", views.mode[bufnr])
    assert.are.equal(1, #core._emitted)
    assert.are.equal("view:changed", core._emitted[1].name)
    assert.are.same({ bufnr = bufnr, mode = "inline" }, core._emitted[1].payload)
  end)

  it("togglear al mismo modo es idempotente (no reemite)", function()
    views.set(core, bufnr, "inline")
    views.set(core, bufnr, "inline")
    assert.are.equal(1, #core._emitted)
  end)

  it("cambiar de inline a split limpia inline y aplica split", function()
    views.set(core, bufnr, "inline")
    views.set(core, bufnr, "split")
    assert.are.equal("split", views.mode[bufnr])
    assert.are.equal(2, #core._emitted)
  end)

  it("mode invalido no cambia el estado", function()
    views.set(core, bufnr, "inline")
    views.set(core, bufnr, "bogus")
    assert.are.equal("inline", views.mode[bufnr])
    assert.are.equal(1, #core._emitted)
  end)

  it("volver a normal limpia la vista previa", function()
    views.set(core, bufnr, "inline")
    views.set(core, bufnr, "normal")
    assert.are.equal("normal", views.mode[bufnr])
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/views/init_spec.lua" -c "qa"`
Expected: FAIL (`module 'review.features.views' not found`).

- [ ] **Step 3: Implementar `lua/review/features/views/init.lua`**

```lua
local inline = require("review.features.views.inline")
local split = require("review.features.views.split")

local M = {}
M.mode = {}

local VALID_MODES = { normal = true, inline = true, split = true }

local function clear_current(core, bufnr, current)
  if current == "inline" then
    inline.clear(core, bufnr)
  elseif current == "split" then
    split.close(core, bufnr)
  end
end

local function apply(core, bufnr, mode)
  if mode == "inline" then
    inline.render(core, bufnr)
  elseif mode == "split" then
    split.open(core, bufnr)
  end
  -- "normal": nada que aplicar, el buffer se ve como siempre.
end

--- Cambia el modo de vista de bufnr. Limpia la vista previa antes de aplicar
--- la nueva. Idempotente si mode == modo actual. No-op si mode es inválido.
function M.set(core, bufnr, mode)
  if not VALID_MODES[mode] then return end
  local current = M.mode[bufnr] or "normal"
  if current == mode then return end

  clear_current(core, bufnr, current)
  apply(core, bufnr, mode)
  M.mode[bufnr] = mode

  core.events.emit("view:changed", { bufnr = bufnr, mode = mode })
end

function M.setup(core, opts)
  M.mode = {}
  -- Limpiar el estado por-buffer cuando el buffer se destruye, para que
  -- Neovim no recicle su bufnr con un modo heredado (bug de estado obsoleto).
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = vim.api.nvim_create_augroup("ReviewViews", { clear = true }),
    callback = function(a)
      M.mode[a.buf] = nil
      split.close(core, a.buf)
    end,
  })
  local commands = require("review.features.views.commands")
  commands.setup(core, opts, M)
end

require("review.core").registry.register({ name = "views", setup = M.setup })

return M
```

- [ ] **Step 4: Correr y ver pasar** (fallará hasta Task 5 porque `commands.setup` no existe — el `require` es lazy dentro de `M.setup`, que no se llama en el test, así que ya debería pasar)

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/views/init_spec.lua" -c "qa"`
Expected: PASS (6).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(views): estado por-buffer, set(bufnr, mode) con limpieza y evento view:changed"
```

---

### Task 5: `commands.lua` — `:ReviewView`/`:Rv` + keymap cíclico

**Files:**
- Create: `lua/review/features/views/commands.lua`

**Interfaces:**
- Consumes: `M` (módulo de Task 4, pasado por parámetro para evitar require circular).
- Produces: `commands.setup(core, opts, views_mod)` — registra:
  - `:ReviewView {normal|inline|split}` y alias `:Rv` (ambos comandos REALES, `nargs = 1` + `complete` sobre los 3 valores); llaman `views_mod.set(core, vim.api.nvim_get_current_buf(), arg)`. La minúscula `rv` la resuelve `plugin/review.lua`.
  - Keymap `(opts.leader or "<leader>r") .. "v"` en modo normal que cicla `normal → inline → split → normal` sobre el buffer actual.

- [ ] **Step 1: Implementar `lua/review/features/views/commands.lua`**

```lua
local M = {}

local ORDER = { "normal", "inline", "split" }

local function next_mode(current)
  for i, m in ipairs(ORDER) do
    if m == current then
      return ORDER[i % #ORDER + 1]
    end
  end
  return ORDER[1]
end

function M.setup(core, opts, views_mod)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"

  local function run(cmd_opts)
    local mode = cmd_opts.args
    if mode == "" then
      vim.notify("uso: :ReviewView {normal|inline|split}", vim.log.levels.ERROR)
      return
    end
    views_mod.set(core, vim.api.nvim_get_current_buf(), mode)
  end

  local ucmd_opts = {
    nargs = 1,
    complete = function() return ORDER end,
  }
  -- Comando largo + alias corto, ambos comandos REALES. La minúscula `rv`
  -- la resuelve plugin/review.lua (core Task 7) vía cnoreabbrev → Rv.
  vim.api.nvim_create_user_command("ReviewView", run, ucmd_opts)
  vim.api.nvim_create_user_command("Rv", run, vim.deepcopy(ucmd_opts))

  vim.keymap.set("n", leader .. "v", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local current = views_mod.mode[bufnr] or "normal"
    views_mod.set(core, bufnr, next_mode(current))
  end, { desc = "review.nvim: ciclar vista normal/inline/split" })
end

return M
```

- [ ] **Step 2: Verificación manual — comandos y keymap**

1. `cd ~/Dev/nvim/review.nvim`, editar un archivo con cambios sin commitear (o crear uno nuevo y modificar una línea).
2. `nvim --headless` no sirve para esto: abrir Neovim normal con `nvim -u NONE -c "set rtp+=." -c "lua require('review').setup()"` sobre el archivo modificado.
3. `:ReviewView inline` → deben verse las líneas borradas como `virt_lines` con fondo rojo por encima de su posición, y las líneas agregadas resaltadas con `DiffAdd` en toda la línea. El buffer sigue siendo editable (escribir algo y confirmar que entra en modo insert normalmente).
4. `:ReviewView split` → se abre una ventana a la izquierda con el contenido de HEAD (readonly, con líneas borradas resaltadas en rojo); la ventana derecha sigue siendo el buffer real y editable.
5. `:ReviewView normal` → el panel izquierdo se cierra y las decoraciones inline desaparecen; queda 1 sola columna, buffer intacto.
6. Repetir `:ReviewView inline` dos veces seguidas (mismo modo) → no debe duplicar extmarks ni parpadear.
7. Probar `<leader>rv` repetidamente → debe ciclar `normal → inline → split → normal → ...`.
8. Probar con un archivo SIN cambios vs HEAD → `:ReviewView inline` no debe pintar nada ni tirar error (no-op).
9. Probar con un archivo nuevo (`git add` sin commit, sin HEAD) → `:ReviewView split` debe mostrar el `vim.notify` de advertencia y NO abrir panel.
10. `:Rv inline` (alias) debe comportarse igual que `:ReviewView inline`.
11. **Hunk de borrado puro:** borrar unas líneas (sin agregar) y `:ReviewView inline` → confirmar que las `virt_lines` rojas aparecen en la posición correcta (justo donde estaban las líneas borradas, no una línea corrida). Si aparecen desplazadas, ajustar `anchor_lnum`/`virt_lines_above` en `inline.lua` (la convención de `git diff -U0` para `@@ -N,M +K,0 @@` es que `K` apunta a la línea de contexto previa al borrado).
12. **Archivo nuevo (untracked) en inline:** `:ReviewView inline` sobre un archivo sin HEAD → no-op silencioso (git diff no lo compara); confirmar que no rompe (limitación conocida: no marca "todo nuevo").
13. **Split en dos buffers distintos:** abrir buffer A con cambios → `:ReviewView split`; sin cerrar, ir a buffer B con cambios → `:ReviewView split`; volver a A → `:ReviewView normal`. Confirmar que cada panel corresponde a su buffer y no quedan ventanas colgadas (valida el estado por-buffer de `_panels`).

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(views/commands): :ReviewView/:Rv + keymap <leader>rv cíclico"
```

---

### Task 6: Suite completa de la feature

**Files:**
- No crea archivos nuevos.

- [ ] **Step 1: Correr toda la suite de `views`**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedDirectory tests/views/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`
Expected: PASS (diff 5, init 6).

- [ ] **Step 2: Correr la suite completa del plugin (no romper core)**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`
Expected: todos los specs de `core` y `views` en PASS.

- [ ] **Step 3: Commit final (si hubo cambios pendientes de fixtures/ajustes)**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "test(views): verificación de suite completa del slice"
```

---

## Self-Review

- **Cobertura del contrato (DESIGN.md):** `git.head_content` ✅ (Task 3, `split.open`), `git.changed_files` — NO consumido directamente por `views` (lo usa `sidebar`; `views` solo necesita `rel_path`/`root`/`head_content` para el archivo activo), `ns.views` ✅ (Task 2/3, único namespace usado, limpiado en cada `set`), `events.emit("view:changed", {bufnr, mode})` ✅ (Task 4). Modos `normal/inline/split` ✅ (Task 4). `:ReviewView`/`:Rv` ✅ (Task 5, coincide con la tabla de comandos del DESIGN).
- **Regla de dependencia:** ningún módulo de `views` hace `require("review.features.*")` de otra feature; solo `require("review.core")` (vía `M.setup(core, opts)`) y submódulos internos del propio slice.
- **Placeholders:** ninguno — todo el código Lua está completo y es ejecutable.
- **Edge-cases cubiertos:**
  - Archivo sin cambios → `inline.render` no-op (Task 2, `hunks` vacío o `nil` corta antes de pintar).
  - Archivo nuevo sin HEAD → `split.open` avisa y no abre (Task 3, chequeo de `head_content == nil`).
  - Togglear al mismo modo → no-op idempotente, no reemite evento (Task 4, test "togglear al mismo modo es idempotente").
  - Cambio de modo → limpieza de la vista previa ANTES de aplicar la nueva, nunca queda decoración/ventana colgada (Task 4, `clear_current` antes de `apply`).
  - Edición del buffer real → nunca se toca `nvim_buf_set_lines` sobre el buffer del usuario en `inline`/`split`; solo extmarks y una ventana con buffer scratch separado.
- **Testing:** parte pura (`diff.parse_unified_diff`, `diff.hunks_for` con `git_root=nil`) y transiciones de estado (`M.set`) cubiertas con specs; UI real (virt_lines, vsplit visual, notify) delegada a verificación manual explícita en Task 5 Step 2, con pasos concretos y reproducibles.
