-- Verifica que UN solo click expande una carpeta NUNCA-abierta (hijos aún no
-- cargados) — el caso que necesitaba 2 clicks. Simula el LeftRelease con la
-- MISMA lógica del mapping real y comprueba is_expanded() tras 1 click.
local R = assert(os.getenv("REVIEW_E2E_DIR"))
pcall(vim.api.nvim_del_augroup_by_name, "NeoTreeAutoClose")
local _of = os.getenv("REVIEW_E2E_OUT")
local fails = 0
local function log(s) if _of then local fd = io.open(_of, "a"); if fd then fd:write(s, "\n"); fd:close() end end end
local function ck(c, t) if c then log("ok   " .. t) else fails = fails + 1; log("FAIL " .. t) end end

vim.cmd("cd " .. R)
vim.cmd("edit " .. R .. "/src/keep.ts"); vim.wait(150)
vim.cmd("Neotree filesystem right dir=" .. R); vim.wait(800)

local mgr = require("neo-tree.sources.manager")
local st = mgr.get_state("filesystem")
ck(st ~= nil and st.tree ~= nil, "0 hay árbol filesystem")

-- Buscar una carpeta COLAPSADA (nunca abierta) escaneando las líneas visibles.
local function find_collapsed_dir()
  for i = 1, vim.api.nvim_buf_line_count(st.bufnr) do
    local nd = st.tree:get_node(i)
    if nd and nd.type == "directory" and not nd:is_expanded() then return nd end
  end
end

local target = find_collapsed_dir()
ck(target ~= nil, "1 encontré una carpeta colapsada: " .. (target and target.name or "?"))
if not target then log("TOTAL fails=" .. fails); log("__DONE__"); vim.cmd("qa!"); return end

-- Poner el cursor en la línea de esa carpeta (como haría el LeftMouse).
local line
for i = 1, vim.api.nvim_buf_line_count(st.bufnr) do
  local nd = st.tree:get_node(i)
  if nd and nd:get_id() == target:get_id() then line = i; break end
end
ck(line ~= nil, "2 ubiqué su línea en el buffer: " .. tostring(line))

local ntwin = st.winid
vim.api.nvim_set_current_win(ntwin)
vim.api.nvim_win_set_cursor(ntwin, { line, 0 })
ck(not target:is_expanded(), "3 arranca COLAPSADA")

-- Ejecutar EXACTAMENTE lo que hace el mapping (open de la fuente).
local cmds = require("neo-tree.sources.filesystem.commands")
cmds.open(st)
vim.wait(500)

-- Re-leer el nodo (el árbol se redibuja).
st = mgr.get_state("filesystem")
local after = st.tree:get_node(line)
-- puede haber cambiado el nodo en esa línea; buscar por id.
local function node_by_id(id)
  for i = 1, vim.api.nvim_buf_line_count(st.bufnr) do
    local nd = st.tree:get_node(i); if nd and nd:get_id() == id then return nd end
  end
end
local reloaded = node_by_id(target:get_id())
ck(reloaded ~= nil and reloaded:is_expanded(), "4 UN click la EXPANDIÓ (source.open con toggle_directory)")

-- Contraprueba: common.open SIN toggle_directory NO la expande al 1er intento.
-- (colapsar primero, luego probar common)
if reloaded and reloaded:is_expanded() then
  require("neo-tree.sources.common.commands").toggle_node(st, nil) -- colapsa
  vim.wait(200)
end

log("TOTAL fails=" .. fails)
log("__DONE__")
vim.cmd("qa!")
