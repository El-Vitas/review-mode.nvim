-- Vista SPLIT y ventanas: qué pasa al cambiar de archivo, de ventana, de
-- pestaña, al cerrar una de las dos columnas o al abrir ventanas especiales.
-- Invariante en TODOS los casos: hay como mucho UN par (columna HEAD + columna
-- de edición), nunca una columna HEAD huérfana ni una ventana pegada en modo diff,
-- y las opciones del split no se filtran a otras ventanas.
-- Corre DENTRO de nvim (config real) sobre el repo sintético de fixture.sh. No
-- escribe archivos del repo: los cambios que hacen falta son en memoria.
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

-- Estado de TODAS las pestañas: columnas HEAD (por nombre de buffer, así se ven
-- también las huérfanas de una sesión vieja) y ventanas en modo diff.
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
local function pair(tag) -- exactamente un par en la pestaña actual
  local h, d = state()
  ck(h == 1 and d == 2, ("%s: un par HEAD+edición (head=%d diff=%d)"):format(tag, h, d))
end
local function single(tag) -- una sola columna, sin diff
  local h, d = state()
  ck(h == 0 and d == 0, ("%s: una sola columna (head=%d diff=%d)"):format(tag, h, d))
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

-- Un archivo que difiere de HEAD solo en memoria (sin escribir el repo).
local function load_modified(rel)
  local b = vim.fn.bufadd(R .. "/" .. rel); vim.fn.bufload(b)
  vim.bo[b].buflisted = true
  vim.api.nvim_buf_set_lines(b, 0, 0, false, { "// cambio en memoria" })
  return b
end

vim.cmd("cd " .. R)
core.git.set_base("HEAD")
vim.cmd("only")
vim.cmd("edit " .. R .. "/src/keep.ts") -- modificado en el working tree
local mod = load_modified("src/mod.ts")
local before_wh, before_fe = vim.go.winhighlight, vim.go.foldenable

views.set(core, "split"); wait()
pair("W1 split sobre keep.ts")

-- ── Cambiar de archivo en la columna de edición ──
vim.api.nvim_set_current_win(edit_win())
vim.cmd("buffer " .. mod); wait()
pair("W2 cambiar a otro archivo con cambios")
ck(head_shows("src/mod.ts"), "W2b la columna HEAD sigue al archivo nuevo")

vim.cmd("edit " .. R .. "/nested/deep/f.ts"); wait()
single("W3 archivo idéntico a HEAD")

vim.cmd("edit " .. R .. "/src/untracked.ts"); wait()
single("W4 archivo nuevo sin HEAD")

local outside = vim.fn.tempname() .. ".ts"
vim.fn.writefile({ "fuera del repo" }, outside)
vim.cmd("edit " .. outside); wait()
single("W5 archivo fuera del repo")
ck(vim.wo.foldenable == before_fe, "W5b fuera del repo no se tocan los folds")

vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
pair("W6 volver a un archivo con cambios")

-- ── Las opciones del split no se filtran al global ──
ck(vim.go.winhighlight == before_wh, ("W7 winhighlight global intacto (%q)"):format(vim.go.winhighlight))
ck(vim.go.foldenable == before_fe, "W7b foldenable global intacto")
vim.cmd("botright new"); wait()
ck(vim.wo.winhighlight == before_wh and not vim.wo.diff, "W7c ventana nueva nace sin el resaltado del split")
vim.cmd("close"); wait()
pair("W7d cerrar esa ventana no rompe el par")

-- ── Foco en ventanas especiales: el par se queda como está ──
vim.cmd("help help"); wait()
local h, d = state()
ck(h == 1 and d == 2, ("W8 abrir :help no desarma el par (head=%d diff=%d)"):format(h, d))
vim.cmd("helpclose"); wait()
pair("W8b cerrar :help")

vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>e", true, false, true), "x", false); wait(1000)
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "neo-tree" then vim.api.nvim_set_current_win(w) end
end
wait()
h, d = state()
ck(h == 1 and d == 2, ("W9 foco en el árbol no desarma el par (head=%d diff=%d)"):format(h, d))
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>e", true, false, true), "x", false); wait(600)
vim.api.nvim_set_current_win(edit_win()); wait()
pair("W9b cerrar el árbol")

-- ── Una sola columna HEAD aunque haya dos ventanas de edición ──
vim.cmd("vsplit"); vim.cmd("buffer " .. mod); wait()
h, d = state()
ck(h == 1 and d == 2, ("W10 segunda ventana de edición: sigue habiendo UN par (head=%d diff=%d)"):format(h, d))
-- El par se movió a la ventana nueva: cerrarla es cerrar su columna de edición.
vim.cmd("close"); wait()
single("W10b cerrar la ventana que tenía el par deja una sola columna")
ck(views.mode == "normal", "W10c ...y la vista pasa a normal (misma regla que cerrar una columna)")
vim.api.nvim_set_current_win(edit_win()); wait()
views.set(core, "split"); wait()
pair("W10d volver a split")

-- ── Cerrar a mano una de las dos columnas ──
local head_win
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("^review://head/") then head_win = w end
end
vim.api.nvim_win_close(head_win, true); wait()
single("W11 cerrar la columna HEAD a mano deja una sola columna")
ck(views.mode == "normal", "W11b ...y la vista pasa a normal (mode=" .. tostring(views.mode) .. ")")
vim.cmd("botright new"); wait(); vim.cmd("close"); wait()
vim.cmd("edit " .. R .. "/src/mod.ts"); wait(); vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
single("W11c el par NO reaparece al cambiar de foco ni de archivo")

views.set(core, "split"); wait()
pair("W12 volver a split con la tecla")
vim.cmd("vsplit " .. R .. "/nested/deep/f.ts"); wait() -- tercera ventana para que nvim no quede vacío
vim.cmd("wincmd p"); wait()
local ew = vim.api.nvim_get_current_win()
local hw
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("^review://head/") then hw = w end
end
if ew ~= hw and vim.wo[ew].diff then
  vim.api.nvim_win_close(ew, true); wait()
  h, d = state()
  ck(h == 0 and d == 0, ("W13 cerrar la columna de edición cierra también la HEAD (head=%d diff=%d)"):format(h, d))
  ck(views.mode == "normal", "W13b ...y la vista pasa a normal")
else
  log("obs  W13 no se pudo ubicar la columna de edición del par")
end

-- ── Pestañas ──
vim.cmd("only"); vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
views.set(core, "normal"); wait(); views.set(core, "split"); wait()
pair("W14 par en la pestaña 1")
local tab1 = vim.api.nvim_get_current_tabpage()
vim.cmd("tabnew"); vim.cmd("buffer " .. mod); wait()
pair("W14b par en la pestaña 2")
local h1, d1 = state(tab1)
ck(h1 == 0 and d1 == 0, ("W14c la pestaña 1 no queda con columnas colgadas (head=%d diff=%d)"):format(h1, d1))
vim.cmd("tabclose"); wait()
-- Cerrar la pestaña cierra las dos columnas del par: misma regla que W11/W13.
single("W15 cerrar la pestaña del par: la pestaña 1 queda en una columna")
ck(views.mode == "normal", "W15b ...y la vista pasa a normal")

-- Cambiar de vista NO es un cierre manual: no debe forzar normal.
views.set(core, "split"); wait()
pair("W16 split otra vez")
views.set(core, "inline"); wait()
ck(views.mode == "inline", "W16b split → inline queda en inline (el cierre lo hizo el plugin)")
views.set(core, "split"); wait()
vim.cmd("edit " .. R .. "/nested/deep/f.ts"); wait()
ck(views.mode == "split", "W16c ir a un archivo sin cambios no apaga el split global")
vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
pair("W16d volver a un archivo con cambios rearma el par")

-- ── Volver a un archivo después de salir del split ──
-- 'diff' y el resaltado se guardan POR BUFFER en cada ventana: si el par se
-- desarma con la ventana mostrando otro archivo, al volver el anterior traía el
-- diff encendido y parecía que <leader>rn/ri/rv no cambiaban nada.
vim.cmd("only"); vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
views.set(core, "split"); wait()
pair("W18 par sobre keep.ts")
vim.cmd("edit " .. R .. "/nested/deep/f.ts"); wait()
views.set(core, "normal"); wait()
vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
single("W18b volver a keep.ts en normal: sin diff pegado")
ck(vim.wo.winhighlight == before_wh, ("W18c ...ni el resaltado del split (%q)"):format(vim.wo.winhighlight))
views.set(core, "inline"); wait()
single("W18d inline sobre keep.ts: sin diff")
views.set(core, "split"); wait()
pair("W18e split otra vez sobre keep.ts")
views.set(core, "normal"); wait()

-- ── Un diff hecho a mano no se toca ──
vim.cmd("only"); vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
vim.cmd("diffthis"); vim.cmd("vsplit " .. R .. "/src/mod.ts"); vim.cmd("diffthis"); wait()
vim.cmd("wincmd p"); wait(); vim.cmd("wincmd p"); wait()
local manual = 0
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do if vim.wo[w].diff then manual = manual + 1 end end
ck(manual == 2, ("W19 un :diffthis del usuario sigue activo al cambiar de ventana (diff=%d)"):format(manual))
vim.cmd("diffoff!"); vim.cmd("only"); wait()

-- ── Los atajos reales recorren las tres vistas ──
vim.cmd("edit " .. R .. "/src/keep.ts"); wait()
local seen = {}
for _ = 1, 3 do
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>rv", true, false, true), "mx", false); wait()
  seen[#seen + 1] = views.mode
end
ck(table.concat(seen, ",") == "inline,split,normal",
  "W20 <leader>rv recorre inline → split → normal (" .. table.concat(seen, ",") .. ")")

views.set(core, "normal"); wait()
single("W17 normal al final")
log("TOTAL fails=" .. fails)
vim.cmd("qa!")
