-- Verifica que re-invocar la vista SPLIT (o cambiar de vista) estando ya en
-- split NO se buguea: no duplica ventanas, no deja columnas colgadas en diff,
-- no explota. Corre DENTRO de nvim sobre el repo sintético.
-- Env: REVIEW_E2E_DIR. Imprime "SPLIT ok/FAIL ..." y un TOTAL.
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

-- Cuenta ventanas NORMALES (buftype "") + el scratch HEAD del split en el tab.
local function count_wins()
  local normal, scratch = 0, 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if split.is_scratch(b) then scratch = scratch + 1
    elseif vim.bo[b].buftype == "" then normal = normal + 1 end
  end
  return normal, scratch
end
-- ¿Cuántas ventanas del tab están en modo diff?
local function count_diff()
  local n = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[w].diff then n = n + 1 end
  end
  return n
end

-- Abrir un archivo CON cambios vs HEAD (para que el split tenga 2 columnas).
-- src/keep.ts tiene un cambio sin commitear en el fixture.
core.git.set_base("HEAD") -- base = working tree vs HEAD
vim.cmd("edit " .. R .. "/src/keep.ts")
vim.wait(200)

-- ── 1. Entrar a split: debe crear el panel HEAD (1 normal + 1 scratch, 2 en diff) ──
views.set(core, "split"); vim.wait(400)
do
  local n, s = count_wins()
  ck(n == 1 and s == 1, "1 split crea 1 panel HEAD (normal=" .. n .. " scratch=" .. s .. ")")
  ck(count_diff() == 2, "1b ambas columnas en modo diff (diff=" .. count_diff() .. ")")
  ck(split._session ~= nil, "1c hay sesión de split")
end

-- ── 2. Re-invocar split estando en split: NO-OP, no duplica ventanas ──
local sess_before = split._session
views.set(core, "split"); vim.wait(400)
do
  local n, s = count_wins()
  ck(n == 1 and s == 1, "2 re-split NO duplica (normal=" .. n .. " scratch=" .. s .. ")")
  ck(count_diff() == 2, "2b sigue con 2 columnas en diff")
  ck(split._session == sess_before, "2c misma sesión (no recreó)")
end

-- ── 3. Re-invocar por el KEYMAP directo (<leader>rs) estando en split ──
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>rs", true, false, true), "x", false)
vim.wait(400)
do
  local n, s = count_wins()
  ck(n == 1 and s == 1, "3 <leader>rs en split NO duplica (normal=" .. n .. " scratch=" .. s .. ")")
end

-- ── 4. split → inline: teardown limpio (0 scratch, 0 diff) ──
views.set(core, "inline"); vim.wait(400)
do
  local n, s = count_wins()
  ck(s == 0, "4 inline cierra el panel HEAD (scratch=" .. s .. ")")
  ck(count_diff() == 0, "4b sin ventanas en diff tras salir de split")
  ck(split._session == nil, "4c sesión liberada")
end

-- ── 5. inline → split otra vez: se re-crea sano ──
views.set(core, "split"); vim.wait(400)
do
  local n, s = count_wins()
  ck(n == 1 and s == 1, "5 re-entrar a split tras inline (normal=" .. n .. " scratch=" .. s .. ")")
  ck(count_diff() == 2, "5b 2 columnas en diff de nuevo")
end

-- ── 6. split → normal: teardown, restaura ventana única ──
views.set(core, "normal"); vim.wait(400)
do
  local n, s = count_wins()
  ck(s == 0 and count_diff() == 0, "6 normal limpia split (scratch=" .. s .. " diff=" .. count_diff() .. ")")
end

-- ── 7. Ciclar rv repetidamente no deja basura (normal→inline→split→normal x2) ──
for i = 1, 2 do
  for _, m in ipairs({ "inline", "split", "normal" }) do
    views.set(core, m); vim.wait(250)
  end
end
do
  local n, s = count_wins()
  ck(n == 1 and s == 0 and count_diff() == 0,
    "7 ciclado repetido termina limpio (normal=" .. n .. " scratch=" .. s .. " diff=" .. count_diff() .. ")")
end

log("TOTAL fails=" .. fails)
if _of then local fd = io.open(_of, "a"); if fd then fd:write("__DONE__\n"); fd:close() end end
vim.cmd("qa!")
