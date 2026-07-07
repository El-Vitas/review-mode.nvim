# review.nvim — Plan 05: Agent (puente RPC nativo)

> **Plan maestro:** `~/Dev/nvim/review.nvim/DESIGN.md` — este plan implementa la fila `agent` de la
> tabla de Features y la sección "Contrato del core" (`core.state.add/remove/update/all`). Toda
> firma aquí DEBE coincidir con ese contrato.
> REQUIRED SUB-SKILL: superpowers:subagent-driven-development

**Goal:** Exponer un puente RPC para que un agente externo (Claude Code, un script, etc.) lea,
agregue, resuelva y borre comentarios de code-review **hablando el protocolo RPC nativo de
Neovim** (`nvim --server <socket> --remote-expr 'luaeval(...)'`), sin sockets TCP propios, sin
servidor HTTP, sin dependencias nuevas. Es el equivalente al CLI `tuicr review`, pero corriendo
adentro de la misma instancia de Neovim que el humano está usando.

**Architecture:** Vertical slice bajo `lua/review/features/agent/`. Depende SOLO de
`core.state.*` (contrato ya estable desde `00-core.md`) y `core.registry`. `rpc.lua` contiene
funciones puras/serializables que operan sobre `core.state` y devuelven `string` (JSON) o
primitivos — nunca tablas Lua crudas, porque `--remote-expr` solo puede evaluar expresiones cuyo
resultado sea convertible a texto. `init.lua` las registra en `_G.ReviewAgent` para que
`luaeval("ReviewAgent.list()")` funcione desde afuera, y respeta `opts.enabled` (la feature está
**deshabilitada por defecto** — es la última fase, y expone superficie de escritura remota, así
que el usuario debe optar explícitamente por encenderla).

**Tech Stack:** Lua, Neovim ≥ 0.10 (`vim.json`, `v:servername`, `--remote-expr`/`--remote-send`),
plenary.nvim (tests busted). Sin dependencias externas: el "servidor" es el proceso `nvim` mismo,
vía su socket RPC nativo (msgpack-rpc), que Neovim ya expone con `--listen` / `$NVIM_LISTEN_ADDRESS`.

## Global Constraints

- Esta feature **NO** abre sockets propios: usa el servidor RPC que Neovim ya expone
  (`--listen <addr>` al arrancar, o `v:servername` si ya está corriendo).
- Todas las funciones expuestas al agente son **serializables**: reciben/devuelven `string`
  (JSON) o tipos primitivos (`string|boolean|nil`) — nunca extmark ids ni funciones.
- `list()` NUNCA incluye `_extmark_id` (es runtime, no persistido — igual que `state.persist()`
  ya lo excluye al guardar en disco).
- Toda mutación (`add`/`resolve`/`delete`) persiste inmediatamente (`core.state.persist()`) —
  el agente no tiene otro momento de "guardar".
- Las funciones NO bloquean el loop de eventos: el trabajo sobre `state` es síncrono y rápido
  (listas en memoria), pero cualquier interacción con UI (re-render, notify) debe ir en
  `vim.schedule` — en la práctica esto ya lo maneja `core.events.emit`, que estas funciones
  disparan indirectamente vía `state.add/remove/update`.
- Feature **deshabilitada por defecto**: `opts.enabled` debe ser `true` explícitamente en
  `features.agent = { enabled = true }` para que `init.lua` registre `_G.ReviewAgent`.
- Tests: `nvim --headless -c "PlenaryBustedFile tests/agent/<spec>.lua" -c "qa"`.

---

### Task 1: `features/agent/rpc.lua` — funciones invocables (list/add/resolve/delete)

**Files:**
- Create: `lua/review/features/agent/rpc.lua`, `tests/agent/rpc_spec.lua`

**Interfaces:**
- Consumes: `core.state.all/add/remove/update/by_id`, `core.state.persist` (contrato de
  `00-core.md`).
- Produces:
  - `rpc.list(core)` → `string` (JSON array de comentarios, sin `_extmark_id`).
  - `rpc.add(core, json_or_table)` → `string` (id del comentario agregado, o `""` si falla el
    parseo).
  - `rpc.resolve(core, id)` → `boolean`.
  - `rpc.delete(core, id)` → `boolean`.

- [ ] **Step 1: Test que falla — `tests/agent/rpc_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local rpc = require("review.features.agent.rpc")

local core = { state = state }

describe("features.agent.rpc", function()
  before_each(function()
    local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
  end)

  it("list() devuelve JSON válido y sin _extmark_id", function()
    local c = state.add({ path = "a.ts", lnum = 1, text = "hola" })
    c._extmark_id = 999
    local out = rpc.list(core)
    local ok, decoded = pcall(vim.json.decode, out)
    assert.is_true(ok)
    assert.are.equal(1, #decoded)
    assert.is_nil(decoded[1]._extmark_id)
    assert.are.equal("hola", decoded[1].text)
  end)

  it("list() sin comentarios devuelve array vacío literal []", function()
    assert.are.equal("[]", rpc.list(core))
  end)

  it("add() con tabla agrega, persiste y devuelve el id", function()
    local id = rpc.add(core, { path = "b.ts", lnum = 3, text = "desde agente", author = "agent" })
    assert.is_truthy(id)
    assert.is_not.equal("", id)
    local c = state.by_id(id)
    assert.are.equal("agent", c.author)
    -- persistió: recargar desde disco
    state._reset(); state.load()
    assert.are.equal(1, #state.all())
  end)

  it("add() con JSON string también funciona", function()
    local id = rpc.add(core, vim.json.encode({ path = "c.ts", lnum = 1, text = "x" }))
    assert.is_truthy(state.by_id(id))
  end)

  it("add() con JSON inválido no rompe, devuelve string vacío", function()
    local id = rpc.add(core, "{ esto no es json")
    assert.are.equal("", id)
  end)

  it("resolve() marca resolved=true y persiste", function()
    local c = state.add({ path = "a.ts", lnum = 1, text = "x" })
    assert.is_true(rpc.resolve(core, c.id))
    assert.is_true(state.by_id(c.id).resolved)
  end)

  it("resolve() con id inexistente devuelve false sin romper", function()
    assert.is_false(rpc.resolve(core, "no-existe"))
  end)

  it("delete() quita el comentario y persiste", function()
    local c = state.add({ path = "a.ts", lnum = 1, text = "x" })
    assert.is_true(rpc.delete(core, c.id))
    assert.is_nil(state.by_id(c.id))
  end)

  it("delete() con id inexistente devuelve false sin romper", function()
    assert.is_false(rpc.delete(core, "no-existe"))
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/rpc_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.agent.rpc' not found").

- [ ] **Step 3: Implementar `lua/review/features/agent/rpc.lua`**

```lua
local M = {}

--- Quita campos runtime (no serializables/no persistidos) de un comentario.
local function clean_comment(c)
  local copy = {}
  for k, v in pairs(c) do
    if k ~= "_extmark_id" then copy[k] = v end
  end
  return copy
end

--- list(core) -> string JSON ARRAY de todos los comentarios, sin campos runtime.
function M.list(core)
  local out = {}
  for _, c in ipairs(core.state.all()) do
    out[#out + 1] = clean_comment(c)
  end
  -- `vim.json.encode({})` produce "{}" (objeto), no "[]": un parser JSON
  -- externo que espera una lista fallaría. Forzamos array vacío explícito.
  if #out == 0 then return "[]" end
  return vim.json.encode(out)
end

--- add(core, json_or_table) -> string id (o "" si el input no es válido).
-- Acepta una tabla Lua ya decodificada o un string JSON crudo (como llega desde
-- `--remote-expr` si el agente serializa el comentario del lado de afuera).
function M.add(core, json_or_table)
  local data = json_or_table
  if type(data) == "string" then
    local ok, decoded = pcall(vim.json.decode, data)
    if not ok or type(decoded) ~= "table" then
      return ""
    end
    data = decoded
  end
  if type(data) ~= "table" or not data.path or not data.lnum or not data.text then
    return ""
  end
  data.author = data.author or "agent"
  local c = core.state.add(data)
  core.state.persist()
  return c.id
end

--- resolve(core, id) -> boolean. id inexistente => false, no rompe.
function M.resolve(core, id)
  local ok = core.state.update(id, { resolved = true })
  if ok then
    core.state.persist()
  end
  return ok
end

--- delete(core, id) -> boolean. id inexistente => false, no rompe.
function M.delete(core, id)
  local ok = core.state.remove(id)
  if ok then
    core.state.persist()
  end
  return ok
end

return M
```

- [ ] **Step 4: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/rpc_spec.lua" -c "qa"`
Expected: PASS (9).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(agent/rpc): list/add/resolve/delete serializables sobre core.state"
```

---

### Task 2: `features/agent/init.lua` — registro, `_G.ReviewAgent`, `enabled` por defecto false

**Files:**
- Create: `lua/review/features/agent/init.lua`, `tests/agent/init_spec.lua`
- Modify: `lua/review/init.lua` (requerir la feature para que se auto-registre — mismo patrón
  que las demás features del plan maestro)

**Interfaces:**
- Consumes: `rpc` (Task 1), `core.registry.register`.
- Produces: `M.setup(core, opts)` → si `opts.enabled` es `true`, expone `_G.ReviewAgent = { list,
  add, resolve, delete }` (cerrando sobre `core`, así el agente invoca sin pasar `core`) y
  reporta el socket vía `vim.v.servername` (con `vim.notify` y devolviéndolo en la tabla como
  `M.servername()`, para que tests/humanos puedan consultarlo). Si `opts.enabled` es falsy (o
  ausente), no toca `_G` — la feature queda inerte, coherente con "deshabilitada por defecto".

- [ ] **Step 1: Test que falla — `tests/agent/init_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local agent = require("review.features.agent")

describe("features.agent.setup", function()
  before_each(function()
    local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
    _G.ReviewAgent = nil
  end)

  it("no expone _G.ReviewAgent si enabled no es true", function()
    agent.setup({ state = state }, {})
    assert.is_nil(_G.ReviewAgent)
  end)

  it("expone _G.ReviewAgent cuando enabled=true, cerrando sobre core", function()
    agent.setup({ state = state }, { enabled = true })
    assert.is_table(_G.ReviewAgent)
    assert.is_function(_G.ReviewAgent.list)
    assert.is_function(_G.ReviewAgent.add)
    assert.is_function(_G.ReviewAgent.resolve)
    assert.is_function(_G.ReviewAgent.delete)

    local id = _G.ReviewAgent.add({ path = "x.ts", lnum = 1, text = "t" })
    assert.is_truthy(id)
    local decoded = vim.json.decode(_G.ReviewAgent.list())
    assert.are.equal(1, #decoded)
    assert.is_true(_G.ReviewAgent.resolve(id))
    assert.is_true(_G.ReviewAgent.delete(id))
  end)

  it("servername() devuelve vim.v.servername", function()
    agent.setup({ state = state }, { enabled = true })
    assert.are.equal(vim.v.servername, _G.ReviewAgent.servername())
  end)
end)
```

- [ ] **Step 2: Correr y ver fallar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/init_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.agent' not found").

- [ ] **Step 3: Implementar `lua/review/features/agent/init.lua`**

```lua
local rpc = require("review.features.agent.rpc")

local M = {}

function M.setup(core, opts)
  opts = opts or {}
  if not opts.enabled then
    return
  end

  if _G.ReviewAgent ~= nil then
    vim.notify("review.nvim: _G.ReviewAgent ya existía, se sobreescribe", vim.log.levels.WARN)
  end

  _G.ReviewAgent = {
    list = function()
      return rpc.list(core)
    end,
    add = function(json_or_table)
      return rpc.add(core, json_or_table)
    end,
    resolve = function(id)
      return rpc.resolve(core, id)
    end,
    delete = function(id)
      return rpc.delete(core, id)
    end,
    servername = function()
      return vim.v.servername
    end,
  }

  vim.schedule(function()
    vim.notify(
      "review.nvim: agent RPC habilitado en socket " .. tostring(vim.v.servername),
      vim.log.levels.INFO
    )
  end)
end

require("review.core").registry.register({ name = "agent", setup = M.setup })

return M
```

- [ ] **Step 4: (nada que hacer en `review/init.lua`)** — el core ya carga todas las features con
  un loop `pcall(require, "review.features."..name)` que incluye `"agent"` (ver `00-core.md`
  Task 6 Step 3). Como `agent` respeta `opts.enabled` (falsy por defecto), quedar registrada es
  inofensivo: no expone `_G.ReviewAgent` hasta que el usuario ponga `features.agent = { enabled = true }`.
  Verificá que el require del core ya la incluye; no dupliques la carga acá.

- [ ] **Step 5: Correr y ver pasar**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/init_spec.lua" -c "qa"`
Expected: PASS (3).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(agent): setup con _G.ReviewAgent, deshabilitado por defecto"
```

---

### Task 3: Documentar el protocolo RPC del agente

**Files:**
- Modify: `docs/plans/05-agent.md` (esta sección, ya embebida abajo — no requiere código nuevo)

**Interfaces:**
- No produce código. Documenta cómo un proceso externo (agente) habla con Neovim.

- [ ] **Step 1: Escribir la sección de protocolo (ver bloque "## Protocolo del agente" más abajo
  en este mismo archivo) y verificar manualmente el flujo end-to-end**:

Run (en una terminal, con Neovim escuchando):

```bash
cd ~/Dev/nvim/review.nvim
nvim --headless --listen /tmp/review-nvim.sock \
  -c "lua require('review').setup({ features = { agent = { enabled = true } } })" &
sleep 1
nvim --server /tmp/review-nvim.sock --remote-expr \
  "luaeval(\"ReviewAgent.add({path='foo.ts', lnum=1, text='probando desde afuera'})\")"
nvim --server /tmp/review-nvim.sock --remote-expr "luaeval(\"ReviewAgent.list()\")"
```

Expected: el primer `--remote-expr` imprime un id (uuid-like), el segundo imprime un JSON array
con un comentario cuyo `text` es `"probando desde afuera"`. Matar el proceso con
`nvim --server /tmp/review-nvim.sock --remote-expr "luaeval('1')" ; kill %1` o cerrando la
terminal.

- [ ] **Step 2: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "docs(agent): protocolo RPC nativo y ejemplos de --remote-expr"
```

---

## Protocolo del agente

**No hay servidor propio.** El "servidor" es el mismo proceso `nvim` que el humano tiene abierto
(o uno headless dedicado). Neovim expone su bus RPC (msgpack-rpc) nativamente:

- Si Neovim ya está corriendo, su socket está en `v:servername` (podés verlo con
  `:echo v:servername` o, desde afuera, si lo arrancaste vos con `--listen <path>`).
- Si lo arrancás para el agente, hacelo con `nvim --listen /tmp/review-nvim.sock ...` (o exportá
  `NVIM_LISTEN_ADDRESS` antes de arrancarlo).

El agente externo (Claude Code, un script bash/python, lo que sea) NO necesita ninguna librería
especial: usa el binario `nvim` como cliente RPC contra ese socket.

### Requisito: habilitar la feature

Por defecto `agent` está **deshabilitada** (superficie de escritura remota = riesgo). Para
habilitarla:

```lua
require("review").setup({
  features = {
    agent = { enabled = true },
  },
})
```

Una vez habilitada, existe una tabla global `_G.ReviewAgent` con 5 funciones:

| Función | Firma | Devuelve |
|---|---|---|
| `ReviewAgent.list()` | `()` | `string` — JSON array de comentarios |
| `ReviewAgent.add(c)` | `(table \| string JSON)` | `string` — id del comentario, o `""` si el input es inválido |
| `ReviewAgent.resolve(id)` | `(string)` | `boolean` |
| `ReviewAgent.delete(id)` | `(string)` | `boolean` |
| `ReviewAgent.servername()` | `()` | `string` — el socket actual (`v:servername`) |

### Formato JSON de un comentario

Lo que devuelve `list()` (y lo que `add()` espera, salvo `id`/`created_at`/`resolved` que se
autocompletan):

```json
{
  "id": "18f2a90b-3c1a",
  "path": "src/foo.ts",
  "lnum": 42,
  "end_lnum": 42,
  "text": "¿esto no debería validar null?",
  "resolved": false,
  "author": "agent",
  "created_at": "2026-07-07T12:00:00Z"
}
```

Nunca incluye `_extmark_id` (campo runtime de anclaje visual, solo vive en memoria dentro de
Neovim mientras la feature `comments` tiene el buffer abierto).

### Ejemplos de invocación desde afuera

**Listar comentarios:**

```bash
nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr 'luaeval("ReviewAgent.list()")'
```

**Agregar un comentario** (el agente arma el JSON y lo pasa como string; `luaeval` permite pasar
argumentos vía su segundo parámetro para evitar escaping infernal de comillas):

```bash
nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr \
  'luaeval("ReviewAgent.add(_A)", "{\"path\":\"src/foo.ts\",\"lnum\":42,\"text\":\"revisar null-check\"}")'
```

(`_A` es la variable especial de `luaeval(expr, arg)` que recibe el segundo argumento del lado
Lua — así el string JSON no tiene que ir embebido literal dentro de la expresión Lua.)

**Resolver un comentario:**

```bash
nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr \
  'luaeval("ReviewAgent.resolve(_A)", "18f2a90b-3c1a")'
```

**Borrar un comentario:**

```bash
nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr \
  'luaeval("ReviewAgent.delete(_A)", "18f2a90b-3c1a")'
```

**Descubrir el socket desde dentro de Neovim** (para que el humano se lo pase al agente, ej. como
variable de entorno de la sesión de terminal donde corre el agente):

```vim
:echo v:servername
```

o, si el agente puede ejecutar comandos Lua directamente dentro de la misma sesión (ej. vía un
plugin de terminal integrada), simplemente `ReviewAgent.servername()`.

### Re-render tras cambios remotos

`ReviewAgent.add/resolve/delete` llaman a `core.state.add/update/remove`, que **ya emiten el
evento `comments:changed`** (contrato de `00-core.md`, Task 5). La feature `comments` (cuando
esté implementada) se suscribe a ese evento para re-renderizar los extmarks de los buffers
abiertos — `agent` no necesita saber nada de eso ni tocar UI directamente: es pura coordinación
por eventos, igual que cualquier otra feature. Esto también significa que si el humano tiene un
buffer abierto mientras el agente agrega/borra comentarios desde afuera, la vista se actualiza
sola sin que el humano tenga que hacer nada.

### `--remote-send` como alternativa

Para casos donde el agente prefiere disparar un comando en vez de evaluar una expresión (ej.
forzar un `:w` o un redraw), existe `--remote-send`:

```bash
nvim --server "$NVIM_LISTEN_ADDRESS" --remote-send ':echo v:lua.ReviewAgent.list()<CR>'
```

Nota: `ReviewAgent` vive en `_G` del lado Lua; desde Vimscript se accede como
`v:lua.ReviewAgent` (`:echo ReviewAgent...` daría `E121: Undefined variable`). Esto no devuelve el
valor al shell (a diferencia de `--remote-expr`), así que para leer resultados el agente SIEMPRE
debe usar `--remote-expr`.

## Self-Review

- **Cobertura del contrato (DESIGN.md, fila `agent`):** depende únicamente de
  `state.add/remove/update/all` ✅ (Task 1) — nunca toca `git`, `store` ni `ns` directamente
  (persistencia pasa siempre por `state.persist()`, coherente con "TODO el I/O pasa por
  `core.store`" ya que `state.persist` es la puerta).
- **Sin sockets propios:** confirmado — todo el protocolo se apoya en `--listen`/`v:servername` y
  `--remote-expr`/`--remote-send` nativos de Neovim; no se agrega ninguna dependencia de red.
- **Placeholders:** ninguno; todo el código Lua de `rpc.lua` e `init.lua` está completo y es el
  que corre en los tests.
- **Edge-cases cubiertos:** id inexistente en `resolve`/`delete` → `false` sin excepción (Task 1,
  tests 6 y 8); JSON inválido en `add` → `""` sin excepción vía `pcall` (Task 1, test 5); feature
  deshabilitada por defecto → `_G.ReviewAgent` permanece `nil` salvo `opts.enabled == true` (Task
  2, test 1); re-render de buffers abiertos delegado al evento `comments:changed` que `state` ya
  emite (documentado en "Protocolo del agente", sin código adicional porque el contrato del core
  ya lo garantiza).
- **No bloqueo del loop:** las mutaciones sobre listas en memoria son síncronas y baratas; el
  único efecto async (notificación de socket) va en `vim.schedule` (Task 2, Step 3).
- **Consistencia con `00-core.md`:** firmas de `state.*` usadas exactamente como están
  documentadas (`add(comment)`, `remove(id)`, `update(id, fields)`, `all()`), sin inventar
  parámetros nuevos.
</content>
