local ns = require("review.core.ns")
local inline = require("review.features.views.inline")

-- minimal core: HEAD is provided by `head`, with no git repo.
local function make_core(head)
  return {
    ns = ns,
    git = {
      rel_path = function() return "f.txt" end,
      root = function() return "/repo" end,
      base_lines = function() return head end,
    },
  }
end

local function added_rows(bufnr)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns.views, 0, -1, { details = true })) do
    if m[4].line_hl_group == "DiffAdd" then out[#out + 1] = m[2] end
  end
  return out
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

  it("a deletion at the end of the file is drawn BELOW the last line", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b", "c" })
    inline.render(make_core({ "a", "b", "c", "d" }), bufnr)
    local marks = virt_marks(bufnr)
    assert.are.equal(1, #marks)
    assert.are.equal(2, marks[1].row) -- row of "c"
    assert.is_false(marks[1].above)
    assert.are.equal("d", vim.trim(marks[1].lines[1][1][1]))
  end)

  it("a deletion in the middle is drawn ABOVE the line that follows it", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "c" })
    inline.render(make_core({ "a", "b", "c" }), bufnr)
    local marks = virt_marks(bufnr)
    assert.are.equal(1, #marks)
    assert.are.equal(1, marks[1].row) -- row of "c"
    assert.is_true(marks[1].above)
  end)

  it("a file new relative to the base is painted entirely as added", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b", "c" })
    inline.render(make_core({}), bufnr)
    assert.are.same({ 0, 1, 2 }, added_rows(bufnr))
    assert.are.equal(0, #virt_marks(bufnr))
  end)

  it("a file without a base (ignored or outside the repo) is not marked", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a" })
    inline.render(make_core(nil), bufnr)
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(bufnr, ns.views, 0, -1, {}))
  end)
end)
