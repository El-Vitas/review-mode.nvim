-- E2E driver. Runs INSIDE nvim (real config) against the synthetic repo.
-- Env: REVIEW_E2E_DIR, REVIEW_E2E_C0, REVIEW_E2E_C1. Prints "E2E ok/FAIL ...".
local R  = assert(os.getenv("REVIEW_E2E_DIR"))
local C0 = assert(os.getenv("REVIEW_E2E_C0"))
local C1 = assert(os.getenv("REVIEW_E2E_C1"))

-- The config's NeoTreeAutoClose autocmd closes nvim when only neo-tree is left;
-- the test manipulates windows, so we disable it to avoid killing the driver.
pcall(vim.api.nvim_del_augroup_by_name, "NeoTreeAutoClose")

local core   = require("review.core")
local review = require("review")
local basef  = require("review.features.base")
local mgr    = require("neo-tree.sources.manager")

local out, fails = {}, 0
local _of = os.getenv("REVIEW_E2E_OUT")
local function log(s)
  out[#out + 1] = s
  if _of then local fd = io.open(_of, "a"); if fd then fd:write(s, "\n"); fd:close() end end -- incremental (to see progress on a hang)
end
local function ck(cond, tag)
  if cond then log("ok   " .. tag) else fails = fails + 1; log("FAIL " .. tag) end
end

local function tc(k) return vim.api.nvim_replace_termcodes(k, true, false, true) end
local function press(k) vim.api.nvim_feedkeys(tc(k), "x", false); vim.wait(650) end
local function set_base(r) core.git.set_base(r); basef.apply_gitsigns(r); core.events.emit("base:changed", { ref = r }); vim.wait(300) end
local function closeall() pcall(vim.cmd, "Neotree close"); vim.wait(250) end
local function abs(rel) return R .. "/" .. rel end

local function nt_win() for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local b = vim.api.nvim_win_get_buf(w); if vim.bo[b].filetype == "neo-tree" then return w, b end end end
local function source() local _, b = nt_win(); if not b then return "NONE" end
  local ok, s = pcall(vim.api.nvim_buf_get_var, b, "neo_tree_source"); return (ok and s) or "?" end
local function nt_base() local st = mgr.get_state("git_status"); if not (st and st.git_base_by_worktree) then return "NO" end
  for _, v in pairs(st.git_base_by_worktree) do return v end; return "EMPTY" end
local function want() return review.effective_base() or "EMPTY" end
local function tree_has(name) local st = mgr.get_state("git_status"); if not (st and st.tree) then return false end
  local f = false
  local function walk(n) if n.type == "file" and n:get_id():find(name, 1, true) then f = true end
    if n:has_children() then for _, c in ipairs(st.tree:get_nodes(n:get_id())) do walk(c) end end end
  for _, n in ipairs(st.tree:get_nodes() or {}) do walk(n) end; return f end
local function cursor_id() local w = nt_win(); if not w then return "NO-WIN" end
  local ln = vim.api.nvim_win_get_cursor(w)[1]; local st = mgr.get_state("git_status")
  if not (st and st.tree) then return "NO-TREE" end
  local ok, nd = pcall(function() return st.tree:get_node(ln) end); return (ok and nd and nd:get_id()) or "NO-NODE" end

-- ── A. effective_base ──
set_base("HEAD"); ck(review.effective_base() == nil, "A1 HEAD→nil")
set_base(":");    ck(review.effective_base() == nil, "A2 index→nil")
set_base(C0);     ck(review.effective_base() == C0, "A3 commit→ref")
core.git.set_base(""); ck(core.git.base_ref == "HEAD" and core.git.base_label == nil, "A4 empty→HEAD")

-- ── B. head_content / changed_files ──
set_base(C0)
do
  local root = core.git.root() or R
  local hc = core.git.head_content("src/mod.ts", root)
  local exp = vim.fn.systemlist({ "git", "-C", root, "show", C0 .. ":src/mod.ts" })
  ck(hc and table.concat(hc, "\n") == table.concat(exp, "\n"), "B1 head_content(mod,C0)==git show")
end
set_base(C1)
ck(core.git.head_content("src/newC2.ts", core.git.root() or R) == nil, "B2 newC2 does not exist in C1→nil")
set_base("HEAD")
do
  local root = core.git.root() or R
  local hc = core.git.head_content("src/keep.ts", root)
  local exp = vim.fn.systemlist({ "git", "-C", root, "show", "HEAD:src/keep.ts" })
  ck(hc and table.concat(hc, "\n") == table.concat(exp, "\n"), "B3 head_content(keep,HEAD)==git show")
end
set_base(C0)
do
  local cf = core.git.changed_files(core.git.root() or R) or {}
  local set = {}; for _, f in ipairs(cf) do set[f] = true end
  ck(set["src/newC1.ts"] and set["src/newC2.ts"] and set["src/mod.ts"], "B4 changed_files(C0) has added+mod")
  ck(not set["nested/deep/f.ts"] == false, "B4b changed_files(C0) includes the modified deep file")
end

-- ── C + D + F for each base ──
local bases = {
  { n = "C0",   ref = C0,     reveal = "src/newC1.ts" },
  { n = "C1",   ref = C1,     reveal = "src/newC2.ts" },
  { n = "HEAD", ref = "HEAD", reveal = "src/keep.ts" },   -- working change
  { n = "idx",  ref = ":",    reveal = "src/staged.ts" }, -- staged
}
for _, bc in ipairs(bases) do
  set_base(bc.ref); closeall()
  vim.cmd("ReviewSidebar changed"); vim.wait(650)
  ck(source() == "git_status", "C1/" .. bc.n .. " open→git_status (got " .. source() .. ")")
  ck(nt_base() == want() or nt_base() == "NO", "C2/" .. bc.n .. " git_base==" .. want() .. " (got " .. nt_base() .. ")")
  ck(tree_has("untracked.ts"), "C5/" .. bc.n .. " untracked in tree")
  -- D1 reveal in git_status highlights the file
  vim.cmd("edit " .. vim.fn.fnameescape(abs(bc.reveal))); vim.wait(250)
  press(" E")
  local cid = cursor_id()
  ck(cid ~= "NO-WIN" and cid:find(vim.fn.fnamemodify(bc.reveal, ":t"), 1, true) ~= nil,
    "D1/" .. bc.n .. " reveal highlights " .. bc.reveal .. " (cursor=" .. tostring(cid and vim.fn.fnamemodify(cid, ":t")) .. ")")
  -- F: close/reopen preserves base + file
  press(" e"); vim.wait(150); press(" e")
  ck(nt_base() == want() or nt_base() == "NO", "F2/" .. bc.n .. " reopen git_base==" .. want())
  ck(tree_has(vim.fn.fnamemodify(bc.reveal, ":t")), "F3/" .. bc.n .. " reopen file is still in the tree")
end

-- ── C3/C4: tree contents vs base C0 (added/mod/del/ren yes; committed keep no) ──
set_base(C0); closeall(); vim.cmd("ReviewSidebar changed"); vim.wait(650)
ck(tree_has("newC1.ts") and tree_has("newC2.ts"), "C3 added vs C0 in tree")
ck(tree_has("mod.ts"), "C3b modified vs C0 in tree")
ck(tree_has("ren_new.ts"), "L2 renamed vs C0 in tree")
ck(tree_has("del.ts"), "L1 deleted vs C0 in tree (D)")

-- ── D2: reveal in FILESYSTEM (reported bug) ──
set_base(C0); closeall()
vim.cmd("Neotree action=show source=filesystem position=right"); vim.wait(650)
ck(source() == "filesystem", "D2-pre filesystem open")
vim.cmd("edit " .. vim.fn.fnameescape(abs("nested/deep/f.ts"))); vim.wait(250)
press(" E")
do
  -- in filesystem the tree belongs to the filesystem source; read the node under the cursor
  local w, b = nt_win(); local cid = "NO"
  if w then
    local st = mgr.get_state("filesystem")
    local ln = vim.api.nvim_win_get_cursor(w)[1]
    local ok, nd = pcall(function() return st.tree:get_node(ln) end)
    cid = (ok and nd and nd:get_id()) or "NO-NODE"
  end
  ck(cid ~= "NO" and cid:find("f.ts", 1, true) ~= nil, "D2 reveal filesystem highlights f.ts (cursor=" .. tostring(cid) .. ")")
end

-- ── D4: file WITHOUT changes vs base → reveal is a no-op in git_status ──
set_base(C0); closeall(); vim.cmd("ReviewSidebar changed"); vim.wait(600)
vim.cmd("edit " .. vim.fn.fnameescape(abs("nested/deep/f.ts"))); vim.wait(200) -- f.ts DID change vs C0; use keep? keep changed in the working tree. We need an unchanged one: keep vs C0 changed. No unchanged file is guaranteed here; skipped if N/A
-- (nested/deep/f.ts changed vs C0, so this case is covered by L3 below)

-- ── E. deterministic toggle ──
set_base(C0); closeall()
press(" s"); ck(source() == "git_status", "E1 closed→changed(git_status) got " .. source())
press(" s"); ck(source() == "filesystem", "E2 changed→all(filesystem) got " .. source())
press(" s"); ck(source() == "git_status", "E3 all→changed(git_status) got " .. source())
ck(nt_base() == C0, "E4 base preserved after toggles got " .. nt_base())

-- ── G. base:changed live ──
set_base(C0); closeall(); vim.cmd("ReviewSidebar changed"); vim.wait(600)
ck(tree_has("newC1.ts"), "G0 (C0) newC1 in tree")
set_base(C1); vim.wait(500)
ck(not tree_has("newC1.ts"), "G1 (C1 live) newC1 no longer present (added in C1, not new vs C1)")
ck(tree_has("newC2.ts"), "G1b (C1 live) newC2 present (new vs C1)")
set_base("HEAD"); vim.wait(500)
ck(nt_base() == "EMPTY", "G2 base→HEAD git_base EMPTY")

-- ── H. gitsigns vs the base ──
--
-- These tests assert BEHAVIOR (what you see in the sign column), not internal
-- details. They used to compare `git_obj.object_name` against the empty blob
-- hash, because our config patch synthesized it that way. gitsigns 5be654f
-- ("fix(change_base): handle files missing from revision") solves it natively
-- and DIFFERENTLY: it returns the index object and sets `object_missing`, and
-- `get_show_text` is what delivers an empty base. Same visual result, another
-- implementation → asserting the hash broke with every upstream refactor.
--
-- What really matters, and is verified here:
--   1. that gitsigns ATTACHES to the buffer (the original bug was that it did
--      not, and the file was left with no signs at all), and
--   2. how many lines it marks as added (all = "new vs the base";
--      some = "there is a real base to diff against").
do
  local cache = require("gitsigns.cache")
  local function attach(rel)
    vim.cmd("edit " .. vim.fn.fnameescape(abs(rel)))
    local buf = vim.api.nvim_get_current_buf()
    vim.wait(2500, function() local c = cache.cache[buf]; return c and c.git_obj ~= nil and c.hunks ~= nil end)
    vim.wait(300)
    return buf, cache.cache[buf]
  end
  -- Buffer lines marked as ADDED vs the base, and total line count.
  local function added(rel)
    local buf, c = attach(rel)
    if not c then return nil end
    local n = 0
    for _, h in ipairs(c.hunks or {}) do
      if h.type == "add" then n = n + (h.added and h.added.count or 0) end
    end
    return n, vim.api.nvim_buf_line_count(buf), c
  end

  set_base(C0); vim.wait(300)

  -- New vs C0 but ALREADY committed (exists in HEAD): no base → all green.
  local n, total, c = added("src/newC2.ts")
  ck(c ~= nil and n == total and total > 0,
    ("H1 new-vs-C0 → attaches and ALL added (%s/%s)"):format(tostring(n), tostring(total)))

  -- Untracked: gitsigns has no object for it. `object_name == nil` remains
  -- upstream's documented contract for untracked (it is what triggers the
  -- dotted `┆` sign), so this one can be asserted.
  local _, _, cu = added("src/untracked.ts")
  ck(cu and cu.git_obj and cu.git_obj.object_name == nil, "H2 untracked → object_name=nil (dotted)")

  -- Modified vs C0: there is a real base → NOT everything can be marked as added.
  local nm, tm, cm = added("src/mod.ts")
  ck(cm ~= nil and nm < tm,
    ("H3 modified-vs-C0 → attaches and partial diff (%s/%s added)"):format(tostring(nm), tostring(tm)))

  -- Renamed vs C0: upstream now resolves the rename on its own (ls_tree looks up the
  -- old path). The content is the same as the original → no added lines.
  local nr, tr, cr = added("src/ren_new.ts")
  ck(cr ~= nil and nr < tr,
    ("H5 renamed-vs-C0 → attaches and uses the old path as base (%s/%s)"):format(tostring(nr), tostring(tr)))
end

-- ── D4/L3. file WITHOUT changes vs base → not in tree + reveal no-op ──
set_base(C0); closeall(); vim.cmd("ReviewSidebar changed"); vim.wait(600)
ck(not tree_has("stable.ts"), "L3 stable.ts (unchanged vs C0) NOT in tree")
do
  vim.cmd("edit " .. vim.fn.fnameescape(abs("src/stable.ts"))); vim.wait(200)
  local src_before = source()
  press(" E")
  -- no-op: must NOT change source nor highlight stable (stays as it was)
  ck(source() == src_before, "D4 reveal of an unchanged file does not change the source")
end

-- ── D5. non-file buffer (buftype!="") → <leader>E no-op (no error) ──
set_base(C0); closeall(); vim.wait(200)
do
  vim.cmd("enew"); vim.bo.buftype = "nofile"
  local okE = pcall(function() press(" E") end)
  ck(okE, "D5 <leader>E in a non-file buffer does not break")
  vim.cmd("edit " .. vim.fn.fnameescape(abs("src/keep.ts"))) -- go back to a real file (no bwipeout)
end

-- ── L6. invalid base ref → head_content nil, no crash ──
do
  local okv = pcall(function() core.git.set_base("deadbeefbadref"); return core.git.head_content("src/mod.ts", core.git.root() or R) end)
  ck(okv, "L6 invalid base ref does not break")
  local hc = core.git.head_content("src/mod.ts", core.git.root() or R)
  ck(hc == nil, "L6b head_content with invalid ref → nil")
end

-- ── H4. base=HEAD → NATIVE gitsigns (does not synthesize an empty blob) ──
do
  local cache = require("gitsigns.cache")
  set_base("HEAD"); vim.wait(300)
  vim.cmd("edit " .. vim.fn.fnameescape(abs("src/untracked.ts"))); local buf = vim.api.nvim_get_current_buf()
  vim.wait(2000, function() local c = cache.cache[buf]; return c and c.git_obj ~= nil end); vim.wait(200)
  local c = cache.cache[buf]
  ck(c and c.git_obj and c.git_obj.object_name == nil, "H4 base=HEAD untracked → object_name nil (native ┆)")
end

-- ── L4. switch base back and forth N times → consistent ──
do
  local seq = { C0, C1, "HEAD", C0, ":", C1, "HEAD" }
  local okall = true
  for _, r in ipairs(seq) do
    set_base(r); closeall(); vim.cmd("ReviewSidebar changed"); vim.wait(450)
    if not (nt_base() == want() or nt_base() == "NO") then okall = false end
  end
  ck(okall, "L4 switch base back/forth (7 steps) always consistent")
end

-- ── J. statusline label (clean_label, no mojibake) ──
ck(basef.clean_label("◂ Merge pull request #195") == "Merge pull request #195", "J3 clean_label strips ◂ without mojibake")
ck(basef.clean_label("normal subject") == "normal subject", "J3b clean_label leaves a normal subject alone")
ck(basef.clean_label("") == nil and basef.clean_label(nil) == nil, "J3c clean_label empty→nil")

-- ── K. persistence ──
do
  local s = core.store
  s.save_base("abc1234", "feat: x"); local r, l = s.load_base()
  ck(r == "abc1234" and l == "feat: x", "K1 save/load JSON")
  local p = (core.git.root() or R) .. "/.git/review.nvim/base"
  local fd = io.open(p, "w"); fd:write("deadbeef"); fd:close()
  local r2, l2 = s.load_base()
  ck(r2 == "deadbeef" and l2 == nil, "K2 compat plain→ref, label nil")
end

log("TOTAL fails=" .. fails) -- log() already writes incrementally to the file
for _, l in ipairs(out) do print("E2E " .. l) end
vim.cmd("qa!")
