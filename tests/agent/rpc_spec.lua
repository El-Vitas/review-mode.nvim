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
