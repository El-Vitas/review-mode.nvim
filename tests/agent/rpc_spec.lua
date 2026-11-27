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

  it("list() without comments returns []", function()
    assert.are.equal("[]", rpc.list(core))
  end)

  it("list() excludes _extmark_id", function()
    local c = state.add({ path = "a.ts", lnum = 1, text = "x" }); c._extmark_id = 7
    local d = vim.json.decode(rpc.list(core))
    assert.is_nil(d[1]._extmark_id)
  end)

  it("list(filter) filters by author and by answered", function()
    local p = state.add({ path = "a.ts", lnum = 1, text = "mine", author = "user" })
    state.add({ path = "a.ts", lnum = 1, text = "reply", author = "agent", reply_to = p.id })
    state.add({ path = "a.ts", lnum = 2, text = "no reply", author = "user" })

    local mine = vim.json.decode(rpc.list(core, vim.json.encode({ author = "user" })))
    assert.are.equal(2, #mine)
    local answered = vim.json.decode(rpc.list(core, vim.json.encode({ answered = true })))
    assert.are.equal(1, #answered)
    assert.are.equal(p.id, answered[1].id)
    local unanswered = vim.json.decode(rpc.list(core, vim.json.encode({ author = "user", answered = false })))
    assert.are.equal(1, #unanswered)
  end)

  it("add() validates and returns an id; author defaults to agent", function()
    local id = rpc.add(core, { path = "b.ts", lnum = 3, text = "from agent" })
    assert.is_not.equal("", id)
    assert.are.equal("agent", state.by_id(id).author)
  end)

  it("add() with invalid JSON returns ''", function()
    assert.are.equal("", rpc.add(core, "{ broken"))
  end)

  it("reply() links to the parent and inherits its path/lnum", function()
    local p = state.add({ path = "a.ts", lnum = 5, text = "question" })
    local rid = rpc.reply(core, p.id, "because X")
    local r = state.by_id(rid)
    assert.are.equal(p.id, r.reply_to)
    assert.are.equal("a.ts", r.path)
    assert.are.equal(5, r.lnum)
    assert.are.equal("agent", r.author)
  end)

  it("reply() with a nonexistent parent returns ''", function()
    assert.are.equal("", rpc.reply(core, "does-not-exist", "x"))
  end)

  it("get() returns the comment with its replies", function()
    local p = state.add({ path = "a.ts", lnum = 1, text = "question" })
    rpc.reply(core, p.id, "reply")
    local g = vim.json.decode(rpc.get(core, p.id))
    assert.are.equal("question", g.text)
    assert.are.equal(1, #g.replies)
  end)

  it("resolve/unresolve/update/delete", function()
    local c = state.add({ path = "a.ts", lnum = 1, text = "x" })
    assert.is_true(rpc.resolve(core, c.id));   assert.is_true(state.by_id(c.id).resolved)
    assert.is_true(rpc.unresolve(core, c.id)); assert.is_false(state.by_id(c.id).resolved)
    assert.is_true(rpc.update(core, c.id, "new text")); assert.are.equal("new text", state.by_id(c.id).text)
    assert.is_true(rpc.delete(core, c.id));    assert.is_nil(state.by_id(c.id))
  end)

  it("clean_resolved deletes the resolved ones and returns the count", function()
    state.add({ path = "a.ts", lnum = 1, text = "open" })
    local r = state.add({ path = "a.ts", lnum = 2, text = "closed", resolved = true })
    assert.are.equal(1, rpc.clean_resolved(core))
    assert.is_nil(state.by_id(r.id))
    assert.are.equal(1, #state.all())
  end)

  it("add() rejects invalid types without persisting anything", function()
    local bad = {
      { path = "a.ts", lnum = "5", text = "x" },
      { path = "a.ts", lnum = { 1 }, text = "x" },
      { path = "a.ts", lnum = -5, text = "x" },
      { path = "a.ts", lnum = 1.5, text = "x" },
      { path = "a.ts", lnum = 3, end_lnum = 1, text = "x" },
      { path = "a.ts", lnum = 1, text = { 1 } },
      { path = "a.ts", lnum = 1, text = "   " },
      { path = "/etc/passwd", lnum = 1, text = "x" },
      { path = "../../etc/os-release", lnum = 1, text = "x" },
      { path = "a.ts", lnum = 1, text = "x", author = "user" },
    }
    for _, d in ipairs(bad) do assert.are.equal("", rpc.add(core, d)) end
    assert.are.equal("", rpc.add(core, '{"path":"a.ts","lnum":null,"text":"x"}'))
    assert.are.equal(0, #state.all())
  end)

  it("add() ignores fields outside the contract (id, resolved, reply_to)", function()
    local id = rpc.add(core, { path = "a.ts", lnum = 1, text = "x", id = "fixed", resolved = true, _extmark_id = 9 })
    local c = state.by_id(id)
    assert.are_not.equal("fixed", id)
    assert.is_false(c.resolved)
    assert.is_nil(c._extmark_id)
  end)

  it("add() accepts a file-level comment and a custom agent author", function()
    local id = rpc.add(core, { path = "a.ts", file_level = true, text = "whole file", author = "claude" })
    assert.is_true(state.by_id(id).file_level)
    assert.are.equal("claude", state.by_id(id).author)
  end)

  it("context() caps the range at 500 lines", function()
    local lines = {}
    for i = 1, 1000 do lines[i] = "l" .. i end
    vim.fn.writefile(lines, root .. "/long.ts")
    local id = rpc.add(core, { path = "long.ts", lnum = 1, end_lnum = 9000000, text = "x" })
    local ctx = vim.json.decode(rpc.context(core, id))
    assert.are.equal(500, #ctx.lines)
  end)

  it("list() with a broken JSON filter does not return everything", function()
    state.add({ path = "a.ts", lnum = 1, text = "x" })
    assert.are.equal("[]", rpc.list(core, "{ broken"))
  end)

  it("is_modified reflects the buffer state", function()
    local path = root .. "/m.ts"
    vim.fn.writefile({ "a" }, path)
    local b = vim.fn.bufadd(path); vim.fn.bufload(b); vim.bo[b].modified = false
    assert.is_false(rpc.is_modified(core, "m.ts"))
    vim.api.nvim_buf_set_lines(b, 0, 0, false, { "x" })
    assert.is_true(rpc.is_modified(core, "m.ts"))
  end)
end)
