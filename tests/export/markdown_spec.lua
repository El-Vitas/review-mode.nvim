local md = require("review.features.export.markdown")

describe("features.export.markdown", function()
  describe("markdown(list)", function()
    it("an empty list returns an empty string", function()
      assert.are.equal("", md.markdown({}))
    end)

    it("single line: path:lnum anchor without a range", function()
      local list = {
        { id = "1", path = "src/a.ts", lnum = 10, end_lnum = 10, text = "watch out for this", resolved = false },
      }
      local out = md.markdown(list)
      assert.is_truthy(out:match("^## src/a%.ts")) -- group heading
      assert.is_truthy(out:match("1%. "))
      assert.is_truthy(out:match("`src/a%.ts:10`"))
      assert.is_falsy(out:match("`src/a%.ts:10-10`"))
      assert.is_truthy(out:match("watch out for this"))
    end)

    it("range: path:lnum-end_lnum anchor when end_lnum > lnum", function()
      local list = {
        { id = "1", path = "src/b.ts", lnum = 5, end_lnum = 8, text = "review block", resolved = false },
      }
      local out = md.markdown(list)
      assert.is_truthy(out:match("`src/b%.ts:5%-8`"))
    end)

    it("excludes resolved comments", function()
      local list = {
        { id = "1", path = "a.ts", lnum = 1, end_lnum = 1, text = "visible", resolved = false },
        { id = "2", path = "a.ts", lnum = 2, end_lnum = 2, text = "resolved", resolved = true },
      }
      local out = md.markdown(list)
      assert.is_truthy(out:match("visible"))
      assert.is_falsy(out:match("resolved"))
    end)

    it("all resolved returns an empty string (no stray header)", function()
      local list = {
        { id = "1", path = "a.ts", lnum = 1, end_lnum = 1, text = "resolved", resolved = true },
      }
      assert.are.equal("", md.markdown(list))
    end)

    it("numbers several unresolved comments correctly", function()
      local list = {
        { id = "1", path = "a.ts", lnum = 1, end_lnum = 1, text = "one", resolved = false },
        { id = "2", path = "a.ts", lnum = 2, end_lnum = 2, text = "two", resolved = true },
        { id = "3", path = "a.ts", lnum = 3, end_lnum = 3, text = "three", resolved = false },
      }
      local out = md.markdown(list)
      assert.is_truthy(out:match("1%. .*one"))
      assert.is_truthy(out:match("2%. .*three"))
      assert.is_falsy(out:match("3%. "))
    end)

    it("collapses line breaks in the text (does not break the numbering)", function()
      local list = {
        { id = "1", path = "a.ts", lnum = 1, end_lnum = 1, text = "line1\nline2", resolved = false },
        { id = "2", path = "a.ts", lnum = 2, end_lnum = 2, text = "other", resolved = false },
      }
      local out = md.markdown(list)
      local numbered = select(2, out:gsub("\n%d+%. ", "")) + (out:match("^%d+%. ") and 1 or 0)
      assert.are.equal(2, numbered) -- exactly 2 numbered lines
      assert.is_truthy(out:match("1%. .*line1 line2"))
    end)

    it("groups by file (## header) and sorts by file+line, with continuous numbering", function()
      local list = {
        { id = "1", path = "b.ts", lnum = 9, end_lnum = 9, text = "b nine", resolved = false },
        { id = "2", path = "a.ts", lnum = 5, end_lnum = 5, text = "a five", resolved = false },
        { id = "3", path = "a.ts", lnum = 2, end_lnum = 2, text = "a two", resolved = false },
      }
      local out = md.markdown(list)
      -- expected order: ## a.ts (2, then 5), ## b.ts (9); numbering 1..3
      local expected = table.concat({
        "## a.ts",
        "1. `a.ts:2` a two  `id:3`",
        "2. `a.ts:5` a five  `id:2`",
        "",
        "## b.ts",
        "3. `b.ts:9` b nine  `id:1`",
      }, "\n")
      assert.are.equal(expected, out)
    end)

    it("replies are indented under their comment, not as numbered items", function()
      local list = {
        { id = "p", path = "a.ts", lnum = 3, end_lnum = 3, text = "why?", author = "user", resolved = false },
        { id = "r", path = "a.ts", lnum = 3, end_lnum = 3, text = "Done", author = "agent", reply_to = "p", resolved = false },
      }
      assert.are.equal(table.concat({
        "## a.ts",
        "1. `a.ts:3` why?  `id:p`",
        "   ↳ agent: Done  `id:r`",
      }, "\n"), md.markdown(list))
    end)

    it("several comments on the same line come out in creation order", function()
      local list = {}
      for i = 1, 8 do list[i] = { id = "c" .. i, path = "a.ts", lnum = 1, end_lnum = 1, text = "t" .. i, resolved = false } end
      local out = md.markdown(list)
      local ids = {}
      for id in out:gmatch("`id:(c%d)`") do ids[#ids + 1] = id end
      assert.are.same({ "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8" }, ids)
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

    it("file(core, relpath) delegates to state.for_path", function()
      local core = { state = state }
      state.add({ path = "a.ts", lnum = 1, text = "only a" })
      state.add({ path = "b.ts", lnum = 1, text = "only b" })
      local out = md.file(core, "a.ts")
      assert.is_truthy(out:match("only a"))
      assert.is_falsy(out:match("only b"))
    end)

    it("all(core) delegates to state.all", function()
      local core = { state = state }
      state.add({ path = "a.ts", lnum = 1, text = "only a" })
      state.add({ path = "b.ts", lnum = 1, text = "only b" })
      local out = md.all(core)
      assert.is_truthy(out:match("only a"))
      assert.is_truthy(out:match("only b"))
    end)

    it("all(core) without comments returns an empty string", function()
      local core = { state = state }
      assert.are.equal("", md.all(core))
    end)
  end)
end)
