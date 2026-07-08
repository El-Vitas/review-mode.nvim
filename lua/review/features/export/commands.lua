local markdown = require("review.features.export.markdown")

local M = {}

-- Header agent-ready: si el agente está habilitado (existe `_G.ReviewAgent`),
-- anteponemos al yank el socket RPC de esta instancia de Neovim + la API, para
-- que el agente tenga TODO lo que necesita con solo pegar el markdown (sin pedir
-- el socket a mano). Si el agente no está habilitado, no se agrega nada.
local function agent_header()
  if _G.ReviewAgent == nil then return "" end
  local sock = vim.v.servername
  if not sock or sock == "" then return "" end
  return table.concat({
    "<!-- review.nvim agent",
    "socket: " .. sock,
    "connect: nvim --server <socket> --remote-expr 'luaeval(\"ReviewAgent.<fn>(...)\")'",
    "api: list(filter?) get(id) context(id) add(json) reply(id,text) resolve(id) unresolve(id) update(id,text) delete(id) clean_resolved(path?) is_modified(path) notify_changed(path)",
    "each comment below carries its `id:<id>` token to target it.",
    "-->",
    "",
    "",
  }, "\n")
end

local function yank(text)
  if not text or text == "" then
    vim.notify("review.nvim: no comments", vim.log.levels.INFO)
    return
  end
  vim.fn.setreg("+", agent_header() .. text)
  vim.notify("review.nvim: comments copied to the + register", vim.log.levels.INFO)
end

local function yank_file(core)
  local relpath = core.git.rel_path(0)
  if not relpath then
    vim.notify("review.nvim: current buffer is not in the repo", vim.log.levels.WARN)
    return
  end
  yank(markdown.file(core, relpath))
end

local function yank_all(core)
  yank(markdown.all(core))
end

function M.setup(core, opts)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"

  vim.api.nvim_create_user_command("ReviewYankFile", function() yank_file(core) end, {})
  vim.api.nvim_create_user_command("ReviewYankAll", function() yank_all(core) end, {})
  vim.api.nvim_create_user_command("Ryf", function() yank_file(core) end, {})
  vim.api.nvim_create_user_command("Rya", function() yank_all(core) end, {})

  -- Yank/export agrupado bajo <leader>ry: yf = file, ya = all.
  vim.keymap.set("n", leader .. "yf", function() yank_file(core) end, { desc = "Review: yank comments (file)" })
  vim.keymap.set("n", leader .. "ya", function() yank_all(core) end, { desc = "Review: yank comments (all)" })
end

return M
