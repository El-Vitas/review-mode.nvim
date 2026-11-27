local diff = require("review.features.views.diff")

local M = {}

-- Cache of the HEAD content per buffer: `git show HEAD` is an expensive subprocess and
-- render() is called on EVERY keystroke (TextChangedI). HEAD does not change while
-- you edit, so we run it only once per buffer. It is invalidated when the
-- file is reloaded (BufReadPost, see init.lua) or with M.invalidate(bufnr).
M._head_cache = {}

function M.invalidate(bufnr)
  if bufnr then M._head_cache[bufnr] = nil else M._head_cache = {} end
end

local function head_for(core, bufnr, relpath, root)
  local c = M._head_cache[bufnr]
  if c ~= nil then
    if c == false then return nil end
    return c
  end
  -- base_lines: a file that is new relative to the base is painted entirely as added.
  local head = core.git.base_lines(relpath, root)
  M._head_cache[bufnr] = head or false
  return head
end

function M.clear(core, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, core.ns.views, 0, -1)
end

-- Width to pad the deleted-lines bar (red background edge to edge,
-- like GitHub). Uses the width of the window showing the buffer; 0 if there is none.
local function win_width(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then return 0 end
  return vim.api.nvim_win_get_width(winid)
end

--- Paints inline diff decorations on bufnr, comparing the HEAD content
--- against the CURRENT content of the buffer (in memory, reflects unsaved
--- changes). Shows deleted lines as red virtual lines above
--- their position and added lines highlighted in green (unified view, GitHub
--- "inline" style). No-op if the file does not belong to the repo or has no HEAD.
function M.render(core, bufnr)
  M.clear(core, bufnr)

  local relpath = core.git.rel_path(bufnr)
  local root = core.git.root(bufnr)
  if not relpath or not root then return end

  local head_lines = head_for(core, bufnr, relpath, root)
  if not head_lines then return end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hunks = diff.hunks_between(head_lines, buf_lines)
  if #hunks == 0 then return end

  local ns = core.ns.views
  local width = win_width(bufnr)
  local last = vim.api.nvim_buf_line_count(bufnr)

  for _, h in ipairs(hunks) do
    -- Deleted lines: red virtual lines anchored above the position
    -- where they were (the first new line of the hunk). A pure deletion at the end
    -- of the file has no new line below it: it goes BELOW the last line.
    if #h.del_lines > 0 then
      local past_end = h.new_start > last
      local anchor = past_end and math.max(last - 1, 0) or math.max(h.new_start - 1, 0)
      local virt = {}
      for _, dl in ipairs(h.del_lines) do
        local text = dl
        if width > 0 and vim.fn.strdisplaywidth(text) < width then
          text = text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
        end
        virt[#virt + 1] = { { text, "DiffDelete" } }
      end
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, anchor, 0, {
        virt_lines = virt,
        virt_lines_above = not past_end,
      })
    end

    -- Added lines: highlight the whole real line in green.
    for _, lnum in ipairs(h.add_lnums) do
      local row = lnum - 1
      if row >= 0 and row < last then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
          line_hl_group = "DiffAdd",
        })
      end
    end
  end
end

return M
