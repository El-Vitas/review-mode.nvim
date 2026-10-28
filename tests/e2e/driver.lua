-- E2E driver. Corre DENTRO de nvim (config real) sobre el repo sintético.
-- Env: REVIEW_E2E_DIR, REVIEW_E2E_C0, REVIEW_E2E_C1. Imprime "E2E ok/FAIL ...".
local R  = assert(os.getenv("REVIEW_E2E_DIR"))
local C0 = assert(os.getenv("REVIEW_E2E_C0"))
local C1 = assert(os.getenv("REVIEW_E2E_C1"))

-- El autocmd NeoTreeAutoClose de la config cierra nvim si queda solo neo-tree;
-- durante el test manipulamos ventanas → lo desactivamos para no matar el driver.
pcall(vim.api.nvim_del_augroup_by_name, "NeoTreeAutoClose")

local core   = require("review.core")
local review = require("review")
local basef  = require("review.features.base")
local mgr    = require("neo-tree.sources.manager")

local out, fails = {}, 0
local _of = os.getenv("REVIEW_E2E_OUT")
local function log(s)
  out[#out + 1] = s
  if _of then local fd = io.open(_of, "a"); if fd then fd:write(s, "\n"); fd:close() end end -- incremental (ver progreso ante hang)
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
ck(core.git.head_content("src/newC2.ts", core.git.root() or R) == nil, "B2 newC2 no existe en C1→nil")
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
  ck(set["src/newC1.ts"] and set["src/newC2.ts"] and set["src/mod.ts"], "B4 changed_files(C0) tiene added+mod")
  ck(not set["nested/deep/f.ts"] == false, "B4b changed_files(C0) incluye deep modificado")
end

-- ── C + D + F por cada base ──
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
  ck(tree_has("untracked.ts"), "C5/" .. bc.n .. " untracked en árbol")
  -- D1 reveal en git_status marca el archivo
  vim.cmd("edit " .. vim.fn.fnameescape(abs(bc.reveal))); vim.wait(250)
  press(" E")
  local cid = cursor_id()
  ck(cid ~= "NO-WIN" and cid:find(vim.fn.fnamemodify(bc.reveal, ":t"), 1, true) ~= nil,
    "D1/" .. bc.n .. " reveal marca " .. bc.reveal .. " (cursor=" .. tostring(cid and vim.fn.fnamemodify(cid, ":t")) .. ")")
  -- F: close/reopen preserva base + archivo
  press(" e"); vim.wait(150); press(" e")
  ck(nt_base() == want() or nt_base() == "NO", "F2/" .. bc.n .. " reopen git_base==" .. want())
  ck(tree_has(vim.fn.fnamemodify(bc.reveal, ":t")), "F3/" .. bc.n .. " reopen archivo sigue en árbol")
end

-- ── C3/C4: contenido del árbol vs base C0 (added/mod/del/ren sí; keep-commiteado no) ──
set_base(C0); closeall(); vim.cmd("ReviewSidebar changed"); vim.wait(650)
ck(tree_has("newC1.ts") and tree_has("newC2.ts"), "C3 added vs C0 en árbol")
ck(tree_has("mod.ts"), "C3b modificado vs C0 en árbol")
ck(tree_has("ren_new.ts"), "L2 renombrado vs C0 en árbol")
ck(tree_has("del.ts"), "L1 borrado vs C0 en árbol (D)")

-- ── D2: reveal en FILESYSTEM (bug reportado) ──
set_base(C0); closeall()
vim.cmd("Neotree action=show source=filesystem position=right"); vim.wait(650)
ck(source() == "filesystem", "D2-pre filesystem abierto")
vim.cmd("edit " .. vim.fn.fnameescape(abs("nested/deep/f.ts"))); vim.wait(250)
press(" E")
do
  -- en filesystem el árbol es del source filesystem; leer el nodo bajo el cursor
  local w, b = nt_win(); local cid = "NO"
  if w then
    local st = mgr.get_state("filesystem")
    local ln = vim.api.nvim_win_get_cursor(w)[1]
    local ok, nd = pcall(function() return st.tree:get_node(ln) end)
    cid = (ok and nd and nd:get_id()) or "NO-NODE"
  end
  ck(cid ~= "NO" and cid:find("f.ts", 1, true) ~= nil, "D2 reveal filesystem marca f.ts (cursor=" .. tostring(cid) .. ")")
end

-- ── D4: archivo SIN cambios vs base → reveal no-op en git_status ──
set_base(C0); closeall(); vim.cmd("ReviewSidebar changed"); vim.wait(600)
vim.cmd("edit " .. vim.fn.fnameescape(abs("nested/deep/f.ts"))); vim.wait(200) -- f.ts SÍ cambió vs C0; usar keep? keep cambió working. Necesitamos uno sin cambios: keep vs C0 cambió. Usamos un archivo sin cambios: ninguno garantizado; saltamos si N/A
-- (nested/deep/f.ts cambió vs C0, así que este caso se cubre con L3 abajo)

-- ── E. toggle determinista ──
set_base(C0); closeall()
press(" s"); ck(source() == "git_status", "E1 closed→changed(git_status) got " .. source())
press(" s"); ck(source() == "filesystem", "E2 changed→all(filesystem) got " .. source())
press(" s"); ck(source() == "git_status", "E3 all→changed(git_status) got " .. source())
ck(nt_base() == C0, "E4 base preservada tras toggles got " .. nt_base())

-- ── G. base:changed en vivo ──
set_base(C0); closeall(); vim.cmd("ReviewSidebar changed"); vim.wait(600)
ck(tree_has("newC1.ts"), "G0 (C0) newC1 en árbol")
set_base(C1); vim.wait(500)
ck(not tree_has("newC1.ts"), "G1 (C1 live) newC1 YA NO (agregado en C1, no es nuevo vs C1)")
ck(tree_has("newC2.ts"), "G1b (C1 live) newC2 sí (nuevo vs C1)")
set_base("HEAD"); vim.wait(500)
ck(nt_base() == "EMPTY", "G2 base→HEAD git_base EMPTY")

-- ── H. gitsigns vs la base ──
--
-- Estos tests asertan COMPORTAMIENTO (lo que ves en la columna de signos), no
-- detalles internos. Antes comparaban `git_obj.object_name` contra el hash del
-- blob vacío, porque así lo sintetizaba nuestro parche de config. gitsigns
-- 5be654f ("fix(change_base): handle files missing from revision") lo resuelve
-- nativamente y DISTINTO: devuelve el objeto del índice y marca `object_missing`,
-- y es `get_show_text` quien entrega base vacía. Mismo resultado visual, otra
-- implementación → asertar el hash rompía con cada refactor de upstream.
--
-- Lo que de verdad importa y acá se verifica:
--   1. que gitsigns SE ADJUNTE al buffer (el bug original era que no lo hacía
--      y el archivo quedaba sin ningún signo), y
--   2. cuántas líneas marca como agregadas (todas = "nuevo vs la base";
--      algunas = "hay una base real contra la cual diffear").
do
  local cache = require("gitsigns.cache")
  local function attach(rel)
    vim.cmd("edit " .. vim.fn.fnameescape(abs(rel)))
    local buf = vim.api.nvim_get_current_buf()
    vim.wait(2500, function() local c = cache.cache[buf]; return c and c.git_obj ~= nil and c.hunks ~= nil end)
    vim.wait(300)
    return buf, cache.cache[buf]
  end
  -- Líneas del buffer marcadas como AGREGADAS vs la base, y total de líneas.
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

  -- Nuevo vs C0 pero YA commiteado (existe en HEAD): no hay base → todo verde.
  local n, total, c = added("src/newC2.ts")
  ck(c ~= nil and n == total and total > 0,
    ("H1 nuevo-vs-C0 → adjunta y TODO agregado (%s/%s)"):format(tostring(n), tostring(total)))

  -- Untracked: gitsigns no tiene objeto para él. `object_name == nil` sigue
  -- siendo el contrato documentado de upstream para untracked (es lo que
  -- dispara el signo punteado `┆`), así que esto sí se puede asertar.
  local _, _, cu = added("src/untracked.ts")
  ck(cu and cu.git_obj and cu.git_obj.object_name == nil, "H2 untracked → object_name=nil (punteado)")

  -- Modificado vs C0: hay base real → NO puede estar todo marcado como agregado.
  local nm, tm, cm = added("src/mod.ts")
  ck(cm ~= nil and nm < tm,
    ("H3 modificado-vs-C0 → adjunta y diff parcial (%s/%s agregadas)"):format(tostring(nm), tostring(tm)))

  -- Renombrado vs C0: upstream ahora resuelve el rename solo (ls_tree busca el
  -- path viejo). El contenido es el mismo que el original → sin líneas agregadas.
  local nr, tr, cr = added("src/ren_new.ts")
  ck(cr ~= nil and nr < tr,
    ("H5 renombrado-vs-C0 → adjunta y usa el path viejo como base (%s/%s)"):format(tostring(nr), tostring(tr)))
end

-- ── D4/L3. archivo SIN cambios vs base → no en árbol + reveal no-op ──
set_base(C0); closeall(); vim.cmd("ReviewSidebar changed"); vim.wait(600)
ck(not tree_has("stable.ts"), "L3 stable.ts (sin cambios vs C0) NO en árbol")
do
  vim.cmd("edit " .. vim.fn.fnameescape(abs("src/stable.ts"))); vim.wait(200)
  local src_before = source()
  press(" E")
  -- no-op: NO debe cambiar de source ni marcar stable (queda como estaba)
  ck(source() == src_before, "D4 reveal de archivo sin cambios no cambia el source")
end

-- ── D5. buffer no-archivo (buftype!="") → <leader>E no-op (no error) ──
set_base(C0); closeall(); vim.wait(200)
do
  vim.cmd("enew"); vim.bo.buftype = "nofile"
  local okE = pcall(function() press(" E") end)
  ck(okE, "D5 <leader>E en buffer no-archivo no rompe")
  vim.cmd("edit " .. vim.fn.fnameescape(abs("src/keep.ts"))) -- volver a un archivo real (no bwipeout)
end

-- ── L6. base ref inválido → head_content nil, sin crash ──
do
  local okv = pcall(function() core.git.set_base("deadbeefbadref"); return core.git.head_content("src/mod.ts", core.git.root() or R) end)
  ck(okv, "L6 base ref inválido no rompe")
  local hc = core.git.head_content("src/mod.ts", core.git.root() or R)
  ck(hc == nil, "L6b head_content con ref inválido → nil")
end

-- ── H4. base=HEAD → gitsigns NATIVO (no sintetiza blob vacío) ──
do
  local cache = require("gitsigns.cache")
  set_base("HEAD"); vim.wait(300)
  vim.cmd("edit " .. vim.fn.fnameescape(abs("src/untracked.ts"))); local buf = vim.api.nvim_get_current_buf()
  vim.wait(2000, function() local c = cache.cache[buf]; return c and c.git_obj ~= nil end); vim.wait(200)
  local c = cache.cache[buf]
  ck(c and c.git_obj and c.git_obj.object_name == nil, "H4 base=HEAD untracked → object_name nil (nativo ┆)")
end

-- ── L4. switch base ida y vuelta N veces → consistente ──
do
  local seq = { C0, C1, "HEAD", C0, ":", C1, "HEAD" }
  local okall = true
  for _, r in ipairs(seq) do
    set_base(r); closeall(); vim.cmd("ReviewSidebar changed"); vim.wait(450)
    if not (nt_base() == want() or nt_base() == "NO") then okall = false end
  end
  ck(okall, "L4 switch base ida/vuelta (7 pasos) siempre consistente")
end

-- ── J. statusline label (clean_label, sin mojibake) ──
ck(basef.clean_label("◂ Merge pull request #195") == "Merge pull request #195", "J3 clean_label quita ◂ sin mojibake")
ck(basef.clean_label("normal subject") == "normal subject", "J3b clean_label deja subject normal")
ck(basef.clean_label("") == nil and basef.clean_label(nil) == nil, "J3c clean_label vacío→nil")

-- ── K. persistencia ──
do
  local s = core.store
  s.save_base("abc1234", "feat: x"); local r, l = s.load_base()
  ck(r == "abc1234" and l == "feat: x", "K1 save/load JSON")
  local p = (core.git.root() or R) .. "/.git/review.nvim/base"
  local fd = io.open(p, "w"); fd:write("deadbeef"); fd:close()
  local r2, l2 = s.load_base()
  ck(r2 == "deadbeef" and l2 == nil, "K2 compat plano→ref, label nil")
end

log("TOTAL fails=" .. fails) -- log() ya escribe incremental al archivo
for _, l in ipairs(out) do print("E2E " .. l) end
vim.cmd("qa!")
