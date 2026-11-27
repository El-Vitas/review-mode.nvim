-- Gutter with NESTED brackets: replaces the statuscolumn of the windows that
-- show repo files to draw, line by line, one bracket for EACH
-- comment that covers it — stacked by nesting and colored per comment
-- (┌ top, │ middle, └ bottom, ▌ single line). Preserves signs (gitsigns) and number.
--
-- The sign column only supports 1 sign per line, so the nesting and the
-- continuity of │ (when comments overlap) can only be achieved this way.
local render = require("review.features.comments.render")

local M = {}

local PALETTE_N = 6

M._core = nil
M._prev = {}   -- win -> previous statuscolumn (to restore)
M._gen = 0     -- generation; goes up when comments change (invalidates cache)
M._cache = {}  -- buf -> { gen, color = {id->idx}, ranked = comment[] }

-- Stable ranking per line (to assign color) + id->color map. Cached per
-- (buf, generation).
local function ranked_for(buf)
  local cached = M._cache[buf]
  if cached and cached.gen == M._gen then return cached end

  local core = M._core
  local rel = core and core.git.rel_path(buf)
  local ranked, color = {}, {}
  if rel then
    -- Replies (reply_to) do not draw their own bracket: they live in the thread.
    for _, c in ipairs(core.state.for_path(rel)) do
      -- file_level has no line → it draws no bracket in the gutter.
      if not c.reply_to and not c.file_level then ranked[#ranked + 1] = c end
    end
    table.sort(ranked, function(a, b) return (a.lnum or 0) < (b.lnum or 0) end)
    for i, c in ipairs(ranked) do color[c.id] = ((i - 1) % PALETTE_N) + 1 end
  end
  local entry = { gen = M._gen, ranked = ranked, color = color }
  M._cache[buf] = entry
  return entry
end

--- Statusline string with the brackets of line `lnum` of buffer `buf`.
--- `cont`=true forces the continuation stroke `│` (for wrapped lines),
--- so the bracket stays CONTINUOUS and does not repeat `┌`/`└` on each wrap.
function M.brackets(buf, lnum, cont)
  if render.hidden then return "" end -- respect the hide/show toggle
  local entry = ranked_for(buf)
  if #entry.ranked == 0 then return "" end

  -- Comments covering the line, sorted outer-first (lo asc, span desc)
  -- so the nesting goes from outside to inside (left -> right).
  local cov = {}
  for _, c in ipairs(entry.ranked) do
    local lo = math.min(c.lnum, c.end_lnum or c.lnum)
    local hi = math.max(c.lnum, c.end_lnum or c.lnum)
    if lnum >= lo and lnum <= hi then
      cov[#cov + 1] = { c = c, lo = lo, hi = hi }
    end
  end
  if #cov == 0 then return "" end
  table.sort(cov, function(a, b)
    if a.lo ~= b.lo then return a.lo < b.lo end
    return (a.hi - a.lo) > (b.hi - b.lo)
  end)

  local parts = {}
  for _, e in ipairs(cov) do
    local ch
    if cont then
      ch = "│" -- wrapped lines: continuous stroke, no corners
    elseif e.lo == e.hi then
      ch = "▌"
    elseif lnum == e.lo then
      ch = "┌"
    elseif lnum == e.hi then
      ch = "└"
    else
      ch = "│"
    end
    local hl
    if e.c.resolved then
      hl = "ReviewCommentSignResolved"
    elseif e.c.author and e.c.author ~= "user" then
      hl = "ReviewCommentSignAgent"
    else
      hl = "ReviewCommentSign" .. entry.color[e.c.id]
    end
    parts[#parts + 1] = "%#" .. hl .. "#" .. ch
  end
  return table.concat(parts) .. "%*"
end

--- statuscolumn: fold + signs (gitsigns) + brackets + number (right).
function M.render()
  local win = vim.g.statusline_winid
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok then return "" end

  -- v:virtnum: 0 = real line; >0 = wrapped part (wrap); <0 = virtual line
  -- (our badge/peek). On virtual lines we do NOT draw a bracket (avoids broken
  -- `┌`/`│` fragments over the badge/peek); on wraps, a continuous stroke.
  local virt = vim.v.virtnum
  local brackets
  if virt < 0 then
    brackets = ""
  elseif virt > 0 then
    brackets = M.brackets(buf, vim.v.lnum, true)
  else
    brackets = M.brackets(buf, vim.v.lnum)
  end

  local numcol = ""
  if virt == 0 then
    local wo = vim.wo[win]
    if wo.number or wo.relativenumber then
      local n = vim.v.lnum
      if wo.relativenumber and vim.v.relnum ~= 0 then n = vim.v.relnum end
      numcol = tostring(n)
    end
  end

  return "%C%s" .. brackets .. " %=" .. numcol .. " "
end

_G.ReviewStatusCol = M.render

local OURS = "%!v:lua.ReviewStatusCol()"

local function enable(win)
  if not vim.api.nvim_win_is_valid(win) then return end
  if vim.wo[win].statuscolumn == OURS then return end -- already active (do not save ours as prev)
  if M._prev[win] == nil then M._prev[win] = vim.wo[win].statuscolumn end
  vim.wo[win].statuscolumn = OURS
end

local function disable(win)
  if M._prev[win] ~= nil and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].statuscolumn = M._prev[win]
    M._prev[win] = nil
  end
end

function M.setup(core)
  M._core = core

  local grp = vim.api.nvim_create_augroup("ReviewGutter", { clear = true })
  -- Enables our own gutter ONLY in windows with normal repo files.
  -- Special buffers (neo-tree, terminal, quickfix, prompts…) are ignored
  -- entirely: their statuscolumn is not touched and git is not run, so as not to
  -- interfere with those plugins (e.g. the neo-tree toggle).
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = grp,
    callback = function(a)
      local buf = a.buf
      local win = vim.api.nvim_get_current_win()
      local isfile = false
      if vim.bo[buf].buftype == "" then -- only real files (not neo-tree/term/qf)
        local ok, rel = pcall(core.git.rel_path, buf)
        isfile = ok and rel ~= nil
      end
      if isfile then
        pcall(enable, win)
      else
        pcall(disable, win)
        -- Splits inherit window-locals: if this special window (neo-tree,
        -- etc.) ended up with OUR statuscolumn inherited, clear it so we do not
        -- run our function there or interfere with that plugin.
        if vim.api.nvim_win_is_valid(win) and vim.wo[win].statuscolumn == OURS then
          vim.wo[win].statuscolumn = ""
        end
      end
    end,
  })

  -- Release cache/state entries when closing buffers/windows (keeps them from
  -- growing with every opened file/split).
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = grp,
    callback = function(a) M._cache[a.buf] = nil end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = grp,
    callback = function(a)
      local win = tonumber(a.match)
      if win then M._prev[win] = nil end
    end,
  })

  -- When comments change, invalidate the cache and redraw.
  if core.events then
    core.events.on("comments:changed", function()
      M._gen = M._gen + 1
      M._cache = {}
      vim.schedule(function() pcall(vim.cmd, "redrawstatus!") end)
    end)
  end
end

return M
