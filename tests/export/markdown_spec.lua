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
      assert.is_truthy(out:match("^## src/a%.ts")) -- encabezado del grupo
      assert.is_truthy(out:match("1%. "))
      assert.is_truthy(out:match("`src/a%.ts:10`"))
      assert.is_falsy(out:match("`src/a%.ts:10-10`"))
      assert.is_truthy(out:match("ojo con esto"))
    end)

    it("rango: ancla path:lnum-end_lnum cuando end_lnum > lnum", function()
      local list = {
        { id = "1", path = "src/b.ts", lnum = 5, end_lnum = 8, text = "revisar bloque", resolved = false },
      }
      local out = md.markdown(list)
      assert.is_truthy(out:match("`src/b%.ts:5%-8`"))
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
      local numbered = select(2, out:gsub("\n%d+%. ", "")) + (out:match("^%d+%. ") and 1 or 0)
      assert.are.equal(2, numbered) -- exactamente 2 líneas numeradas
      assert.is_truthy(out:match("1%. .*línea1 línea2"))
    end)

    it("agrupa por archivo (## header) y ordena por archivo+línea, numeración continua", function()
      local list = {
        { id = "1", path = "b.ts", lnum = 9, end_lnum = 9, text = "b nueve", resolved = false },
        { id = "2", path = "a.ts", lnum = 5, end_lnum = 5, text = "a cinco", resolved = false },
        { id = "3", path = "a.ts", lnum = 2, end_lnum = 2, text = "a dos", resolved = false },
      }
      local out = md.markdown(list)
      -- orden esperado: ## a.ts (2, luego 5), ## b.ts (9); numeración 1..3
      local expected = table.concat({
        "## a.ts",
        "1. `a.ts:2` a dos  `id:3`",
        "2. `a.ts:5` a cinco  `id:2`",
        "",
        "## b.ts",
        "3. `b.ts:9` b nueve  `id:1`",
      }, "\n")
      assert.are.equal(expected, out)
    end)

    it("las respuestas van sangradas bajo su comentario, no como ítems numerados", function()
      local list = {
        { id = "p", path = "a.ts", lnum = 3, end_lnum = 3, text = "¿por qué?", author = "user", resolved = false },
        { id = "r", path = "a.ts", lnum = 3, end_lnum = 3, text = "Hecho", author = "agent", reply_to = "p", resolved = false },
      }
      assert.are.equal(table.concat({
        "## a.ts",
        "1. `a.ts:3` ¿por qué?  `id:p`",
        "   ↳ agent: Hecho  `id:r`",
      }, "\n"), md.markdown(list))
    end)

    it("varios comentarios en la misma línea salen en orden de creación", function()
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
