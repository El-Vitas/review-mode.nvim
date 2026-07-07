local render = require("review.features.comments.render")

local M = {}
local saved_guicursor = nil

local function clamp(bufnr, lnum)
  local last = vim.api.nvim_buf_line_count(bufnr)
  if last < 1 then return 1 end
  if lnum < 1 then return 1 end
  if lnum > last then return last end
  return lnum
end

local function find_at(core, rel, lnum)
  for _, c in ipairs(core.state.for_path(rel)) do
    local lo = math.min(c.lnum, c.end_lnum or c.lnum)
    local hi = math.max(c.lnum, c.end_lnum or c.lnum)
    if lnum >= lo and lnum <= hi then return c end
  end
  return nil
end

function M._add(core, bufnr, lnum, end_lnum, text)
  local rel = core.git.rel_path(bufnr)
  if not rel then return nil end

  if text == nil or vim.trim(text) == "" then return nil end

  lnum = clamp(bufnr, lnum or 1)
  end_lnum = clamp(bufnr, end_lnum or lnum)
  if end_lnum < lnum then
    lnum, end_lnum = end_lnum, lnum
  end

  local c = core.state.add({ path = rel, lnum = lnum, end_lnum = end_lnum, text = text })
  render.render(core, bufnr)
  core.state.persist()
  return c
end

function M._delete_at(core, bufnr, lnum)
  local rel = core.git.rel_path(bufnr)
  if not rel then return false end

  lnum = clamp(bufnr, lnum)
  local c = find_at(core, rel, lnum)
  if not c then return false end

  local ok = core.state.remove(c.id)
  render.render(core, bufnr)
  core.state.persist()
  return ok
end

function M._resolve_at(core, bufnr, lnum)
  local rel = core.git.rel_path(bufnr)
  if not rel then return false end

  lnum = clamp(bufnr, lnum)
  local c = find_at(core, rel, lnum)
  if not c then return false end

  local ok = core.state.update(c.id, { resolved = not c.resolved })
  render.render(core, bufnr)
  core.state.persist()
  return ok
end

function M.toggle(core)
  _G.review_mode_active = not _G.review_mode_active
  if _G.review_mode_active then
    saved_guicursor = vim.o.guicursor
    vim.o.guicursor = "a:blinkon0-Cursor/lCursor"
  else
    vim.o.guicursor = saved_guicursor or vim.o.guicursor
  end
end

function M.add_here(core, opts)
  opts = opts or {}
  local Popup = require("nui.popup")
  local bufnr = vim.api.nvim_get_current_buf()

  local mode_v = vim.fn.mode()
  local lnum, end_lnum
  if mode_v == "v" or mode_v == "V" or mode_v == "\22" then
    lnum = vim.fn.line("v")
    end_lnum = vim.fn.line(".")
    vim.cmd("normal! \27")
  else
    lnum = vim.fn.line(".")
    end_lnum = lnum
  end

  local popup = Popup({
    enter = true,
    focusable = true,
    border = { style = "rounded", text = { top = " Comentario " } },
    position = "50%",
    size = { width = 60, height = 5 },
    buf_options = { filetype = "markdown" },
  })

  popup:mount()

  local function confirm()
    local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
    local text = table.concat(lines, "\n")
    popup:unmount()
    M._add(core, bufnr, lnum, end_lnum, text)
  end

  local function cancel()
    popup:unmount()
  end

  popup:map("n", opts.confirm_key or "<CR>", confirm, { noremap = true })
  popup:map("n", opts.cancel_key or "<Esc>", cancel, { noremap = true })
end

function M.delete_here(core)
  return M._delete_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

function M.resolve_here(core)
  return M._resolve_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

return M
