-- TEST DURO del split: mide DESINCRONÍA REAL en pantalla (screenpos) y verifica
-- que cambiar de vista limpia AMBOS paneles sin importar dónde esté el foco.
local R = assert(os.getenv("REVIEW_E2E_DIR"))
pcall(vim.api.nvim_del_augroup_by_name, "NeoTreeAutoClose")
local _of = os.getenv("REVIEW_E2E_OUT")
local fails = 0
local function log(s) if _of then local fd = io.open(_of, "a"); if fd then fd:write(s, "\n"); fd:close() end end end
local function ck(c, t) if c then log("ok   " .. t) else fails = fails + 1; log("FAIL " .. t) end end

local views = require("review.features.views")
local split = require("review.features.views.split")
local core = require("review.core")

-- Archivo con líneas LARGAS (envuelven) + cambio que ALARGA una línea (para que
-- el lado editado envuelva distinto que HEAD → desincronía visible con wrap).
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
  L[10] = "line10 CHANGED-AND-MUCH-LONGER " .. long .. long -- 2x largo → envuelve más
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

-- ── 1. DESINCRONÍA REAL en pantalla: misma línea, ¿misma fila de pantalla? ──
views.set(core, "normal"); vim.wait(150)
vim.g.review_wrap = true
views.set(core, "split"); vim.wait(500)
do
  local head, edit = panes()
  ck(head and edit, "1 hay 2 columnas")
  if head and edit then
    -- Verificación headless del padding de alineación (screenpos da 0 sin UI):
    -- con wrap, la línea 10 es MUCHO más larga en EDIT que en HEAD, así que repad
    -- debe añadir filas virtuales al lado HEAD (el más corto). Contamos extmarks
    -- del namespace de padding en el buffer scratch.
    vim.wait(200) -- dejar correr el repad diferido
    local ns
    for name, id in pairs(vim.api.nvim_get_namespaces()) do
      if name == "review_split_pad" then ns = id end
    end
    ck(ns ~= nil, "1b existe el namespace de padding")
    if ns then
      local hbuf = vim.api.nvim_win_get_buf(head)
      local marks = vim.api.nvim_buf_get_extmarks(hbuf, ns, 0, -1, { details = true })
      local vrows = 0
      for _, m in ipairs(marks) do
        local vl = m[4] and m[4].virt_lines
        if vl then vrows = vrows + #vl end
      end
      log("   filas virtuales de padding en HEAD = " .. vrows)
      ck(vrows > 0, "1b (WRAP ON) repad añadió padding al lado corto (HEAD)")
    end
  end
end

-- ── 2. Cambiar de vista desde el panel EDIT limpia AMBOS ──
local head, edit = panes()
if edit then vim.api.nvim_set_current_win(edit) end
views.set(core, "normal"); vim.wait(400)
do
  local d, s = count()
  ck(d == 0 and s == 0, string.format("2 split→normal desde EDIT limpia todo (diff=%d scratch=%d)", d, s))
end

-- ── 3. Cambiar de vista desde el panel HEAD (scratch) limpia AMBOS ──
views.set(core, "split"); vim.wait(400)
head, edit = panes()
if head then vim.api.nvim_set_current_win(head) end
views.set(core, "normal"); vim.wait(400)
do
  local d, s = count()
  ck(d == 0 and s == 0, string.format("3 split→normal desde HEAD limpia todo (diff=%d scratch=%d)", d, s))
end

-- ── 4. split→inline desde HEAD ──
views.set(core, "split"); vim.wait(400)
head, edit = panes()
if head then vim.api.nvim_set_current_win(head) end
views.set(core, "inline"); vim.wait(400)
do
  local d, s = count()
  ck(d == 0 and s == 0, string.format("4 split→inline desde HEAD limpia todo (diff=%d scratch=%d)", d, s))
end

-- ── 5. scrollbind/cursorbind presentes en ambos tras entrar a split ──
views.set(core, "normal"); vim.wait(150)
views.set(core, "split"); vim.wait(400)
do
  local h, e = panes()
  if h and e then
    ck(vim.wo[h].scrollbind and vim.wo[e].scrollbind, "5 scrollbind en ambos")
    ck(vim.wo[h].cursorbind and vim.wo[e].cursorbind, "5b cursorbind en ambos")
    ck(vim.wo[h].diff and vim.wo[e].diff, "5c diff en ambos")
  end
end

log("TOTAL fails=" .. fails)
log("__DONE__")
vim.cmd("qa!")
