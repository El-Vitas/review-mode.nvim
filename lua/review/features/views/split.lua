-- Global SPLIT view (2 columns), VSCode style, using the NATIVE DIFF MODE.
-- There is a SINGLE split session: a HEAD panel on the left (readonly scratch,
-- with `winfixbuf` so files can NOT be opened in it) and the real editing
-- window on the right. When switching files in the real window, the HEAD panel
-- updates to that file's HEAD (or closes if the file has no HEAD).
local diff = require("review.features.views.diff")

local M = {}
M._session = nil -- { left_win, buf = <scratch>, main_win }

-- ── WRAP alignment ("virtual padding") ─────────────────────────────────────
-- The native diff mode aligns by LINE NUMBER (+filler for additions/deletions),
-- but NOT by SCREEN rows: a long line wraps into more rows on one
-- side than the other → everything below gets out of sync. Solution: for each
-- diff block, we compute how many screen rows it takes on each side (wrap
-- height + native filler) and pad the shorter side with VIRTUAL lines
-- (virt_lines extmarks) so both blocks have the same height. That way the context
-- that follows is aligned row-to-row again. It is recomputed when entering
-- split, when editing and when the width changes (sidebar, resize).
local PAD_NS = vim.api.nvim_create_namespace("review_split_pad")

-- Real TEXT columns of a window (width minus number/sign/fold).
local function text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  if not info then return 80 end
  return math.max(1, info.width - (info.textoff or 0))
end

-- Screen rows taken by `text` wrapped at `tw` columns.
local function wrap_rows(text, tw)
  local w = vim.fn.strdisplaywidth(text)
  if w <= 0 then return 1 end
  return math.max(1, math.ceil(w / tw))
end

local function clear_pad(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, PAD_NS, 0, -1)
  end
end

-- Adds `n` virtual rows BELOW line `lnum0` (0-based) of `buf`.
local function add_pad(buf, lnum0, n)
  if n <= 0 or not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local last = vim.api.nvim_buf_line_count(buf) - 1
  if lnum0 < 0 then lnum0 = 0 elseif lnum0 > last then lnum0 = last end
  local vl = {}
  for _ = 1, n do vl[#vl + 1] = { { "", "ReviewDiffFiller" } } end
  pcall(vim.api.nvim_buf_set_extmark, buf, PAD_NS, lnum0, 0, { virt_lines = vl })
end

--- Recomputes the virtual padding of the current split session (idempotent).
function M.repad()
  local s = M._session
  if not s then return end
  local lw, rw = s.left_win, s.main_win
  if not (lw and rw and vim.api.nvim_win_is_valid(lw) and vim.api.nvim_win_is_valid(rw)) then return end
  local lbuf = s.buf
  local rbuf = vim.api.nvim_win_get_buf(rw)
  if not (vim.api.nvim_buf_is_valid(lbuf) and vim.api.nvim_buf_is_valid(rbuf)) then return end
  clear_pad(lbuf)
  clear_pad(rbuf)
  -- Without wrap the padding does not apply (long lines do not wrap): just clear.
  if not (vim.wo[lw].wrap and vim.wo[rw].wrap) then return end

  local head = s.head or {}
  local edit = vim.api.nvim_buf_get_lines(rbuf, 0, -1, false)
  local twl, twr = text_width(lw), text_width(rw)

  local a = table.concat(head, "\n") .. "\n"
  local b = table.concat(edit, "\n") .. "\n"
  local ok, hunks = pcall(vim.text.diff or vim.diff, a, b, { result_type = "indices", algorithm = "histogram" })
  if not ok or type(hunks) ~= "table" then return end

  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    -- Screen rows of the block on each side (real wrap + native filler, which
    -- expands both sides to max(ca,cb) buffer lines, 1 row per filler).
    local rowsL, rowsR = 0, 0
    for i = sa, sa + ca - 1 do rowsL = rowsL + wrap_rows(head[i] or "", twl) end
    for i = sb, sb + cb - 1 do rowsR = rowsR + wrap_rows(edit[i] or "", twr) end
    rowsL = rowsL + math.max(0, cb - ca) -- native filler on the LEFT
    rowsR = rowsR + math.max(0, ca - cb) -- native filler on the RIGHT
    local delta = rowsL - rowsR
    if delta > 0 then -- the right is shorter → pad the right at the end of the block
      local anchor = (cb > 0) and (sb + cb - 2) or (sb - 1) -- 0-based, below the last line of the block
      add_pad(rbuf, anchor, delta)
    elseif delta < 0 then
      local anchor = (ca > 0) and (sa + ca - 2) or (sa - 1)
      add_pad(lbuf, anchor, -delta)
    end
  end
end

-- Aligns line-by-line VSCode style (linematch/histogram), preserving flags.
local function ensure_diffopt()
  local parts = vim.split(vim.o.diffopt, ",", { trimempty = true })
  local has = {}
  for _, p in ipairs(parts) do has[p:match("^([%w%-]+)") or p] = true end
  local add = {}
  if not has["internal"] then add[#add + 1] = "internal" end
  if not has["filler"] then add[#add + 1] = "filler" end
  if not has["linematch"] then add[#add + 1] = "linematch:60" end
  if not has["algorithm"] then add[#add + 1] = "algorithm:histogram" end
  if not has["indent-heuristic"] then add[#add + 1] = "indent-heuristic" end
  if not has["inline"] then add[#add + 1] = "inline:char" end -- highlight the exact text that changed
  if #add > 0 then vim.o.diffopt = vim.o.diffopt .. "," .. table.concat(add, ",") end
end

-- Are two lists of lines identical?
local function same_lines(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

--- Is `bufnr` the scratch of the HEAD panel?
function M.is_scratch(bufnr)
  return M._session ~= nil and M._session.buf == bufnr
end

--- EDITING window of the split session (the real one, not the HEAD panel), or nil.
function M.main_win()
  local s = M._session
  if s and s.main_win and vim.api.nvim_win_is_valid(s.main_win) then return s.main_win end
end

-- Forces ALL lines visible (no diff folds collapsing what did not
-- change) + diagonal fill, in a window in diff mode.
local function open_all_folds(win)
  if win and vim.api.nvim_win_is_valid(win) then
    -- `[0]` = local to the window (`:setlocal`): without it the global value
    -- changes too and all new windows inherit these folds.
    pcall(function()
      vim.wo[win][0].foldenable = false
      vim.wo[win][0].foldlevel = 99
      vim.wo[win][0].fillchars = "diff:╱"
    end)
  end
end

-- Turns off the diff of window `w` (for the buffer it shows NOW) and gives back
-- the fold/fillchars/highlight options saved when the pair was built.
local function diffoff_restore(w, sv)
  pcall(vim.api.nvim_win_call, w, function() vim.cmd("diffoff") end)
  pcall(function()
    sv = sv or {}
    local wl = vim.wo[w][0]
    if sv.fe == nil then wl.foldenable = true else wl.foldenable = sv.fe end
    wl.foldlevel = sv.fl or 99
    wl.foldmethod = sv.fm or "manual"
    wl.fillchars = sv.fc or ""
    wl.winhighlight = sv.wh or ""
  end)
end

-- Diffs left on in a buffer that is no longer shown in its window:
-- [win][buf] = saved options. 'diff' and the window options are saved
-- PER BUFFER: if the pair is torn down because the window switched to showing another
-- file, `diffoff` turns off the new file's diff, and the previous one's
-- comes back on when that file returns to the window. Only the
-- diffs set by the split are recorded, so a user's `:diffthis` is left alone.
M._stale = {}

--- If `buf` returns to `win` with a diff left by the split, turns it off.
function M.clear_stale(win, buf)
  local per_win = M._stale[win]
  local sv = per_win and per_win[buf]
  if not sv then return end
  per_win[buf] = nil
  if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
    diffoff_restore(win, sv)
  end
end

--- Forgets what was recorded for a window that was closed.
function M.forget_win(win) M._stale[win] = nil end

-- Removes the diff from the real window and restores its fold/fillchars options.
local function restore_main(s)
  local w = s.main_win
  if not (w and vim.api.nvim_win_is_valid(w)) then return end
  -- Clear the virtual padding of the REAL buffer (the scratch wipes itself, but
  -- the actual file keeps its extmarks if we do not delete them here).
  local cur = vim.api.nvim_win_get_buf(w)
  clear_pad(cur)
  if s.main_buf and s.main_buf ~= cur then
    -- The window already shows another file: the pair file's diff is still
    -- stored in this window. It is turned off when that file comes back (clear_stale).
    if vim.api.nvim_buf_is_valid(s.main_buf) then clear_pad(s.main_buf) end
    M._stale[w] = M._stale[w] or {}
    M._stale[w][s.main_buf] = s.saved or {}
  end
  diffoff_restore(w, s.saved)
end

--- Closes the HEAD column without Neovim recomputing the diff IN THE MIDDLE of the close.
--- `:diffoff` leaves the tab's diff invalidated, and when closing a window
--- Neovim resizes the neighbor, sees the invalidated diff and runs :diffupdate,
--- which fires DiffUpdated while the window list is half-changed.
--- A callback that queries windows there (render-markdown calls win_findbuf)
--- made Neovim crash with SIGSEGV. Hence: diff also turned off in this
--- window, recompute at a safe moment, and DiffUpdated ignored only
--- during the close. See docs/decisions.md (B19).
local function close_head_win(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  pcall(vim.api.nvim_win_call, win, function() vim.cmd("diffoff") end)
  pcall(vim.cmd, "diffupdate")
  local ei = vim.go.eventignore
  vim.go.eventignore = (ei == "") and "DiffUpdated" or (ei .. ",DiffUpdated")
  pcall(vim.api.nvim_win_close, win, true) -- scratch: bufhidden=wipe
  vim.go.eventignore = ei
end

-- Guard for a close NOT made by this plugin (the user's `:q` on a
-- window in diff mode): Neovim invalidates the diff when closing it and runs
-- :diffupdate in the middle of the close (same SIGSEGV as close_head_win). It is called
-- from WinClosed, which runs before the window is removed from the layout; DiffUpdated
-- stays ignored until the next tick and is then recomputed normally. When
-- restoring, only our own entry is removed from 'eventignore'.
local guarding = false
function M.guard_diff_close()
  if guarding then return end
  guarding = true
  local ei = vim.go.eventignore
  vim.go.eventignore = (ei == "") and "DiffUpdated" or (ei .. ",DiffUpdated")
  vim.schedule(function()
    local parts = vim.split(vim.go.eventignore, ",", { trimempty = true })
    for i, p in ipairs(parts) do
      if p == "DiffUpdated" then table.remove(parts, i); break end
    end
    vim.go.eventignore = table.concat(parts, ",")
    guarding = false
  end)
end

--- Closes the split session (removes the diff from the real window and closes the HEAD).
function M.teardown()
  local s = M._session
  M._session = nil
  if not s then return end
  restore_main(s)
  close_head_win(s.left_win)
end

-- Creates the HEAD panel (left) for window `main_win`.
local function create_pane(main_win)
  -- Save the fold/fillchars options of the real window to restore them.
  local saved = {
    fe = vim.wo[main_win].foldenable,
    fl = vim.wo[main_win].foldlevel,
    fm = vim.wo[main_win].foldmethod,
    fc = vim.wo[main_win].fillchars,
    wh = vim.wo[main_win].winhighlight,
  }
  vim.api.nvim_set_current_win(main_win)
  vim.cmd("leftabove vsplit")
  local left_win = vim.api.nvim_get_current_win()
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "nofile"
  vim.bo[scratch].bufhidden = "wipe"
  vim.api.nvim_win_set_buf(left_win, scratch)
  pcall(function() vim.wo[left_win][0].winfixbuf = true end) -- do not open files here
  return { left_win = left_win, buf = scratch, main_win = main_win, saved = saved }
end

--- Handles the manual close of one of the split windows: if the HEAD
--- panel or the editing window is closed, removes the diff from the remaining one and cleans up the
--- session (so no column is left stuck in diff mode). Closes done by
--- the plugin itself (teardown) do not get here: they drop the session before closing.
--- @return boolean true if the closed window belonged to the pair
function M.on_win_closed(win)
  local s = M._session
  if not s then return false end
  if win ~= s.left_win and win ~= s.main_win then return false end
  M._session = nil
  local is_left = (win == s.left_win)
  -- Defer: windows cannot be closed/modified INSIDE the WinClosed autocmd
  -- (Neovim aborts with E855). We do it on the next tick.
  vim.schedule(function()
    if is_left then
      restore_main(s)
    else
      close_head_win(s.left_win)
    end
  end)
  return true
end

--- Syncs the HEAD panel with the file of the CURRENT window (the editing one).
--- Creates the session if needed; closes it if the file has no HEAD or is not
--- in the repo (it stays as a single column).
local WH_DEL = "DiffChange:ReviewDiffChange,DiffText:ReviewDiffDelText,DiffAdd:ReviewDiffDelLine,DiffDelete:ReviewDiffFiller"
local WH_ADD = "DiffChange:ReviewDiffChange,DiffText:ReviewDiffAddText,DiffAdd:ReviewDiffAddLine,DiffDelete:ReviewDiffFiller"

function M.sync(core)
  local cur = vim.api.nvim_get_current_win()
  local s = M._session
  if s and cur == s.left_win then return end -- do not act from the HEAD panel

  local buf = vim.api.nvim_win_get_buf(cur)
  if vim.bo[buf].buftype ~= "" then return end -- special window

  local rel = core.git.rel_path(buf)
  if not rel then M.teardown(); return end

  -- REUSE of the SAME file: it is already diffed. Do NOT re-diff (the native diff
  -- updates itself while editing; re-diffing over the same windows corrupts it
  -- —marks everything as changed— and is also slow). We only close if the file
  -- became identical to HEAD again. Cheap: no git, no re-diff.
  if s and s.rel == rel and s.head
      and s.left_win and vim.api.nvim_win_is_valid(s.left_win)
      and s.main_win and vim.api.nvim_win_is_valid(s.main_win) then
    -- Cheap: if the buffer has not changed since the last sync, do nothing.
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    if tick ~= s.tick then
      s.tick = tick
      if same_lines(s.head, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
        M.teardown()
      end
    end
    return
  end

  -- New file or no valid session: prepare a FRESH setup.
  local head = core.git.head_content(rel, core.git.root(buf))
  if not head then M.teardown(); return end -- no HEAD (new file): one column
  if same_lines(head, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
    M.teardown(); return -- no changes: one column
  end

  M.teardown() -- close the previous session (from another file) if there was one
  ensure_diffopt()

  local sess = create_pane(cur)
  sess.rel = rel
  sess.head = head
  sess.tick = vim.api.nvim_buf_get_changedtick(buf)
  sess.main_buf = buf -- the pair's file (the window may switch to showing another)
  M._session = sess

  -- Scratch = contenido HEAD.
  local scratch = sess.buf
  vim.bo[scratch].modifiable = true
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, head)
  vim.bo[scratch].modifiable = false
  vim.bo[scratch].readonly = true
  local ft = vim.bo[buf].filetype
  if ft and ft ~= "" then vim.bo[scratch].filetype = ft end
  pcall(vim.api.nvim_buf_set_name, scratch, "review://head/" .. rel)
  pcall(vim.treesitter.start, scratch) -- same highlighting as the right

  -- Native diff (fresh scratch). diffoff! clears ANY residual diff state
  -- of the tab (otherwise, after a switch the diff misaligns and marks everything).
  pcall(vim.api.nvim_win_call, cur, function() vim.cmd("diffoff!") end)
  pcall(vim.api.nvim_win_call, sess.left_win, function() vim.cmd("diffthis") end)
  pcall(vim.api.nvim_win_call, cur, function() vim.cmd("diffthis") end)
  open_all_folds(sess.left_win)
  open_all_folds(cur)
  -- Diff mode turns off `wrap`. Respect the user's preference (<leader>w);
  -- wrapped by default.
  local wrap = vim.g.review_wrap ~= false
  pcall(function() vim.wo[sess.left_win][0].wrap = wrap end)
  pcall(function() vim.wo[cur][0].wrap = wrap end)
  pcall(function() vim.wo[sess.left_win][0].winhighlight = WH_DEL end)
  pcall(function() vim.wo[cur][0].winhighlight = WH_ADD end)
  vim.api.nvim_set_current_win(cur)
  pcall(vim.cmd, "diffupdate")
  -- Align screen rows (wrap) with virtual padding. Deferred: the wrap heights
  -- depend on the windows' already-settled width.
  if wrap then vim.schedule(M.repad) end
end

return M
