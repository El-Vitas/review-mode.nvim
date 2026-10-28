-- Vista SPLIT con archivos markdown (render-markdown adjunto). Cerrar una
-- columna del split con el diff invalidado hacía que Neovim disparara
-- DiffUpdated EN MEDIO de win_close; el callback de render-markdown llama a
-- win_findbuf ahí y Neovim moría con SIGSEGV (bug de Neovim). Cada caso de
-- abajo cierra columnas por un camino distinto: si Neovim se cae, el script no
-- llega a "TOTAL" y el runner lo marca como sin resultados.
-- Env: REVIEW_E2E_DIR, REVIEW_E2E_OUT. Commitea doc.md en el fixture.
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
local md2 = R .. "/otro.md"
vim.fn.writefile({ "# Doc", "", "| a | b |", "|---|---|", "| 1 | 2 |", "", "texto" }, md)
vim.fn.writefile({ "# Otro", "", "texto" }, md2)
vim.fn.system({ "git", "-C", R, "add", "doc.md", "otro.md" })
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
-- Abre `path` y le hace un cambio en memoria. TextChanged a mano: en headless
-- nvim_buf_set_lines no lo dispara, y es el evento con el que review arma el par.
local function open_changed(path)
  -- `edit!`: reabrir el mismo archivo con cambios en memoria sin `!` da E37.
  local ok, err = pcall(vim.cmd, "edit! " .. path)
  if not ok then log("obs  edit " .. path:gsub("^.*/", "") .. " falló: " .. tostring(err) .. " | " .. state_str()) end
  wait(300)
  vim.api.nvim_buf_set_lines(0, 1, 1, false, { "cambio en memoria" })
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

-- 1. markdown → archivo sin cambios (el caso del crash reportado)
ck(split_on(md), "M1 par sobre doc.md")
vim.cmd("edit " .. R .. "/nested/deep/f.ts"); wait()
ck(select(1, heads()) == 0, "M1b doc.md → archivo sin cambios: vivo y en una columna")

-- 2. markdown → otro archivo con cambios
ck(split_on(md), "M2 par sobre doc.md")
open_changed(R .. "/src/mod.ts"); wait()
ck(select(1, heads()) == 1, "M2b doc.md → mod.ts: vivo y con el par en mod.ts")

-- 3. archivo de código → markdown con cambios, y markdown → markdown
ck(split_on(R .. "/src/keep.ts"), "M3 par sobre keep.ts")
open_changed(md); wait()
ck(select(1, heads()) == 1, "M3b keep.ts → doc.md: vivo")
open_changed(md2); wait()
ck(select(1, heads()) == 1, "M3c doc.md → otro.md: vivo")
vim.cmd("edit " .. R .. "/nested/deep/f.ts"); wait()
ck(select(1, heads()) == 0, "M3d otro.md → sin cambios: vivo")

-- 4. cambiar de vista desde cada columna con markdown
ck(split_on(md), "M4 par sobre doc.md")
views.set(core, "normal"); wait()
ck(select(1, heads()) == 0, "M4b split → normal desde la edición: vivo")
ck(split_on(md), "M4c par sobre doc.md")
vim.api.nvim_set_current_win(head_win()); views.set(core, "inline"); wait()
ck(select(1, heads()) == 0, "M4d split → inline desde la columna HEAD: vivo")

-- 5. cerrar cada columna a mano
ck(split_on(md), "M5 par sobre doc.md")
vim.api.nvim_win_close(head_win(), true); wait()
ck(select(1, heads()) == 0, "M5b cerrar la columna HEAD a mano: vivo")
ck(split_on(md), "M5c par sobre doc.md")
vim.cmd("vsplit " .. R .. "/nested/deep/f.ts"); wait()
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.wo[w].diff and not vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("^review://") then
    vim.api.nvim_win_close(w, true); break
  end
end
wait()
ck(select(2, heads()) == 0, "M5d cerrar la columna de edición a mano: vivo")

-- 6. cerrar la pestaña del par
vim.cmd("only")
vim.cmd("tabnew")
ck(split_on(md), "M6 par sobre doc.md en otra pestaña")
vim.cmd("tabclose"); wait()
ck(true, "M6b cerrar la pestaña del par: vivo")

-- 7. Las guardias no dejan DiffUpdated ignorado.
wait()
ck(not vim.go.eventignore:find("DiffUpdated", 1, true),
  ("M7 eventignore limpio al final (%q)"):format(vim.go.eventignore))

log("TOTAL fails=" .. fails)
vim.cmd("qa!")
