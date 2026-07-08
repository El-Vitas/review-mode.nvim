-- Integración con petertriho/nvim-scrollbar + navegación de cambios.
-- Marca en el scrollbar las líneas cambiadas vs HEAD, BIEN NOTORIAS (glifo lleno
-- `█` y colores brillantes: verde=agregado, naranja=cambiado, rojo=borrado), y
-- expone los RANGOS de cambios para saltar con :ReviewNextChange / :ReviewChanges.
local M = {}

-- Cache del contenido HEAD por buffer (git show es subproceso; el HEAD no cambia
-- mientras editás). Se libera al cerrar el buffer / recargar.
local _head = {}
-- Cache de hunks por (buffer, changedtick).
local _hunks = {}

local function head_for(core, bufnr, rel, root)
  local c = _head[bufnr]
  if c ~= nil then return c or nil end
  local lines = core.git.head_content(rel, root)
  _head[bufnr] = lines or false
  return lines
end

--- Hunks de cambios del buffer vs HEAD. Devuelve lista de
--- { sl, el, kind } (1-based, en el buffer). kind = "add"|"change"|"delete".
function M.hunks(core, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end
  if vim.bo[bufnr].buftype ~= "" then return {} end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _hunks[bufnr]
  if cached and cached.tick == tick then return cached.hunks end

  local rel = core.git.rel_path(bufnr)
  local root = core.git.root(bufnr)
  local out = {}
  if rel and root then
    local head = head_for(core, bufnr, rel, root)
    if head then
      local a = table.concat(head, "\n")
      local b = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      if a ~= b then
        local hunks = vim.diff(a, b, { result_type = "indices" }) or {}
        for _, h in ipairs(hunks) do
          local count_a, start_b, count_b = h[2], h[3], h[4]
          if count_a == 0 then
            out[#out + 1] = { sl = start_b, el = start_b + count_b - 1, kind = "add" }
          elseif count_b == 0 then
            out[#out + 1] = { sl = math.max(1, start_b), el = math.max(1, start_b), kind = "delete" }
          else
            out[#out + 1] = { sl = start_b, el = start_b + count_b - 1, kind = "change" }
          end
        end
      end
    end
  end
  _hunks[bufnr] = { tick = tick, hunks = out }
  return out
end

local KIND_TYPE = { add = "GitAdd", change = "GitChange", delete = "GitDelete" }

-- Handler para nvim-scrollbar: marca cada línea cambiada con glifo NOTORIO.
local function handler(core, bufnr)
  local marks = {}
  for _, h in ipairs(M.hunks(core, bufnr)) do
    local ty = KIND_TYPE[h.kind]
    for l = h.sl, h.el do
      marks[#marks + 1] = { line = l - 1, text = "█", type = ty, level = 2 }
    end
  end
  return marks
end

-- Colores BRILLANTES y bold para las marcas (por defecto caen a negro y no se
-- ven). Override-ables por el usuario (se re-aplican en ColorScheme).
local function ensure_hl()
  local defs = {
    ScrollbarGitAdd = "#a6e3a1",       -- verde
    ScrollbarGitAddHandle = "#a6e3a1",
    ScrollbarGitChange = "#fab387",    -- naranja
    ScrollbarGitChangeHandle = "#fab387",
    ScrollbarGitDelete = "#f38ba8",    -- rojo
    ScrollbarGitDeleteHandle = "#f38ba8",
  }
  for name, fg in pairs(defs) do
    vim.api.nvim_set_hl(0, name, { fg = fg, bold = true })
  end
end

function M.setup(core)
  local ok, handlers = pcall(require, "scrollbar.handlers")
  if not ok then return end -- nvim-scrollbar no instalado → no-op

  handlers.register("review", function(bufnr) return handler(core, bufnr) end)
  ensure_hl()

  local grp = vim.api.nvim_create_augroup("ReviewScrollbar", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = grp, callback = ensure_hl })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = grp,
    callback = function(a)
      _head[a.buf] = nil
      _hunks[a.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = grp,
    callback = function(a) _head[a.buf] = nil end,
  })

  -- Al cambiar la base de comparación: limpiar caches y redibujar las marcas.
  if core.events then
    core.events.on("base:changed", function()
      _head = {}
      _hunks = {}
      vim.schedule(function() pcall(require("scrollbar.handlers").show) end)
    end)
  end
end

return M
