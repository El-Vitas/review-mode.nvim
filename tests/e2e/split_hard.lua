-- HARD split test: measures REAL on-screen DESYNC (screenpos) and verifies
-- that switching view cleans up BOTH panes no matter where the focus is.
local R = assert(os.getenv("REVIEW_E2E_DIR"))
pcall(vim.api.nvim_del_augroup_by_name, "NeoTreeAutoClose")
local _of = os.getenv("REVIEW_E2E_OUT")
local fails = 0
local function log(s) if _of then local fd = io.open(_of, "a"); if fd then fd:write(s, "\n"); fd:close() end end end
local function ck(c, t) if c then log("ok   " .. t) else fails = fails + 1; log("FAIL " .. t) end end

local views = require("review.features.views")
local split = require("review.features.views.split")
local core = require("review.core")

-- File with LONG lines (they wrap) + a change that LENGTHENS one line (so the
-- edited side wraps differently from HEAD → visible desync with wrap).
local long = string.rep("x", 200)
local f = R .. "/src/wrapme.ts"
do
  local L = {}
  for i = 1, 60 do L[i] = "line" .. i .. " " .. long end
  vim.fn.writefile(L, f)
end
vim.fn.system({ "git", "-C", R, "add", "src/wrapme.ts" })
vim.fn.system({ "git", "-C", R, "commit", "-q", "-m", "wrapme" })
do
  local L = vim.fn.readfile(f)
  L[10] = "line10 CHANGED-AND-MUCH-LONGER " .. long .. long -- 2x longer → wraps more
  vim.fn.writefile(L, f)
end

vim.cmd("cd " .. R)
core.git.set_base("HEAD")
vim.cmd("edit " .. f); vim.wait(200)

local function panes()
  local head, edit
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if split.is_scratch(b) then head = w
    elseif vim.bo[b].buftype == "" and vim.bo[b].filetype ~= "neo-tree" then edit = w end
  end
  return head, edit
end
local function count()
  local diff, scratch = 0, 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[w].diff then diff = diff + 1 end
    if split.is_scratch(vim.api.nvim_win_get_buf(w)) then scratch = scratch + 1 end
  end
  return diff, scratch
end

-- ── 1. REAL on-screen DESYNC: same line, same screen row? ──
views.set(core, "normal"); vim.wait(150)
vim.g.review_wrap = true
views.set(core, "split"); vim.wait(500)
do
  local head, edit = panes()
  ck(head and edit, "1 there are 2 columns")
  if head and edit then
    -- Headless check of the alignment padding (screenpos gives 0 without a UI):
    -- with wrap, line 10 is MUCH longer in EDIT than in HEAD, so repad must add
    -- virtual rows to the HEAD side (the shorter one). We count extmarks in the
    -- padding namespace on the scratch buffer.
    vim.wait(200) -- let the deferred repad run
    local ns
    for name, id in pairs(vim.api.nvim_get_namespaces()) do
      if name == "review_split_pad" then ns = id end
    end
    ck(ns ~= nil, "1b the padding namespace exists")
    if ns then
      local hbuf = vim.api.nvim_win_get_buf(head)
      local marks = vim.api.nvim_buf_get_extmarks(hbuf, ns, 0, -1, { details = true })
      local vrows = 0
      for _, m in ipairs(marks) do
        local vl = m[4] and m[4].virt_lines
        if vl then vrows = vrows + #vl end
      end
      log("   virtual padding rows in HEAD = " .. vrows)
      ck(vrows > 0, "1b (WRAP ON) repad added padding to the short side (HEAD)")
    end
  end
end

-- ── 2. Switching view from the EDIT pane cleans up BOTH ──
local head, edit = panes()
if edit then vim.api.nvim_set_current_win(edit) end
views.set(core, "normal"); vim.wait(400)
do
  local d, s = count()
  ck(d == 0 and s == 0, string.format("2 split→normal from EDIT cleans up everything (diff=%d scratch=%d)", d, s))
end

-- ── 3. Switching view from the HEAD pane (scratch) cleans up BOTH ──
views.set(core, "split"); vim.wait(400)
head, edit = panes()
if head then vim.api.nvim_set_current_win(head) end
views.set(core, "normal"); vim.wait(400)
do
  local d, s = count()
  ck(d == 0 and s == 0, string.format("3 split→normal from HEAD cleans up everything (diff=%d scratch=%d)", d, s))
end

-- ── 4. split→inline from HEAD ──
views.set(core, "split"); vim.wait(400)
head, edit = panes()
if head then vim.api.nvim_set_current_win(head) end
views.set(core, "inline"); vim.wait(400)
do
  local d, s = count()
  ck(d == 0 and s == 0, string.format("4 split→inline from HEAD cleans up everything (diff=%d scratch=%d)", d, s))
end

-- ── 5. scrollbind/cursorbind present in both after entering split ──
views.set(core, "normal"); vim.wait(150)
views.set(core, "split"); vim.wait(400)
do
  local h, e = panes()
  if h and e then
    ck(vim.wo[h].scrollbind and vim.wo[e].scrollbind, "5 scrollbind in both")
    ck(vim.wo[h].cursorbind and vim.wo[e].cursorbind, "5b cursorbind in both")
    ck(vim.wo[h].diff and vim.wo[e].diff, "5c diff in both")
  end
end

log("TOTAL fails=" .. fails)
log("__DONE__")
vim.cmd("qa!")
