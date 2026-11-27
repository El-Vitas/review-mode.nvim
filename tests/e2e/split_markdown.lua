-- SPLIT view with markdown files (render-markdown attached). Closing one
-- column of the split with the diff invalidated made Neovim fire
-- DiffUpdated IN THE MIDDLE of win_close; render-markdown's callback calls
-- win_findbuf there and Neovim died with SIGSEGV (a Neovim bug). Each case
-- below closes columns through a different path: if Neovim crashes, the script
-- never reaches "TOTAL" and the runner flags it as having no results.
-- Env: REVIEW_E2E_DIR, REVIEW_E2E_OUT. Commits doc.md into the fixture.
local R = assert(os.getenv("REVIEW_E2E_DIR"))
pcall(vim.api.nvim_del_augroup_by_name, "NeoTreeAutoClose")
local _of = os.getenv("REVIEW_E2E_OUT")
local fails = 0
local function log(s) local fd = io.open(_of, "a"); if fd then fd:write(s, "\n"); fd:close() end end
local function ck(c, t) if c then log("ok   " .. t) else fails = fails + 1; log("FAIL " .. t) end end
local function wait(ms) vim.wait(ms or 500, function() return false end, 10) end

local views = require("review.features.views")
local core = require("review.core")

local md = R .. "/doc.md"
local md2 = R .. "/other.md"
vim.fn.writefile({ "# Doc", "", "| a | b |", "|---|---|", "| 1 | 2 |", "", "text" }, md)
vim.fn.writefile({ "# Other", "", "text" }, md2)
vim.fn.system({ "git", "-C", R, "add", "doc.md", "other.md" })
vim.fn.system({ "git", "-C", R, "commit", "-q", "-m", "docs" })
vim.cmd("cd " .. R)

local function heads()
  local h, d = 0, 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("^review://head/") then h = h + 1 end
    if vim.wo[w].diff then d = d + 1 end
  end
  return h, d
end
local function state_str()
  local parts = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    parts[#parts + 1] = ("%s%s[%s%s%s]"):format(w == vim.api.nvim_get_current_win() and "*" or "",
      vim.api.nvim_buf_get_name(b):gsub("^.*/", ""), vim.wo[w].diff and "diff" or "",
      vim.bo[b].modified and ",mod" or "", vim.bo[b].bufhidden ~= "" and ("," .. vim.bo[b].bufhidden) or "")
  end
  return table.concat(parts, " ")
end
-- Opens `path` and makes an in-memory change to it. TextChanged by hand: in headless
-- nvim_buf_set_lines does not fire it, and it is the event review uses to build the pair.
local function open_changed(path)
  -- `edit!`: reopening the same file with in-memory changes without `!` gives E37.
  local ok, err = pcall(vim.cmd, "edit! " .. path)
  if not ok then log("obs  edit " .. path:gsub("^.*/", "") .. " failed: " .. tostring(err) .. " | " .. state_str()) end
  wait(300)
  vim.api.nvim_buf_set_lines(0, 1, 1, false, { "in-memory change" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
end
local function split_on(path)
  vim.cmd("only")
  open_changed(path)
  views.set(core, "normal"); wait(200)
  views.set(core, "split"); wait()
  local h, d = heads()
  return h == 1 and d == 2
end
local function head_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("^review://head/") then return w end
  end
end

-- 1. markdown → unchanged file (the reported crash case)
ck(split_on(md), "M1 pair over doc.md")
vim.cmd("edit " .. R .. "/nested/deep/f.ts"); wait()
ck(select(1, heads()) == 0, "M1b doc.md → unchanged file: alive and in a single column")

-- 2. markdown → another file with changes
ck(split_on(md), "M2 pair over doc.md")
open_changed(R .. "/src/mod.ts"); wait()
ck(select(1, heads()) == 1, "M2b doc.md → mod.ts: alive and with the pair on mod.ts")

-- 3. code file → markdown with changes, and markdown → markdown
ck(split_on(R .. "/src/keep.ts"), "M3 pair over keep.ts")
open_changed(md); wait()
ck(select(1, heads()) == 1, "M3b keep.ts → doc.md: alive")
open_changed(md2); wait()
ck(select(1, heads()) == 1, "M3c doc.md → other.md: alive")
vim.cmd("edit " .. R .. "/nested/deep/f.ts"); wait()
ck(select(1, heads()) == 0, "M3d other.md → unchanged: alive")

-- 4. switch view from each column with markdown
ck(split_on(md), "M4 pair over doc.md")
views.set(core, "normal"); wait()
ck(select(1, heads()) == 0, "M4b split → normal from the edit column: alive")
ck(split_on(md), "M4c pair over doc.md")
vim.api.nvim_set_current_win(head_win()); views.set(core, "inline"); wait()
ck(select(1, heads()) == 0, "M4d split → inline from the HEAD column: alive")

-- 5. close each column by hand
ck(split_on(md), "M5 pair over doc.md")
vim.api.nvim_win_close(head_win(), true); wait()
ck(select(1, heads()) == 0, "M5b closing the HEAD column by hand: alive")
ck(split_on(md), "M5c pair over doc.md")
vim.cmd("vsplit " .. R .. "/nested/deep/f.ts"); wait()
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.wo[w].diff and not vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("^review://") then
    vim.api.nvim_win_close(w, true); break
  end
end
wait()
ck(select(2, heads()) == 0, "M5d closing the edit column by hand: alive")

-- 6. close the pair's tab
vim.cmd("only")
vim.cmd("tabnew")
ck(split_on(md), "M6 pair over doc.md in another tab")
vim.cmd("tabclose"); wait()
ck(true, "M6b closing the pair's tab: alive")

-- 7. The guards do not leave DiffUpdated ignored.
wait()
ck(not vim.go.eventignore:find("DiffUpdated", 1, true),
  ("M7 eventignore clean at the end (%q)"):format(vim.go.eventignore))

log("TOTAL fails=" .. fails)
vim.cmd("qa!")
