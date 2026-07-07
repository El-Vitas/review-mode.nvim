# review.nvim — Plan 05: Agent (puente RPC + reconciliación AUTO)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development o superpowers:executing-plans. Steps con checkbox (`- [ ]`).
> **Diseño maestro:** `docs/roadmap.md` §1 (fuente de verdad, supera al plan 05 viejo) + "Contrato del core" en `docs/plans/00-core.md`. Toda firma del core citada aquí DEBE coincidir con `00-core.md`.

**Goal:** Que un agente externo (Claude Code, script, etc.) pueda **leer, comentar, responder,
resolver, actualizar y limpiar** comentarios de review sobre la MISMA instancia de Neovim que el
humano usa, hablando el RPC nativo de Neovim (`--remote-expr`), sin sockets propios. Y que cuando el
agente **edite código en disco** (con sus propias herramientas, FUERA de nvim), Neovim **recargue el
buffer y re-ancle los comentarios automáticamente**, sin pisar cambios sin guardar del humano.

**Architecture:** El código lo escribe el agente LIBREMENTE en disco; review.nvim NO edita código.
Solo los comentarios pasan por nvim (vía `core.state`, única fuente de verdad). El problema no es
"editar sin choques" (eso lo maneja el agente en disco), sino **enterarse del cambio en disco,
recargar el buffer con un PATCH mínimo (no `:edit!`) y dejar que los extmarks se re-anclen solos por
gravity**. Dos slices tocados:

- `features/comments/` — se extiende: capturar `anchor_text` al crear, marcar `stale`, distinguir
  autoría y threading en render/gutter/peek, filtros de lista por autor/respondido, y una
  `render.reconcile` que re-sincroniza posiciones + marca stale (reacciona a un evento, sin conocer
  al agente).
- `features/agent/` — nuevo: `reconcile.lua` (patch mínimo por diff, el CORAZÓN), `watch.lua`
  (watcher `vim.uv.fs_event` + debounce), `rpc.lua` (API serializable sobre `core.state`),
  `init.lua` (`_G.ReviewAgent`, `opts.enabled`, cablea el watcher). Deshabilitada por defecto.

**Coordinación entre slices = SOLO eventos** (regla dura del core): `agent/reconcile` emite
`buffer:reconciled {bufnr}`; `comments` se suscribe y re-sincroniza. Ninguno hace
`require("review.features.<otra>")`.

**Tech Stack:** Lua, Neovim ≥ 0.10 (`vim.diff` result_type=indices, `vim.uv.new_fs_event`,
`vim.json`, `v:servername`, `--remote-expr`), plenary.nvim (tests busted).

## Global Constraints

- **El código lo escribe el agente en disco, nunca review.nvim.** Este plan jamás llama
  `nvim_buf_set_lines` para "aplicar cambios del agente" salvo dentro de `reconcile.patch`, que
  copia disco→buffer como patch mínimo para preservar extmarks (no es editar, es recargar).
- Ninguna feature hace `require("review.features.<otra>")`. Solo `require("review.core")`.
  Coordinación = `core.events`.
- Nunca pisar cambios sin guardar: si `vim.bo[bufnr].modified`, `reconcile.patch` NO aplica y avisa.
- Todas las funciones expuestas al agente son **serializables**: reciben/devuelven `string` (JSON) o
  primitivos. `list()`/`get()` NUNCA incluyen `_extmark_id` (runtime).
- Toda mutación desde el agente (`add/reply/resolve/unresolve/update/delete/clean_resolved`) persiste
  inmediatamente (`core.state.persist()`).
- Feature **deshabilitada por defecto**: `_G.ReviewAgent` y el watcher solo se montan si
  `features.agent = { enabled = true }`.
- Los watchers `vim.uv.fs_event` se cierran en `BufWipeout`/`BufDelete` (sin fugas, como los demás
  caches — ver `performance.md`).
- Retro-compatibilidad del modelo: los campos nuevos (`reply_to`, `anchor_text`, `stale`) son
  opcionales; `state.persist` ya copia todo campo que no sea `_extmark_id`, así que persisten solos.
  JSON viejo sin esos campos sigue cargando (defaults en `nil`/`false`).
- Tests: `nvim --headless -c "PlenaryBustedFile tests/agent/<spec>.lua" -c "qa"`. Suite completa:
  `nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`.

---

### Task 1: `core.state` — helpers de threading (`replies`, `thread`) + round-trip de campos nuevos

**Files:**
- Modify: `lua/review/core/state.lua`
- Modify: `tests/core/state_spec.lua`

**Interfaces:**
- Consumes: `state.all()`, `state.by_id(id)` (ya existen).
- Produces:
  - `state.replies(id)` → `comment[]` — comentarios cuyo `reply_to == id`, en orden de inserción.
  - `state.thread(id)` → `comment[]` — `{ padre, ...replies }` (padre primero); `{}` si `id` no existe.
  - Confirmación (test) de que `reply_to`/`anchor_text`/`stale` sobreviven `persist()`/`load()`.

- [ ] **Step 1: Agregar tests al final de `tests/core/state_spec.lua`** (dentro del `describe` existente, o un `describe` nuevo)

```lua
describe("core.state threading + campos nuevos", function()
  before_each(function()
    local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
  end)

  it("replies(id) devuelve solo los hijos de ese comentario", function()
    local parent = state.add({ path = "a.ts", lnum = 1, text = "duda" })
    state.add({ path = "a.ts", lnum = 1, text = "respuesta 1", reply_to = parent.id, author = "agent" })
    state.add({ path = "a.ts", lnum = 1, text = "respuesta 2", reply_to = parent.id, author = "agent" })
    state.add({ path = "a.ts", lnum = 2, text = "otro top-level" })
    local r = state.replies(parent.id)
    assert.are.equal(2, #r)
    assert.are.equal("respuesta 1", r[1].text)
  end)

  it("thread(id) devuelve el padre seguido de sus replies", function()
    local parent = state.add({ path = "a.ts", lnum = 1, text = "duda" })
    state.add({ path = "a.ts", lnum = 1, text = "resp", reply_to = parent.id })
    local t = state.thread(parent.id)
    assert.are.equal(2, #t)
    assert.are.equal(parent.id, t[1].id)
  end)

  it("thread(id) inexistente devuelve lista vacía", function()
    assert.are.same({}, state.thread("no-existe"))
  end)

  it("reply_to/anchor_text/stale sobreviven persist + load", function()
    local p = state.add({ path = "a.ts", lnum = 3, text = "x", anchor_text = "const foo = 1" })
    state.add({ path = "a.ts", lnum = 3, text = "y", reply_to = p.id, author = "agent" })
    state.update(p.id, { stale = true })
    state.persist(); state._reset(); state.load()
    local loaded = state.by_id(p.id)
    assert.are.equal("const foo = 1", loaded.anchor_text)
    assert.is_true(loaded.stale)
    assert.are.equal(1, #state.replies(p.id))
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/core/state_spec.lua" -c "qa"`
Expected: FAIL (`attempt to call field 'replies' (a nil value)`).

- [ ] **Step 3: Implementar `replies`/`thread` en `lua/review/core/state.lua`** (agregar antes de `return M`)

```lua
--- Comentarios que responden a `id` (reply_to == id), en orden de inserción.
function M.replies(id)
  local out = {}
  for _, c in ipairs(list) do
    if c.reply_to == id then out[#out + 1] = c end
  end
  return out
end

--- Hilo completo de un comentario: el padre primero, luego sus respuestas.
--- Lista vacía si `id` no existe.
function M.thread(id)
  local parent = M.by_id(id)
  if not parent then return {} end
  local out = { parent }
  for _, c in ipairs(M.replies(id)) do out[#out + 1] = c end
  return out
end
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/core/state_spec.lua" -c "qa"`
Expected: PASS (los previos + 4 nuevos).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(core/state): helpers de threading (replies/thread) para comentarios del agente"
```

---

### Task 2: `comments` — capturar `anchor_text` al crear + `render.reconcile` (sync + stale)

**Files:**
- Modify: `lua/review/features/comments/mode.lua` (capturar `anchor_text` en `_add`)
- Modify: `lua/review/features/comments/render.lua` (agregar `render.reconcile`)
- Modify: `tests/comments/mode_spec.lua`
- Modify: `tests/comments/render_spec.lua`

**Interfaces:**
- Consumes: `core.git.rel_path`, `core.state.for_path`, `core.state.update`, `core.ns.comments`.
- Produces:
  - `mode._add(...)` ahora guarda `anchor_text` = texto de la línea `lnum` del buffer (o `""` si no
    hay). Es la malla de seguridad para detectar re-anclaje incierto (roadmap §1.3).
  - `render.reconcile(core, bufnr)` — corre `sync_positions` (ya existe) y luego, por cada comentario
    con `anchor_text`, marca `stale = true` si la línea actual del extmark ya NO contiene ese texto
    (o lo des-marca si volvió a coincidir). Re-renderiza. Pensada para llamarse tras un patch de disco.

- [ ] **Step 1: Test en `tests/comments/mode_spec.lua`** (agregar dentro del describe existente)

```lua
  it("_add captura anchor_text de la línea comentada", function()
    local c = mode._add(core, bufnr, 3, 3, "ojo con l3")
    assert.are.equal("l3", c.anchor_text)
  end)
```

- [ ] **Step 2: Test en `tests/comments/render_spec.lua`** (agregar dentro del describe existente)

```lua
  it("reconcile marca stale cuando la línea anclada ya no coincide", function()
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x", anchor_text = "l2" })
    render.render(core, bufnr)
    -- el agente reescribió esa línea en disco (simulamos el resultado en el buffer)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "TOTALMENTE DISTINTO" })
    render.reconcile(core, bufnr)
    assert.is_true(state.by_id(c.id).stale)
  end)

  it("reconcile des-marca stale si la línea vuelve a coincidir", function()
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x", anchor_text = "l2", stale = true })
    render.render(core, bufnr)
    render.reconcile(core, bufnr)  -- la línea 2 sigue siendo "l2"
    assert.is_false(state.by_id(c.id).stale)
  end)

  it("reconcile no marca stale si el comentario no tiene anchor_text", function()
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x" })
    render.render(core, bufnr)
    render.reconcile(core, bufnr)
    assert.is_nil(state.by_id(c.id).stale)
  end)
```

- [ ] **Step 3: Capturar `anchor_text` en `mode._add`** (`lua/review/features/comments/mode.lua`)

En `M._add`, justo antes de `local c = core.state.add({ ... })`, calcular el texto de la línea ancla
y pasarlo:

```lua
  local anchor_text = ""
  do
    local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
    anchor_text = lines[1] or ""
  end

  local c = core.state.add({ path = rel, lnum = lnum, end_lnum = end_lnum, text = text, anchor_text = anchor_text })
```

(reemplaza la línea `local c = core.state.add({ path = rel, lnum = lnum, end_lnum = end_lnum, text = text })`).

- [ ] **Step 4: Implementar `render.reconcile`** (`lua/review/features/comments/render.lua`, antes de `return M`)

```lua
--- Re-sincroniza posiciones desde los extmarks y marca `stale` los comentarios
--- cuya línea anclada dejó de coincidir con su `anchor_text` (malla de seguridad
--- tras un cambio de código en disco). Des-marca los que volvieron a coincidir.
--- No-op si el buffer está fuera del repo.
function M.reconcile(core, bufnr)
  local rel = core.git.rel_path(bufnr)
  if not rel then return end

  M.sync_positions(core, bufnr)

  local last = vim.api.nvim_buf_line_count(bufnr)
  for _, c in ipairs(core.state.for_path(rel)) do
    if c.anchor_text and c.anchor_text ~= "" then
      local row = (c.lnum or 1) - 1
      local now = ""
      if row >= 0 and row < last then
        now = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      end
      -- coincide si la línea actual contiene el texto ancla (tolerante a
      -- reindentación/espacios: comparamos trims).
      local matches = vim.trim(now) == vim.trim(c.anchor_text)
      if matches and c.stale then
        core.state.update(c.id, { stale = false })
      elseif not matches and not c.stale then
        core.state.update(c.id, { stale = true })
      end
    end
  end

  M.render(core, bufnr)
end
```

- [ ] **Step 5: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/mode_spec.lua" -c "qa" && nvim --headless -c "PlenaryBustedFile tests/comments/render_spec.lua" -c "qa"`
Expected: PASS (mode: previos + 1; render: previos + 3).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): capturar anchor_text al crear + render.reconcile (sync + marca stale)"
```

---

### Task 3: `agent/reconcile.lua` — patch mínimo por diff (EL CORAZÓN)

**Files:**
- Create: `lua/review/features/agent/reconcile.lua`, `tests/agent/reconcile_spec.lua`

**Interfaces:**
- Consumes: `core.git.rel_path`, `core.events.emit`.
- Produces:
  - `reconcile.patch(core, bufnr)` → `"applied"|"identical"|"conflict"|"skipped"` — lee el archivo del
    disco y aplica SOLO los hunks (`vim.diff` result_type=indices) al buffer con `nvim_buf_set_lines`
    de abajo hacia arriba, preservando los extmarks (se re-anclan solos por gravity). Deja el buffer
    `nomodified`. Si el buffer tiene cambios sin guardar (`modified`) → NO aplica, devuelve
    `"conflict"`. Si disco == buffer → `"identical"`. Fuera del repo / sin nombre / sin extmark →
    `"skipped"`. Tras aplicar, emite `buffer:reconciled { bufnr = bufnr }`.

- [ ] **Step 1: Test que falla — `tests/agent/reconcile_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local events = require("review.core.events")
local reconcile = require("review.features.agent.reconcile")

local core = { state = state, git = git, ns = ns, events = events }

local function write_file(path, lines)
  vim.fn.writefile(lines, path)
end

describe("agent.reconcile.patch", function()
  local root, path, bufnr

  before_each(function()
    root = vim.fn.tempname(); vim.fn.mkdir(root, "p")
    store.root_fn = function() return root end
    state._reset()
    events._reset()
    path = root .. "/foo.ts"
    write_file(path, { "l1", "l2", "l3", "l4", "l5" })
    bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].modified = false
  end)

  it("identical si disco == buffer", function()
    assert.are.equal("identical", reconcile.patch(core, bufnr))
  end)

  it("conflict si el buffer tiene cambios sin guardar", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "sin guardar" })
    assert.is_true(vim.bo[bufnr].modified)
    write_file(path, { "l1", "l2", "l3", "l4", "l5", "l6" })
    assert.are.equal("conflict", reconcile.patch(core, bufnr))
  end)

  it("applied: inserción arriba corre el extmark y queda nomodified", function()
    -- extmark de comentario en la línea 3 (row 2)
    local id = vim.api.nvim_buf_set_extmark(bufnr, ns.comments, 2, 0, {})
    -- el agente insertó una línea al principio en disco
    write_file(path, { "NUEVA", "l1", "l2", "l3", "l4", "l5" })
    assert.are.equal("applied", reconcile.patch(core, bufnr))
    -- el buffer refleja el disco
    assert.are.same(
      { "NUEVA", "l1", "l2", "l3", "l4", "l5" },
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    )
    -- el extmark bajó de row 2 a row 3 (gravity)
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns.comments, id, {})
    assert.are.equal(3, pos[1])
    assert.is_false(vim.bo[bufnr].modified)
  end)

  it("applied: modificación en el medio no mueve extmarks anteriores", function()
    local id = vim.api.nvim_buf_set_extmark(bufnr, ns.comments, 0, 0, {})
    write_file(path, { "l1", "l2", "l3-MOD", "l4", "l5" })
    assert.are.equal("applied", reconcile.patch(core, bufnr))
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns.comments, id, {})
    assert.are.equal(0, pos[1])
    assert.are.equal("l3-MOD", vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1])
  end)

  it("emite buffer:reconciled al aplicar", function()
    local fired = nil
    events.on("buffer:reconciled", function(p) fired = p.bufnr end)
    write_file(path, { "l1", "l2", "l3", "l4", "l5", "l6" })
    reconcile.patch(core, bufnr)
    vim.wait(50, function() return fired ~= nil end)
    assert.are.equal(bufnr, fired)
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/reconcile_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.agent.reconcile' not found").

- [ ] **Step 3: Implementar `lua/review/features/agent/reconcile.lua`**

```lua
local M = {}

--- Aplica el contenido de disco al buffer como PATCH mínimo (no `:edit!`), para
--- que los extmarks (y por lo tanto los comentarios anclados) se re-anclen solos
--- por gravity. Nunca pisa cambios sin guardar del humano.
--- @return "applied"|"identical"|"conflict"|"skipped"
function M.patch(core, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return "skipped" end
  local rel = core.git.rel_path(bufnr)
  if not rel then return "skipped" end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return "skipped" end

  -- Conflicto: hay ediciones sin guardar → NO pisar (ver roadmap §1.3.3).
  if vim.bo[bufnr].modified then return "conflict" end

  local ok, disk = pcall(vim.fn.readfile, name)
  if not ok or type(disk) ~= "table" then return "skipped" end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local a = table.concat(buf_lines, "\n")
  local b = table.concat(disk, "\n")
  if a == b then return "identical" end

  local hunks = vim.diff(a, b, { result_type = "indices" })
  if not hunks or #hunks == 0 then return "identical" end

  -- Aplicar de ABAJO hacia arriba para no invalidar los índices de los hunks
  -- superiores. Cada hunk = { start_a, count_a, start_b, count_b } (1-based en a
  -- y b; count==0 marca inserción/borrado puro con start = línea previa).
  for i = #hunks, 1, -1 do
    local h = hunks[i]
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]

    local repl = {}
    for j = start_b, start_b + count_b - 1 do
      repl[#repl + 1] = disk[j]
    end

    local s, e
    if count_a == 0 then
      -- inserción: `start_a` es la línea (1-based) DESPUÉS de la cual insertar;
      -- en 0-based eso es el índice `start_a` (set_lines(start_a, start_a, ...)).
      s = start_a
      e = start_a
    else
      s = start_a - 1
      e = start_a - 1 + count_a
    end
    vim.api.nvim_buf_set_lines(bufnr, s, e, false, repl)
  end

  vim.bo[bufnr].modified = false
  core.events.emit("buffer:reconciled", { bufnr = bufnr })
  return "applied"
end

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/reconcile_spec.lua" -c "qa"`
Expected: PASS (5).

- [ ] **Step 5: Suscribir `comments` a `buffer:reconciled`** (`lua/review/features/comments/init.lua`, dentro de `M.setup`, tras los autocmds existentes)

```lua
  -- El agente (o cualquiera) editó el archivo en disco y reconcile aplicó el
  -- patch al buffer; re-sincronizamos posiciones y marcamos stale los dudosos.
  core.events.on("buffer:reconciled", function(payload)
    if payload and payload.bufnr and vim.api.nvim_buf_is_valid(payload.bufnr) then
      render.reconcile(core, payload.bufnr)
    end
  end)
```

- [ ] **Step 6: Test de integración del evento — agregar a `tests/comments/init_spec.lua`**

```lua
  it("buffer:reconciled dispara render.reconcile y re-sincroniza posiciones", function()
    comments.setup(core, { leader = "<leader>r" })
    local events = require("review.core.events")
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x", anchor_text = "l2" })
    require("review.features.comments.render").render(core, bufnr)
    vim.api.nvim_set_current_buf(bufnr)
    -- simulamos que reconcile ya aplicó un patch: se insertó una línea arriba
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "nueva" })
    events.emit("buffer:reconciled", { bufnr = bufnr })
    vim.wait(50)
    assert.are.equal(3, state.by_id(c.id).lnum)  -- 2 -> 3
  end)
```

- [ ] **Step 7: Correr suite de comments + agent**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedDirectory tests/comments {minimal_init='tests/minimal_init.lua'}" -c "qa" && nvim --headless -c "PlenaryBustedFile tests/agent/reconcile_spec.lua" -c "qa"`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(agent): reconcile.patch (patch minimo por diff) + comments reacciona a buffer:reconciled"
```

---

### Task 4: `agent/watch.lua` — watcher de disco con debounce + limpieza

**Files:**
- Create: `lua/review/features/agent/watch.lua`
- Create: `tests/agent/watch_spec.lua`

**Interfaces:**
- Consumes: `reconcile.patch` (Task 3), `core.git.rel_path`.
- Produces:
  - `watch.attach(core, bufnr)` — si el buffer es un archivo del repo (`rel_path ~= nil`) y no tiene
    watcher, crea un `vim.uv.new_fs_event` sobre su archivo; en cada evento hace debounce (~150 ms) y
    corre `reconcile.patch(core, bufnr)` dentro de `vim.schedule` (las APIs de buffer no son seguras
    en el callback de libuv). Idempotente.
  - `watch.detach(bufnr)` — cierra y olvida el watcher del buffer. Idempotente.
  - `watch.detach_all()` — cierra todos (para tests / teardown).
  - `watch._debounce_ms` — sobrescribible en tests.

- [ ] **Step 1: Test que falla — `tests/agent/watch_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local events = require("review.core.events")
local watch = require("review.features.agent.watch")

local core = { state = state, git = git, ns = ns, events = events }

describe("agent.watch", function()
  local root, path, bufnr

  before_each(function()
    root = vim.fn.tempname(); vim.fn.mkdir(root, "p")
    store.root_fn = function() return root end
    state._reset(); events._reset()
    watch.detach_all()
    watch._debounce_ms = 30
    path = root .. "/foo.ts"
    vim.fn.writefile({ "l1", "l2", "l3" }, path)
    bufnr = vim.fn.bufadd(path); vim.fn.bufload(bufnr)
    vim.bo[bufnr].modified = false
  end)

  after_each(function() watch.detach_all() end)

  it("attach es no-op para buffers fuera del repo", function()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(other, "/fuera/x.ts")
    assert.has_no.errors(function() watch.attach(core, other) end)
    assert.is_false(watch._has(other))
  end)

  it("attach crea un watcher y detach lo cierra", function()
    watch.attach(core, bufnr)
    assert.is_true(watch._has(bufnr))
    watch.detach(bufnr)
    assert.is_false(watch._has(bufnr))
  end)

  it("al cambiar el archivo en disco, reconcilia el buffer (debounced)", function()
    watch.attach(core, bufnr)
    local reconciled = false
    events.on("buffer:reconciled", function() reconciled = true end)
    -- el agente escribe en disco
    vim.fn.writefile({ "l1", "l2", "l3", "l4" }, path)
    vim.wait(1000, function() return reconciled end)
    assert.is_true(reconciled)
    assert.are.same({ "l1", "l2", "l3", "l4" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/watch_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.agent.watch' not found").

- [ ] **Step 3: Implementar `lua/review/features/agent/watch.lua`**

```lua
local reconcile = require("review.features.agent.reconcile")

local uv = vim.uv or vim.loop

-- _watchers[bufnr] = { fs = <fs_event>, timer = <uv_timer|nil> }
local M = { _watchers = {}, _debounce_ms = 150 }

function M._has(bufnr)
  return M._watchers[bufnr] ~= nil
end

--- Corre reconcile.patch en el hilo principal (las APIs de buffer NO son seguras
--- dentro del callback de libuv).
local function run_patch(core, bufnr)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      reconcile.patch(core, bufnr)
    end
  end)
end

function M.attach(core, bufnr)
  if M._watchers[bufnr] then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local rel = core.git.rel_path(bufnr)
  if not rel then return end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return end

  local fs = uv.new_fs_event()
  if not fs then return end
  local entry = { fs = fs, timer = nil }
  M._watchers[bufnr] = entry

  local ok = pcall(function()
    fs:start(path, {}, function(err)
      if err then return end
      -- Debounce: agrupar ráfagas de escritura del agente en un solo patch.
      if entry.timer then
        entry.timer:stop()
        entry.timer:close()
        entry.timer = nil
      end
      local t = uv.new_timer()
      entry.timer = t
      t:start(M._debounce_ms, 0, function()
        t:stop(); t:close(); entry.timer = nil
        -- Algunos editores reemplazan el inode (rename); re-armar el watch.
        pcall(function() fs:stop() end)
        pcall(function() fs:start(path, {}, function() end) end)
        run_patch(core, bufnr)
      end)
    end)
  end)
  if not ok then
    M.detach(bufnr)
  end
end

function M.detach(bufnr)
  local entry = M._watchers[bufnr]
  if not entry then return end
  if entry.timer then pcall(function() entry.timer:stop(); entry.timer:close() end) end
  if entry.fs then pcall(function() entry.fs:stop(); entry.fs:close() end) end
  M._watchers[bufnr] = nil
end

function M.detach_all()
  for bufnr in pairs(M._watchers) do
    M.detach(bufnr)
  end
end

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/watch_spec.lua" -c "qa"`
Expected: PASS (3). (El watcher usa el filesystem real; el test escribe y espera hasta 1 s.)

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(agent/watch): watcher fs_event con debounce + limpieza sin fugas"
```

---

### Task 5: `agent/rpc.lua` — API serializable completa

**Files:**
- Create: `lua/review/features/agent/rpc.lua`, `tests/agent/rpc_spec.lua`

**Interfaces:**
- Consumes: `core.state.*`, `core.git.rel_path`/`head_content`/`root`, `reconcile.patch` (para
  `notify_changed`).
- Produces (todas serializables — reciben/devuelven string JSON o primitivos):
  - `rpc.list(core, filter_json?)` → `string` (JSON array). `filter` opcional:
    `{ author?, path?, resolved?, answered? }`. `answered` filtra por tener/no tener replies.
  - `rpc.get(core, id)` → `string` (JSON del comentario + `replies`), o `"null"`.
  - `rpc.context(core, id)` → `string` (JSON `{ comment, lines }` con las líneas de código que abarca,
    leídas del HEAD o del disco), o `"null"`.
  - `rpc.add(core, json_or_table)` → `string` (id, o `""`). `author` default `"agent"`.
  - `rpc.reply(core, parent_id, text)` → `string` (id de la respuesta, o `""` si el padre no existe).
  - `rpc.resolve(core, id)` / `rpc.unresolve(core, id)` → `boolean`.
  - `rpc.update(core, id, text)` → `boolean`.
  - `rpc.delete(core, id)` → `boolean`.
  - `rpc.clean_resolved(core, path?)` → `number` (cuántos borró).
  - `rpc.is_modified(core, path)` → `boolean` (¿hay un buffer de ese path con cambios sin guardar?).
  - `rpc.notify_changed(core, path)` → `boolean` (fuerza `reconcile.patch` del buffer de ese path si
    está abierto; `false` si no está abierto o hubo conflicto).

- [ ] **Step 1: Test que falla — `tests/agent/rpc_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local events = require("review.core.events")
local rpc = require("review.features.agent.rpc")

local core = { state = state, git = git, ns = ns, events = events }

describe("features.agent.rpc", function()
  local root
  before_each(function()
    root = vim.fn.tempname(); vim.fn.mkdir(root, "p")
    store.root_fn = function() return root end
    state._reset(); events._reset()
  end)

  it("list() sin comentarios devuelve []", function()
    assert.are.equal("[]", rpc.list(core))
  end)

  it("list() excluye _extmark_id", function()
    local c = state.add({ path = "a.ts", lnum = 1, text = "x" }); c._extmark_id = 7
    local d = vim.json.decode(rpc.list(core))
    assert.is_nil(d[1]._extmark_id)
  end)

  it("list(filter) filtra por author y por answered", function()
    local p = state.add({ path = "a.ts", lnum = 1, text = "mío", author = "user" })
    state.add({ path = "a.ts", lnum = 1, text = "resp", author = "agent", reply_to = p.id })
    state.add({ path = "a.ts", lnum = 2, text = "sin resp", author = "user" })

    local mine = vim.json.decode(rpc.list(core, vim.json.encode({ author = "user" })))
    assert.are.equal(2, #mine)
    local answered = vim.json.decode(rpc.list(core, vim.json.encode({ answered = true })))
    assert.are.equal(1, #answered)
    assert.are.equal(p.id, answered[1].id)
    local unanswered = vim.json.decode(rpc.list(core, vim.json.encode({ author = "user", answered = false })))
    assert.are.equal(1, #unanswered)
  end)

  it("add() valida y devuelve id; author default agent", function()
    local id = rpc.add(core, { path = "b.ts", lnum = 3, text = "desde agente" })
    assert.is_not.equal("", id)
    assert.are.equal("agent", state.by_id(id).author)
  end)

  it("add() con JSON inválido devuelve ''", function()
    assert.are.equal("", rpc.add(core, "{ roto"))
  end)

  it("reply() liga al padre y hereda su path/lnum", function()
    local p = state.add({ path = "a.ts", lnum = 5, text = "duda" })
    local rid = rpc.reply(core, p.id, "porque X")
    local r = state.by_id(rid)
    assert.are.equal(p.id, r.reply_to)
    assert.are.equal("a.ts", r.path)
    assert.are.equal(5, r.lnum)
    assert.are.equal("agent", r.author)
  end)

  it("reply() con padre inexistente devuelve ''", function()
    assert.are.equal("", rpc.reply(core, "no-existe", "x"))
  end)

  it("get() devuelve el comentario con sus replies", function()
    local p = state.add({ path = "a.ts", lnum = 1, text = "duda" })
    rpc.reply(core, p.id, "resp")
    local g = vim.json.decode(rpc.get(core, p.id))
    assert.are.equal("duda", g.text)
    assert.are.equal(1, #g.replies)
  end)

  it("resolve/unresolve/update/delete", function()
    local c = state.add({ path = "a.ts", lnum = 1, text = "x" })
    assert.is_true(rpc.resolve(core, c.id));   assert.is_true(state.by_id(c.id).resolved)
    assert.is_true(rpc.unresolve(core, c.id)); assert.is_false(state.by_id(c.id).resolved)
    assert.is_true(rpc.update(core, c.id, "nuevo texto")); assert.are.equal("nuevo texto", state.by_id(c.id).text)
    assert.is_true(rpc.delete(core, c.id));    assert.is_nil(state.by_id(c.id))
  end)

  it("clean_resolved borra los resueltos y devuelve el conteo", function()
    state.add({ path = "a.ts", lnum = 1, text = "abierto" })
    local r = state.add({ path = "a.ts", lnum = 2, text = "cerrado", resolved = true })
    assert.are.equal(1, rpc.clean_resolved(core))
    assert.is_nil(state.by_id(r.id))
    assert.are.equal(1, #state.all())
  end)

  it("is_modified refleja el estado del buffer", function()
    local path = root .. "/m.ts"
    vim.fn.writefile({ "a" }, path)
    local b = vim.fn.bufadd(path); vim.fn.bufload(b); vim.bo[b].modified = false
    assert.is_false(rpc.is_modified(core, "m.ts"))
    vim.api.nvim_buf_set_lines(b, 0, 0, false, { "x" })
    assert.is_true(rpc.is_modified(core, "m.ts"))
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/rpc_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.agent.rpc' not found").

- [ ] **Step 3: Implementar `lua/review/features/agent/rpc.lua`**

```lua
local reconcile = require("review.features.agent.reconcile")

local M = {}

local function clean(c)
  local copy = {}
  for k, v in pairs(c) do
    if k ~= "_extmark_id" then copy[k] = v end
  end
  return copy
end

local function decode_maybe(x)
  if type(x) == "string" then
    local ok, d = pcall(vim.json.decode, x)
    if not ok then return nil end
    return d
  end
  return x
end

--- Busca el bufnr abierto para un relpath (o nil).
local function buf_for_path(core, relpath)
  local root = core.git.root()
  if not root then return nil end
  local full = root:gsub("/$", "") .. "/" .. relpath
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == full then
      return b
    end
  end
  return nil
end

function M.list(core, filter_json)
  local filter = decode_maybe(filter_json) or {}
  local out = {}
  for _, c in ipairs(core.state.all()) do
    local ok = true
    if filter.author ~= nil and c.author ~= filter.author then ok = false end
    if filter.path ~= nil and c.path ~= filter.path then ok = false end
    if filter.resolved ~= nil and (not not c.resolved) ~= filter.resolved then ok = false end
    if filter.answered ~= nil then
      local answered = #core.state.replies(c.id) > 0
      if answered ~= filter.answered then ok = false end
    end
    if ok then out[#out + 1] = clean(c) end
  end
  if #out == 0 then return "[]" end
  return vim.json.encode(out)
end

function M.get(core, id)
  local c = core.state.by_id(id)
  if not c then return "null" end
  local obj = clean(c)
  obj.replies = {}
  for _, r in ipairs(core.state.replies(id)) do obj.replies[#obj.replies + 1] = clean(r) end
  return vim.json.encode(obj)
end

function M.context(core, id)
  local c = core.state.by_id(id)
  if not c then return "null" end
  local lines = {}
  -- Preferimos el contenido del buffer abierto; si no, disco; si no, HEAD.
  local b = buf_for_path(core, c.path)
  if b then
    lines = vim.api.nvim_buf_get_lines(b, (c.lnum or 1) - 1, (c.end_lnum or c.lnum), false)
  else
    local root = core.git.root()
    local full = root and (root:gsub("/$", "") .. "/" .. c.path) or nil
    local ok, disk = false, nil
    if full then ok, disk = pcall(vim.fn.readfile, full) end
    if ok and disk then
      for i = (c.lnum or 1), (c.end_lnum or c.lnum) do lines[#lines + 1] = disk[i] or "" end
    end
  end
  return vim.json.encode({ comment = clean(c), lines = lines })
end

function M.add(core, json_or_table)
  local data = decode_maybe(json_or_table)
  if type(data) ~= "table" or not data.path or not data.lnum or not data.text then return "" end
  data.author = data.author or "agent"
  local c = core.state.add(data)
  core.state.persist()
  return c.id
end

function M.reply(core, parent_id, text)
  local parent = core.state.by_id(parent_id)
  if not parent or not text or vim.trim(text) == "" then return "" end
  local c = core.state.add({
    path = parent.path,
    lnum = parent.lnum,
    end_lnum = parent.end_lnum,
    text = text,
    author = "agent",
    reply_to = parent_id,
  })
  core.state.persist()
  return c.id
end

local function set_resolved(core, id, value)
  local ok = core.state.update(id, { resolved = value })
  if ok then core.state.persist() end
  return ok
end

function M.resolve(core, id) return set_resolved(core, id, true) end
function M.unresolve(core, id) return set_resolved(core, id, false) end

function M.update(core, id, text)
  if not text then return false end
  local ok = core.state.update(id, { text = text })
  if ok then core.state.persist() end
  return ok
end

function M.delete(core, id)
  local ok = core.state.remove(id)
  if ok then core.state.persist() end
  return ok
end

function M.clean_resolved(core, path)
  local ids = {}
  for _, c in ipairs(core.state.all()) do
    if c.resolved and (path == nil or c.path == path) then ids[#ids + 1] = c.id end
  end
  for _, id in ipairs(ids) do core.state.remove(id) end
  if #ids > 0 then core.state.persist() end
  return #ids
end

function M.is_modified(core, path)
  local b = buf_for_path(core, path)
  if not b then return false end
  return vim.bo[b].modified
end

function M.notify_changed(core, path)
  local b = buf_for_path(core, path)
  if not b then return false end
  return reconcile.patch(core, b) == "applied"
end

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/rpc_spec.lua" -c "qa"`
Expected: PASS (11).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(agent/rpc): API serializable completa (list/get/context/add/reply/resolve/update/delete/clean/is_modified/notify_changed)"
```

---

### Task 6: `agent/init.lua` — `_G.ReviewAgent`, `opts.enabled`, cablear watcher

**Files:**
- Create: `lua/review/features/agent/init.lua`, `tests/agent/init_spec.lua`

**Interfaces:**
- Consumes: `rpc` (Task 5), `watch` (Task 4), `core.registry.register`.
- Produces: `M.setup(core, opts)` — si `opts.enabled` es truthy: expone `_G.ReviewAgent` (todas las
  funciones de `rpc` cerrando sobre `core`, más `servername()`), y crea autocmds para adjuntar el
  watcher a los buffers de archivos del repo (`BufReadPost`/`BufWinEnter`) y liberarlo en
  `BufWipeout`/`BufDelete`. Si `opts.enabled` es falsy → no toca `_G` ni crea watchers (inerte).

- [ ] **Step 1: Test que falla — `tests/agent/init_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local events = require("review.core.events")
local agent = require("review.features.agent")

local core = { state = state, git = git, ns = ns, events = events }

describe("features.agent.setup", function()
  before_each(function()
    local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset(); events._reset()
    _G.ReviewAgent = nil
  end)

  it("no expone _G.ReviewAgent si enabled no es true", function()
    agent.setup(core, {})
    assert.is_nil(_G.ReviewAgent)
  end)

  it("expone la API completa cuando enabled=true", function()
    agent.setup(core, { enabled = true })
    assert.is_table(_G.ReviewAgent)
    for _, fn in ipairs({ "list", "get", "context", "add", "reply", "resolve",
                          "unresolve", "update", "delete", "clean_resolved",
                          "is_modified", "notify_changed", "servername" }) do
      assert.is_function(_G.ReviewAgent[fn], fn .. " debe ser función")
    end
    local id = _G.ReviewAgent.add({ path = "x.ts", lnum = 1, text = "t" })
    assert.is_truthy(id)
    assert.are.equal(1, #vim.json.decode(_G.ReviewAgent.list()))
  end)

  it("servername() devuelve v:servername", function()
    agent.setup(core, { enabled = true })
    assert.are.equal(vim.v.servername, _G.ReviewAgent.servername())
  end)

  it("se auto-registra en core.registry", function()
    local feats = require("review.core").registry.features()
    assert.is_not_nil(feats.agent)
    assert.are.equal(agent.setup, feats.agent.setup)
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/init_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.agent' not found").

- [ ] **Step 3: Implementar `lua/review/features/agent/init.lua`**

```lua
local rpc = require("review.features.agent.rpc")
local watch = require("review.features.agent.watch")

local M = {}

function M.setup(core, opts)
  opts = opts or {}
  if not opts.enabled then return end

  _G.ReviewAgent = {
    list = function(filter_json) return rpc.list(core, filter_json) end,
    get = function(id) return rpc.get(core, id) end,
    context = function(id) return rpc.context(core, id) end,
    add = function(json_or_table) return rpc.add(core, json_or_table) end,
    reply = function(parent_id, text) return rpc.reply(core, parent_id, text) end,
    resolve = function(id) return rpc.resolve(core, id) end,
    unresolve = function(id) return rpc.unresolve(core, id) end,
    update = function(id, text) return rpc.update(core, id, text) end,
    delete = function(id) return rpc.delete(core, id) end,
    clean_resolved = function(path) return rpc.clean_resolved(core, path) end,
    is_modified = function(path) return rpc.is_modified(core, path) end,
    notify_changed = function(path) return rpc.notify_changed(core, path) end,
    servername = function() return vim.v.servername end,
  }

  local group = vim.api.nvim_create_augroup("ReviewAgentWatch", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = group,
    callback = function(a) watch.attach(core, a.buf) end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(a) watch.detach(a.buf) end,
  })
  -- Adjuntar a los buffers ya abiertos al habilitar.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then watch.attach(core, b) end
  end

  vim.schedule(function()
    vim.notify(
      "review.nvim: agent RPC enabled on socket " .. tostring(vim.v.servername),
      vim.log.levels.INFO
    )
  end)
end

require("review.core").registry.register({ name = "agent", setup = M.setup })

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/init_spec.lua" -c "qa"`
Expected: PASS (4).

- [ ] **Step 5: `:ReviewReload` manual como fallback** (`lua/review/features/agent/init.lua`, dentro de `M.setup`, antes del `vim.schedule`)

```lua
  -- Fallback manual para el único caso que auto no resuelve (buffer con cambios
  -- sin guardar en conflicto con disco): fuerza el patch del buffer actual.
  vim.api.nvim_create_user_command("ReviewReload", function()
    local b = vim.api.nvim_get_current_buf()
    -- forzamos aunque estuviera modified: el humano lo pidió explícitamente.
    if vim.bo[b].modified then vim.bo[b].modified = false end
    require("review.features.agent.reconcile").patch(core, b)
  end, {})
```

- [ ] **Step 6: Suite completa del plugin (no romper nada)**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`
Expected: PASS (todos los slices verde).

- [ ] **Step 7: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(agent): _G.ReviewAgent + watcher cableado + :ReviewReload, deshabilitado por defecto"
```

---

### Task 7: `comments` render/gutter/peek — distinguir autoría, hilos y `stale` (UI)

**Files:**
- Modify: `lua/review/features/comments/render.lua` (badge/hl por autor + marca stale)
- Modify: `lua/review/features/comments/gutter.lua` (color/ícono por autor + "respondido")
- Modify: `lua/review/features/comments/mode.lua` (peek muestra el hilo completo)
- Modify: `lua/review/features/views/init.lua` (definir highlights nuevos con `default=true`)
- Modify: `docs/highlights.md`

Esta capa es visual (extmarks reales / floats), se verifica manualmente como en `03-views.md`. La
lógica ya está testeada (autoría en `state`, hilos en `state.thread`, stale en `render.reconcile`).

**Interfaces:**
- Consumes: `core.state.for_path`, `core.state.replies`, `core.state.thread`.
- Produces: pintado que distingue `author == "user"` de `author ~= "user"` (agente), marca visual de
  `stale`, y peek que renderiza el hilo (comentario + respuestas debajo).

- [ ] **Step 1: Definir highlights nuevos** (`lua/review/features/views/init.lua`, en la función que
  define los grupos con `default=true`, junto a los `ReviewComment*` existentes)

```lua
  set("ReviewCommentAgent",   { bg = "#3a2c52" })  -- fondo de comentario del agente (violeta)
  set("ReviewCommentStale",   { bg = "#4a3a1d" })  -- comentario con anclaje incierto (ámbar)
  set("ReviewCommentSignAgent", { fg = "#c6a0f6" }) -- corchete del agente en el gutter
```

(usar el mismo helper `set`/`nvim_set_hl(0, name, { ..., default = true })` que ya usa el archivo).

- [ ] **Step 2: `render.lua` — badge/hl por autor + marca stale**

En el loop de `M.render`, al elegir el highlight de fondo y el prefijo del badge, contemplar autor y
stale:

```lua
    local is_agent = c.author and c.author ~= "user"
    local icon = is_agent and "🤖" or "💬"
    if c.stale then icon = "⚠️ " .. icon end
    -- hl de fondo: resuelto > stale > agente > normal (alternado)
    local line_hl
    if c.resolved then
      line_hl = "ReviewCommentLineResolved"
    elseif c.stale then
      line_hl = "ReviewCommentStale"
    elseif is_agent then
      line_hl = "ReviewCommentAgent"
    else
      line_hl = (idx % 2 == 0) and "ReviewCommentLine" or "ReviewCommentLine2"
    end
```

(Adaptar a los nombres reales de las variables del loop actual — `idx`, badge, etc. Mantener el
badge de eol pero con `icon` en vez del `💬` fijo, y agregar un sufijo si tiene respuestas:
`#core.state.replies(c.id) > 0` → ` ↩N`).

- [ ] **Step 3: `gutter.lua` — color del corchete por autor + marca "respondido"**

En el cálculo del `statuscolumn`, si el comentario es del agente usar `ReviewCommentSignAgent` en vez
del color cíclico; si tiene respuestas, agregar un pequeño marcador (`↩`) o cambiar el carácter del
tope del corchete. Respetar `render.hidden` como ya lo hace.

- [ ] **Step 4: `mode.lua` (peek) — renderizar el hilo completo**

En `M.peek_here`/el builder de las `virt_lines` del peek, en vez de mostrar solo `c.text`, construir
las líneas con `core.state.thread(c.id)`: el comentario padre y, debajo, cada respuesta con sangría y
su autor (`↳ 🤖 agent: ...`). Mantener el diseño fijo (virt_lines, no flotante) de la decisión D8.

- [ ] **Step 5: Verificación manual**

1. `nvim` sobre un archivo del repo con cambios. Crear un comentario tuyo (`<leader>rc`).
2. Con el agente habilitado (Task 8) o desde otra terminal:
   `nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr 'luaeval("ReviewAgent.reply(_A, \"porque el tipo puede ser null\")", "<id>")'`
   (obtené el `<id>` con `ReviewAgent.list()`).
3. Confirmar en el buffer: el comentario del agente se pinta con fondo violeta + 🤖; tu comentario
   muestra el sufijo `↩1` (tiene 1 respuesta); el peek (`<leader>rp`) muestra el hilo (tu comentario
   arriba, la respuesta del agente sangrada debajo).
4. Simular re-anclaje incierto: editar en disco (fuera de nvim) la línea comentada por algo muy
   distinto; al reconciliar, el comentario debe quedar marcado `⚠️` con fondo ámbar (`stale`).
5. Confirmar que ocultar/mostrar (`<leader>rh`) sigue funcionando y que el gutter no se filtra a
   neo-tree (regresión B del D13).

- [ ] **Step 6: Actualizar `docs/highlights.md`** con los 3 grupos nuevos (`ReviewCommentAgent`,
  `ReviewCommentStale`, `ReviewCommentSignAgent`) y su default.

- [ ] **Step 7: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): distinguir autoría del agente, hilos en el peek y marca stale (UI)"
```

---

### Task 8: `comments` lista — filtro por autor y por respondido/sin responder

**Files:**
- Modify: `lua/review/features/comments/commands.lua`
- Modify: `tests/comments/commands_spec.lua`

**Interfaces:**
- Consumes: `core.state.all`, `core.state.replies`.
- Produces: el filtro `f` de la quickfix (`:Rl`/`:Rlf`) cicla por más estados; se agrega un helper
  puro `commands._filter(list, replies_fn, mode)` testeable que devuelve la sublista según el modo:
  `all | open | resolved | mine | agent | answered | unanswered`.

- [ ] **Step 1: Test que falla — agregar a `tests/comments/commands_spec.lua`**

```lua
  it("_filter selecciona por modo (mine/agent/answered/unanswered)", function()
    local p = { id = "p", author = "user", resolved = false }
    local a = { id = "a", author = "agent", resolved = false }
    local list = { p, a }
    local replies_fn = function(id) return id == "p" and { {} } or {} end  -- p tiene 1 respuesta

    local mine = commands._filter(list, replies_fn, "mine")
    assert.are.equal(1, #mine); assert.are.equal("p", mine[1].id)

    local ag = commands._filter(list, replies_fn, "agent")
    assert.are.equal(1, #ag); assert.are.equal("a", ag[1].id)

    local answered = commands._filter(list, replies_fn, "answered")
    assert.are.equal(1, #answered); assert.are.equal("p", answered[1].id)

    local unanswered = commands._filter(list, replies_fn, "unanswered")
    assert.are.equal(1, #unanswered); assert.are.equal("a", unanswered[1].id)

    assert.are.equal(2, #commands._filter(list, replies_fn, "all"))
  end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/commands_spec.lua" -c "qa"`
Expected: FAIL (`attempt to call field '_filter' (a nil value)`).

- [ ] **Step 3: Implementar `commands._filter`** (`lua/review/features/comments/commands.lua`, antes de `return M`)

```lua
--- Filtra una lista de comentarios según `mode`. `replies_fn(id)` devuelve las
--- respuestas de un comentario (para answered/unanswered). Función pura/testeable.
function M._filter(list, replies_fn, mode)
  local function answered(c) return #(replies_fn(c.id) or {}) > 0 end
  local pred = {
    all = function() return true end,
    open = function(c) return not c.resolved end,
    resolved = function(c) return c.resolved end,
    mine = function(c) return (c.author or "user") == "user" end,
    agent = function(c) return (c.author or "user") ~= "user" end,
    answered = function(c) return answered(c) end,
    unanswered = function(c) return not answered(c) end,
  }
  local f = pred[mode] or pred.all
  local out = {}
  for _, c in ipairs(list) do if f(c) then out[#out + 1] = c end end
  return out
end
```

- [ ] **Step 4: Cablear el ciclo de `f` en la quickfix** para pasar por los nuevos modos
  (`all → open → resolved → mine → agent → answered → unanswered → all`), usando
  `M._filter(core.state.all(), function(id) return core.state.replies(id) end, mode)` y actualizando
  el hint de la winbar. (Sin test automatizado: es interacción de quickfix; el helper puro ya está
  cubierto en Step 1.)

- [ ] **Step 5: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/commands_spec.lua" -c "qa"`
Expected: PASS (previos + 1).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): filtro de lista por autor y por respondido/sin responder"
```

---

### Task 9: Documentar el protocolo del agente + verificación end-to-end

**Files:**
- Modify: `docs/features.md` (sección `agent`: pasar de "PENDIENTE" a implementado)
- Modify: `docs/commands.md` (agregar `:ReviewReload` y el nuevo ciclo de filtros)
- Modify: `docs/decisions.md` (D21 → implementado; agregar D22 reconciliación AUTO)
- Create/rescribir: sección "Protocolo del agente" en este archivo (abajo)

- [ ] **Step 1: Verificación end-to-end del RPC** (con Neovim escuchando)

```bash
cd ~/Dev/nvim/review.nvim
nvim --headless --listen /tmp/review-nvim.sock \
  -c "lua require('review').setup({ features = { agent = { enabled = true } } })" &
sleep 1
# agregar un comentario desde afuera
nvim --server /tmp/review-nvim.sock --remote-expr \
  'luaeval("ReviewAgent.add(_A)", "{\"path\":\"foo.ts\",\"lnum\":1,\"text\":\"probando\"}")'
# listar
nvim --server /tmp/review-nvim.sock --remote-expr 'luaeval("ReviewAgent.list()")'
kill %1
```

Expected: el primer `--remote-expr` imprime un id; el segundo, un JSON array con el comentario.

- [ ] **Step 2: Actualizar docs** (features/commands/decisions) reflejando: reconciliación AUTO por
  patch-diff, watcher, threading/autoría/stale, `:ReviewReload`, API `_G.ReviewAgent`.

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "docs(agent): protocolo RPC, reconciliación AUTO y actualización de features/commands/decisions"
```

---

## Protocolo del agente

**No hay servidor propio.** El "servidor" es el mismo proceso `nvim` que el humano tiene abierto (o
uno headless con `--listen`). El agente usa el binario `nvim` como cliente RPC contra ese socket. El
socket está en `v:servername` (`:echo v:servername`) o en el `--listen <path>` con que se arrancó.

### Modelo mental

- **El agente escribe CÓDIGO en disco con sus propias herramientas** (Edit/Write/etc.), FUERA de
  nvim. review.nvim NO edita código.
- **Los comentarios pasan por nvim** vía `_G.ReviewAgent` (RPC), que opera sobre `core.state` (única
  fuente de verdad de comentarios).
- Cuando el agente cambia un archivo en disco, el **watcher** (`vim.uv.fs_event`) lo detecta y
  `reconcile.patch` aplica el cambio al buffer como **patch mínimo por diff** — los extmarks (y por
  lo tanto los comentarios) **se re-anclan solos por gravity**, sin `:edit!`. Si el buffer tiene
  cambios sin guardar del humano, NO se pisa: se reporta conflicto y queda `:ReviewReload` manual.
- Antes de editar un archivo, el agente puede consultar `ReviewAgent.is_modified(path)` para no
  chocar con algo que el humano está editando sin guardar. Tras editar, puede llamar
  `ReviewAgent.notify_changed(path)` para forzar el patch de inmediato (además del watcher).

### Habilitar (deshabilitado por defecto)

```lua
require("review").setup({ features = { agent = { enabled = true } } })
```

### API `_G.ReviewAgent`

| Función | Firma | Devuelve |
|---|---|---|
| `list(filter?)` | `(string JSON filter?)` | `string` JSON array. filter: `{author?,path?,resolved?,answered?}` |
| `get(id)` | `(string)` | `string` JSON del comentario + `replies`, o `"null"` |
| `context(id)` | `(string)` | `string` JSON `{comment, lines}` (código que abarca) |
| `add(c)` | `(table\|string JSON)` | `string` id, o `""` si inválido. `author` default `"agent"` |
| `reply(parent_id, text)` | `(string, string)` | `string` id de la respuesta, o `""` |
| `resolve(id)` / `unresolve(id)` | `(string)` | `boolean` |
| `update(id, text)` | `(string, string)` | `boolean` |
| `delete(id)` | `(string)` | `boolean` |
| `clean_resolved(path?)` | `(string?)` | `number` (cuántos borró) |
| `is_modified(path)` | `(string)` | `boolean` — buffer abierto con cambios sin guardar |
| `notify_changed(path)` | `(string)` | `boolean` — forzó el patch de ese buffer |
| `servername()` | `()` | `string` — el socket actual |

### Ejemplos (`--remote-expr`, con `_A` para pasar argumentos sin escaping infernal)

```bash
# listar solo los míos sin responder
nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr \
  'luaeval("ReviewAgent.list(_A)", "{\"author\":\"user\",\"answered\":false}")'

# responder a un comentario del humano
nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr \
  'luaeval("ReviewAgent.reply(_A[1], _A[2])", ["18f2a90b-3c1a", "porque el tipo puede ser null"])'

# ver el código que abarca un comentario (para entender a qué se refiere)
nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr 'luaeval("ReviewAgent.context(_A)", "18f2a90b-3c1a")'

# tras editar en disco, forzar la recarga + re-anclaje
nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr 'luaeval("ReviewAgent.notify_changed(_A)", "src/foo.ts")'
```

### Flujo típico

1. El humano deja comentarios (dudas, pedidos). `:Rya` copia el markdown agent-ready.
2. El agente lee (`list`/`get`/`context`), **edita el código en disco por su cuenta**, y por RPC
   **responde ligado** (`reply`) con la justificación, opcionalmente `resolve`, y llama
   `notify_changed(path)` de lo que tocó (o deja que el watcher lo detecte).
3. Neovim recarga esos archivos con patch mínimo y re-ancla los comentarios; el humano ve en vivo el
   badge 🤖/`↩` y el peek con el hilo. Acepta (queda resuelto) o reabre.
4. `clean_resolved` para limpiar lo cerrado.

## Self-Review

- **Alineado con `docs/roadmap.md` §1:** transporte RPC nativo ✅ (T6/protocolo); separación
  código-en-disco vs comentarios-por-nvim ✅ (T3 reconcile + protocolo); reconciliación AUTO por
  patch mínimo por diff con re-anclaje por gravity ✅ (T3, validado empíricamente en roadmap §1.3);
  detección por watcher `fs_event` + debounce + `notify_changed` ✅ (T4/T5); conflicto si `modified`
  (no pisar) + `:ReviewReload` fallback ✅ (T3/T6); `anchor_text` + `stale` ✅ (T2); autoría +
  threading (`reply_to`) + filtros ✅ (T1/T5/T8); API `_G.ReviewAgent` completa ✅ (T5/T6);
  deshabilitada por defecto ✅ (T6). Orden de impl coincide con roadmap §1.7.
- **Regla de no-dependencia entre features:** `agent` nunca hace `require("review.features.comments")`
  ni viceversa; coordinan por el evento `buffer:reconciled` (T3). `agent` solo requiere `review.core`
  y sus propios submódulos.
- **Sin fugas:** watchers se cierran en `BufWipeout`/`BufDelete` (T4/T6), timers de debounce se cierran
  siempre (T4).
- **Edge-cases:** buffer `modified` → `conflict`, no pisa (T3); JSON inválido → `""`/`null` (T5);
  padre inexistente en `reply` → `""` (T5); id inexistente → `false` (T5); feature inerte si no
  `enabled` (T6); fuera del repo → no-op (T2/T3/T4).
- **Placeholders:** el código de `state`, `reconcile`, `watch`, `rpc`, `agent/init` está completo y
  ejecutable. Las Tasks 7 (UI render/gutter/peek) y 8 Step 4 (cableado del ciclo de quickfix) se
  adaptan a las variables reales de los archivos existentes y se verifican manualmente, siguiendo el
  criterio de `03-views.md` para capas visuales; su lógica pura sí tiene tests.
- **Retro-compatibilidad:** campos nuevos opcionales; `state.persist` ya los conserva; JSON viejo
  carga sin ellos (defaults nil/false).
