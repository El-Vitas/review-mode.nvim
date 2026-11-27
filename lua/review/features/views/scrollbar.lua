-- Integration with petertriho/nvim-scrollbar + change navigation.
-- Marks on the scrollbar the lines changed vs HEAD, VERY NOTICEABLY (solid glyph
-- `█` and bright colors: green=added, orange=changed, red=deleted), and
-- exposes the change RANGES to jump with :ReviewNextChange / :ReviewChanges.
local M = {}

-- Cache of the HEAD content per buffer (git show is a subprocess). It is released when
-- closing or reloading the buffer, when the base changes and when focus returns to Neovim
-- (a commit made outside changes HEAD without touching the file).
local _head = {}
-- Hunk cache per (buffer, changedtick).
local _hunks = {}

--- Forgets the cached HEADs and hunks (of one buffer, or of all).
function M.invalidate(bufnr)
  if bufnr then
    _head[bufnr] = nil
    _hunks[bufnr] = nil
  else
    _head = {}
    _hunks = {}
  end
end

local function head_for(core, bufnr, rel, root)
  local c = _head[bufnr]
  if c ~= nil then return c or nil end
  local lines = core.git.base_lines(rel, root) -- new file: everything is added
  _head[bufnr] = lines or false
  return lines
end

--- Change hunks of the buffer vs HEAD. Returns a list of
--- { sl, el, kind } (1-based, in the buffer). kind = "add"|"change"|"delete".
function M.hunks(core, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end
  if vim.bo[bufnr].buftype ~= "" then return {} end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _hunks[bufnr]
  if cached and cached.tick == tick then return cached.hunks end

  local rel = core.git.rel_path(bufnr)
  local root = core.git.root(bufnr)
  local out = {}
  if rel and root then
    local head = head_for(core, bufnr, rel, root)
    if head then
      local a = table.concat(head, "\n")
      local b = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      if a ~= b then
        local hunks = (vim.text.diff or vim.diff)(a, b, { result_type = "indices" }) or {}
        for _, h in ipairs(hunks) do
          local count_a, start_b, count_b = h[2], h[3], h[4]
          if count_a == 0 then
            out[#out + 1] = { sl = start_b, el = start_b + count_b - 1, kind = "add" }
          elseif count_b == 0 then
            out[#out + 1] = { sl = math.max(1, start_b), el = math.max(1, start_b), kind = "delete" }
          else
            out[#out + 1] = { sl = start_b, el = start_b + count_b - 1, kind = "change" }
          end
        end
      end
    end
  end
  _hunks[bufnr] = { tick = tick, hunks = out }
  return out
end

local KIND_TYPE = { add = "GitAdd", change = "GitChange", delete = "GitDelete" }

-- Handler for nvim-scrollbar: marks each changed line with a NOTICEABLE glyph.
local function handler(core, bufnr)
  local marks = {}
  for _, h in ipairs(M.hunks(core, bufnr)) do
    local ty = KIND_TYPE[h.kind]
    for l = h.sl, h.el do
      marks[#marks + 1] = { line = l - 1, text = "█", type = ty, level = 2 }
    end
  end
  return marks
end

-- BRIGHT, bold colors for the marks (by default they fall back to black and are
-- not visible). Overridable by the user (re-applied on ColorScheme).
local function ensure_hl()
  local defs = {
    ScrollbarGitAdd = "#a6e3a1",       -- green
    ScrollbarGitAddHandle = "#a6e3a1",
    ScrollbarGitChange = "#fab387",    -- orange
    ScrollbarGitChangeHandle = "#fab387",
    ScrollbarGitDelete = "#f38ba8",    -- red
    ScrollbarGitDeleteHandle = "#f38ba8",
  }
  for name, fg in pairs(defs) do
    vim.api.nvim_set_hl(0, name, { fg = fg, bold = true })
  end
end

function M.setup(core)
  local ok, handlers = pcall(require, "scrollbar.handlers")
  if not ok then return end -- nvim-scrollbar not installed → no-op

  handlers.register("review", function(bufnr) return handler(core, bufnr) end)
  ensure_hl()

  local grp = vim.api.nvim_create_augroup("ReviewScrollbar", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = grp, callback = ensure_hl })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = grp,
    callback = function(a)
      _head[a.buf] = nil
      _hunks[a.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = grp,
    callback = function(a) _head[a.buf] = nil end,
  })

  -- When the comparison base changes: clear caches and redraw the marks.
  if core.events then
    core.events.on("base:changed", function()
      _head = {}
      _hunks = {}
      vim.schedule(function() pcall(require("scrollbar.handlers").show) end)
    end)
  end
end

return M
