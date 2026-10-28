local ns = require("review.core.ns")
local inline = require("review.features.views.inline")

-- core mínimo: el HEAD lo da `head`, sin repo git.
local function make_core(head)
  return {
    ns = ns,
    git = {
      rel_path = function() return "f.txt" end,
      root = function() return "/repo" end,
      head_content = function() return head end,
    },
  }
end

local function virt_marks(bufnr)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns.views, 0, -1, { details = true })) do
    if m[4].virt_lines then out[#out + 1] = { row = m[2], above = m[4].virt_lines_above, lines = m[4].virt_lines } end
  end
  return out
end

describe("views.inline", function()
  local bufnr
  before_each(function()
    inline.invalidate()
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  it("un borrado al final del archivo se dibuja DEBAJO de la última línea", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b", "c" })
    inline.render(make_core({ "a", "b", "c", "d" }), bufnr)
    local marks = virt_marks(bufnr)
    assert.are.equal(1, #marks)
    assert.are.equal(2, marks[1].row) -- fila de "c"
    assert.is_false(marks[1].above)
    assert.are.equal("d", vim.trim(marks[1].lines[1][1][1]))
  end)

  it("un borrado en el medio se dibuja ENCIMA de la línea que lo sigue", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "c" })
    inline.render(make_core({ "a", "b", "c" }), bufnr)
    local marks = virt_marks(bufnr)
    assert.are.equal(1, #marks)
    assert.are.equal(1, marks[1].row) -- fila de "c"
    assert.is_true(marks[1].above)
  end)
end)
