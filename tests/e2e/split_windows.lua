-- SPLIT view and windows: what happens when switching file, window, tab,
-- when closing one of the two columns, or when opening special windows.
-- Invariant in ALL cases: there is at most ONE pair (HEAD column + edit
-- column), never an orphaned HEAD column nor a window stuck in diff mode,
-- and the split's options do not leak into other windows.
-- Runs INSIDE nvim (real config) against fixture.sh's synthetic repo. It does not
-- write repo files: the changes it needs are in memory.
-- Env: REVIEW_E2E_DIR, REVIEW_E2E_OUT.
local R = assert(os.getenv("REVIEW_E2E_DIR"))
pcall(vim.api.nvim_del_augroup_by_name, "NeoTreeAutoClose")
local _of = os.getenv("REVIEW_E2E_OUT")
local fails = 0
local function log(s) if _of then local fd = io.open(_of, "a"); if fd then fd:write(s, "\n"); fd:close() end end end
local function ck(c, t) if c then log("ok   " .. t) else fails = fails + 1; log("FAIL " .. t) end end
local function wait(ms) vim.wait(ms or 400, function() return false end, 10) end

local views = require("review.features.views")
local split = require("review.features.views.split")
local core = require("review.core")

-- State of ALL tabs: HEAD columns (by buffer name, so orphans from an old
-- session show up too) and windows in diff mode.
local function state(tab)
  local head, diff, normal = 0, 0, 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab or 0)) do
    local b = vim.api.nvim_win_get_buf(w)
    local name = vim.api.nvim_buf_get_name(b)
    if name:find("^review://head/") then head = head + 1 end
    if vim.wo[w].diff then diff = diff + 1 end
    if vim.api.nvim_win_get_config(w).relative == "" then normal = normal + 1 end
  end
  return head, diff, normal
end
local function pair(tag) -- exactly one pair in the current tab
  local h, d = state()
  ck(h == 1 and d == 2, ("%s: one HEAD+edit pair (head=%d diff=%d)"):format(tag, h, d))
end
local function single(tag) -- a single column, no diff
  local h, d = state()
  ck(h == 0 and d == 0, ("%s: a single column (head=%d diff=%d)"):format(tag, h, d))
end
local function head_shows(rel)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
    if name:find("^review://head/") then return name == "review://head/" .. rel end
  end
  return false
end
local function edit_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].buftype == "" and not vim.api.nvim_buf_get_name(b):find("^review://") then return w end
  end
end

-- A file that differs from HEAD only in memory (without writing to the repo).
local function load_modified(rel)
  local b = vim.fn.bufadd(R .. "/" .. rel); vim.fn.bufload(b)
  vim.bo[b].buflisted = true
  vim.api.nvim_buf_set_lines(b, 0, 0, false, { "// in-memory change" })
  return b
end

vim.cmd("cd " .. R)
core.git.set_base("HEAD")
vim.cmd("only")
vim.cmd("edit " .. R .. "/src/keep.ts") -- modified in the working tree
local mod = load_modified("src/mod.ts")
local before_wh, before_fe = vim.go.winhighlight, vim.go.foldenable

views.set(core, "split"); wait()
pair("W1 split over keep.ts")

-- ── Switch file in the edit column ──
vim.api.nvim_set_current_win(edit_win())
vim.cmd("buffer " .. mod); wait()
pair("W2 switch to another file with changes")
ck(head_shows("src/mod.ts"), "W2b the HEAD column follows the new file")

vim.cmd("edit " .. R .. "/nested/deep/f.ts"); wait()
single("W3 file identical to HEAD")

vim.cmd("edit " .. R .. "/src/untracked.ts"); wait()
single("W4 new file with no HEAD")

local outside = vim.fn.tempname() .. ".ts"
vim.fn.writefile({ "outside the repo" }, outside)
vim.cmd("edit " .. outside); wait()
single("W5 file outside the repo")
ck(vim.wo.foldenable == before_fe, "W5b outside the repo the folds are not touched")

vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
pair("W6 go back to a file with changes")

-- ── The split's options do not leak into the global scope ──
ck(vim.go.winhighlight == before_wh, ("W7 global winhighlight untouched (%q)"):format(vim.go.winhighlight))
ck(vim.go.foldenable == before_fe, "W7b global foldenable untouched")
vim.cmd("botright new"); wait()
ck(vim.wo.winhighlight == before_wh and not vim.wo.diff, "W7c a new window is born without the split's highlight")
vim.cmd("close"); wait()
pair("W7d closing that window does not break the pair")

-- ── Focus on special windows: the pair stays as it is ──
vim.cmd("help help"); wait()
local h, d = state()
ck(h == 1 and d == 2, ("W8 opening :help does not dismantle the pair (head=%d diff=%d)"):format(h, d))
vim.cmd("helpclose"); wait()
pair("W8b close :help")

vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>e", true, false, true), "x", false); wait(1000)
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "neo-tree" then vim.api.nvim_set_current_win(w) end
end
wait()
h, d = state()
ck(h == 1 and d == 2, ("W9 focus on the tree does not dismantle the pair (head=%d diff=%d)"):format(h, d))
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>e", true, false, true), "x", false); wait(600)
vim.api.nvim_set_current_win(edit_win()); wait()
pair("W9b close the tree")

-- ── A single HEAD column even with two edit windows ──
vim.cmd("vsplit"); vim.cmd("buffer " .. mod); wait()
h, d = state()
ck(h == 1 and d == 2, ("W10 second edit window: there is still ONE pair (head=%d diff=%d)"):format(h, d))
-- The pair moved to the new window: closing it means closing its edit column.
vim.cmd("close"); wait()
single("W10b closing the window that held the pair leaves a single column")
ck(views.mode == "normal", "W10c ...and the view switches to normal (same rule as closing a column)")
vim.api.nvim_set_current_win(edit_win()); wait()
views.set(core, "split"); wait()
pair("W10d back to split")

-- ── Close one of the two columns by hand ──
local head_win
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("^review://head/") then head_win = w end
end
vim.api.nvim_win_close(head_win, true); wait()
single("W11 closing the HEAD column by hand leaves a single column")
ck(views.mode == "normal", "W11b ...and the view switches to normal (mode=" .. tostring(views.mode) .. ")")
vim.cmd("botright new"); wait(); vim.cmd("close"); wait()
vim.cmd("edit " .. R .. "/src/mod.ts"); wait(); vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
single("W11c the pair does NOT reappear when changing focus or file")

views.set(core, "split"); wait()
pair("W12 back to split with the key")
vim.cmd("vsplit " .. R .. "/nested/deep/f.ts"); wait() -- third window so nvim is not left empty
vim.cmd("wincmd p"); wait()
local ew = vim.api.nvim_get_current_win()
local hw
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("^review://head/") then hw = w end
end
if ew ~= hw and vim.wo[ew].diff then
  vim.api.nvim_win_close(ew, true); wait()
  h, d = state()
  ck(h == 0 and d == 0, ("W13 closing the edit column also closes the HEAD one (head=%d diff=%d)"):format(h, d))
  ck(views.mode == "normal", "W13b ...and the view switches to normal")
else
  log("obs  W13 could not locate the pair's edit column")
end

-- ── Tabs ──
vim.cmd("only"); vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
views.set(core, "normal"); wait(); views.set(core, "split"); wait()
pair("W14 pair in tab 1")
local tab1 = vim.api.nvim_get_current_tabpage()
vim.cmd("tabnew"); vim.cmd("buffer " .. mod); wait()
pair("W14b pair in tab 2")
local h1, d1 = state(tab1)
ck(h1 == 0 and d1 == 0, ("W14c tab 1 is not left with dangling columns (head=%d diff=%d)"):format(h1, d1))
vim.cmd("tabclose"); wait()
-- Closing the tab closes both columns of the pair: same rule as W11/W13.
single("W15 closing the pair's tab: tab 1 is left with one column")
ck(views.mode == "normal", "W15b ...and the view switches to normal")

-- Switching views is NOT a manual close: it must not force normal.
views.set(core, "split"); wait()
pair("W16 split again")
views.set(core, "inline"); wait()
ck(views.mode == "inline", "W16b split → inline stays in inline (the plugin did the close)")
views.set(core, "split"); wait()
vim.cmd("edit " .. R .. "/nested/deep/f.ts"); wait()
ck(views.mode == "split", "W16c going to an unchanged file does not turn off the global split")
vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
pair("W16d going back to a file with changes rebuilds the pair")

-- ── Going back to a file after leaving the split ──
-- 'diff' and the highlight are stored PER BUFFER in each window: if the pair is
-- dismantled while the window shows another file, on returning the previous one
-- came back with diff on and it seemed <leader>rn/ri/rv changed nothing.
vim.cmd("only"); vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
views.set(core, "split"); wait()
pair("W18 pair over keep.ts")
vim.cmd("edit " .. R .. "/nested/deep/f.ts"); wait()
views.set(core, "normal"); wait()
vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
single("W18b back to keep.ts in normal: no stuck diff")
ck(vim.wo.winhighlight == before_wh, ("W18c ...nor the split's highlight (%q)"):format(vim.wo.winhighlight))
views.set(core, "inline"); wait()
single("W18d inline over keep.ts: no diff")
views.set(core, "split"); wait()
pair("W18e split again over keep.ts")
views.set(core, "normal"); wait()

-- ── A hand-made diff is left alone ──
vim.cmd("only"); vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
vim.cmd("diffthis"); vim.cmd("vsplit " .. R .. "/src/mod.ts"); vim.cmd("diffthis"); wait()
vim.cmd("wincmd p"); wait(); vim.cmd("wincmd p"); wait()
local manual = 0
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do if vim.wo[w].diff then manual = manual + 1 end end
ck(manual == 2, ("W19 a user's :diffthis stays active when changing window (diff=%d)"):format(manual))
vim.cmd("diffoff!"); vim.cmd("only"); wait()

-- ── The real shortcuts cycle through the three views ──
vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
local seen = {}
for _ = 1, 3 do
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>rv", true, false, true), "mx", false); wait()
  seen[#seen + 1] = views.mode
end
ck(table.concat(seen, ",") == "inline,split,normal",
  "W20 <leader>rv cycles inline → split → normal (" .. table.concat(seen, ",") .. ")")

views.set(core, "normal"); wait()
single("W17 normal at the end")
log("TOTAL fails=" .. fails)
vim.cmd("qa!")
