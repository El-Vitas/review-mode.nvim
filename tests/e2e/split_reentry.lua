-- Verifies that re-invoking the SPLIT view (or switching views) while already in
-- split does NOT misbehave: it does not duplicate windows, leave columns stuck in
-- diff, or blow up. Runs INSIDE nvim against the synthetic repo.
-- Env: REVIEW_E2E_DIR. Prints "SPLIT ok/FAIL ..." and a TOTAL.
local R = assert(os.getenv("REVIEW_E2E_DIR"))
pcall(vim.api.nvim_del_augroup_by_name, "NeoTreeAutoClose")

local views = require("review.features.views")
local split = require("review.features.views.split")
local core = require("review.core")

local out, fails = {}, 0
local _of = os.getenv("REVIEW_E2E_OUT")
local function log(s)
  out[#out + 1] = s
  if _of then local fd = io.open(_of, "a"); if fd then fd:write(s, "\n"); fd:close() end end
end
local function ck(cond, tag)
  if cond then log("ok   " .. tag) else fails = fails + 1; log("FAIL " .. tag) end
end

-- Counts NORMAL windows (buftype "") + the split's HEAD scratch in the tab.
local function count_wins()
  local normal, scratch = 0, 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if split.is_scratch(b) then scratch = scratch + 1
    elseif vim.bo[b].buftype == "" then normal = normal + 1 end
  end
  return normal, scratch
end
-- How many windows of the tab are in diff mode?
local function count_diff()
  local n = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[w].diff then n = n + 1 end
  end
  return n
end

-- Open a file WITH changes vs HEAD (so the split has 2 columns).
-- src/keep.ts has an uncommitted change in the fixture.
core.git.set_base("HEAD") -- base = working tree vs HEAD
vim.cmd("edit " .. R .. "/src/keep.ts")
vim.wait(200)

-- ── 1. Enter split: must create the HEAD pane (1 normal + 1 scratch, 2 in diff) ──
views.set(core, "split"); vim.wait(400)
do
  local n, s = count_wins()
  ck(n == 1 and s == 1, "1 split creates 1 HEAD pane (normal=" .. n .. " scratch=" .. s .. ")")
  ck(count_diff() == 2, "1b both columns in diff mode (diff=" .. count_diff() .. ")")
  ck(split._session ~= nil, "1c there is a split session")
end

-- ── 2. Re-invoke split while in split: NO-OP, does not duplicate windows ──
local sess_before = split._session
views.set(core, "split"); vim.wait(400)
do
  local n, s = count_wins()
  ck(n == 1 and s == 1, "2 re-split does NOT duplicate (normal=" .. n .. " scratch=" .. s .. ")")
  ck(count_diff() == 2, "2b still has 2 columns in diff")
  ck(split._session == sess_before, "2c same session (not recreated)")
end

-- ── 3. Re-invoke through the direct KEYMAP (<leader>rs) while in split ──
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>rs", true, false, true), "x", false)
vim.wait(400)
do
  local n, s = count_wins()
  ck(n == 1 and s == 1, "3 <leader>rs in split does NOT duplicate (normal=" .. n .. " scratch=" .. s .. ")")
end

-- ── 4. split → inline: clean teardown (0 scratch, 0 diff) ──
views.set(core, "inline"); vim.wait(400)
do
  local n, s = count_wins()
  ck(s == 0, "4 inline closes the HEAD pane (scratch=" .. s .. ")")
  ck(count_diff() == 0, "4b no windows in diff after leaving split")
  ck(split._session == nil, "4c session released")
end

-- ── 5. inline → split again: it is recreated healthy ──
views.set(core, "split"); vim.wait(400)
do
  local n, s = count_wins()
  ck(n == 1 and s == 1, "5 re-entering split after inline (normal=" .. n .. " scratch=" .. s .. ")")
  ck(count_diff() == 2, "5b 2 columns in diff again")
end

-- ── 6. split → normal: teardown, restores the single window ──
views.set(core, "normal"); vim.wait(400)
do
  local n, s = count_wins()
  ck(s == 0 and count_diff() == 0, "6 normal cleans up split (scratch=" .. s .. " diff=" .. count_diff() .. ")")
end

-- ── 7. Cycling rv repeatedly leaves no garbage (normal→inline→split→normal x2) ──
for i = 1, 2 do
  for _, m in ipairs({ "inline", "split", "normal" }) do
    views.set(core, m); vim.wait(250)
  end
end
do
  local n, s = count_wins()
  ck(n == 1 and s == 0 and count_diff() == 0,
    "7 repeated cycling ends clean (normal=" .. n .. " scratch=" .. s .. " diff=" .. count_diff() .. ")")
end

log("TOTAL fails=" .. fails)
if _of then local fd = io.open(_of, "a"); if fd then fd:write("__DONE__\n"); fd:close() end end
vim.cmd("qa!")
