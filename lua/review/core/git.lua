local store = require("review.core.store")

local M = {}

-- Cache de la raíz del repo por directorio. `git rev-parse` es un subproceso y
-- root()/rel_path() se llaman muy seguido (render en BufEnter, sync de vistas,
-- etc.). La raíz de un directorio es estable, así que la cacheamos: string =
-- raíz encontrada, false = ese dir no está en un repo (usar fallback por cwd).
local root_cache = {}

--- Limpia el cache de raíces (por si cambió la estructura de repos).
function M.clear_cache()
  root_cache = {}
end

--- Raíz del repo. Si se pasa `bufnr`, la resuelve desde el DIRECTORIO DEL
--- ARCHIVO de ese buffer (`git -C <dir> rev-parse`), de modo que funcione
--- aunque el cwd de Neovim esté en otro lado (caso típico: abrir nvim en ~ y
--- editar un proyecto, o saltar entre archivos con telescope/harpoon). Si no
--- hay bufnr, o el archivo no está en un repo, cae en `store.root_fn()`
--- (detección por cwd, y punto de override en tests).
--- @param bufnr integer|nil
--- @return string|nil
function M.root(bufnr)
  if bufnr then
    local full = vim.api.nvim_buf_get_name(bufnr)
    if full ~= "" then
      local dir = vim.fn.fnamemodify(full, ":h")
      local cached = root_cache[dir]
      if cached == nil then
        local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
        cached = (vim.v.shell_error == 0 and out[1] and out[1] ~= "") and out[1] or false
        root_cache[dir] = cached
      end
      if cached then return cached end
    end
  end
  return store.root_fn()
end

function M.rel_path(bufnr)
  local full = vim.api.nvim_buf_get_name(bufnr)
  if full == "" then return nil end
  local root = M.root(bufnr)
  if not root then return nil end
  -- Resolver symlinks para que el prefijo matchee (git devuelve el path
  -- canónico; el nombre del buffer puede venir por un symlink).
  full = vim.fn.resolve(full)
  root = vim.fn.resolve(root):gsub("/$", "")
  if full:sub(1, #root + 1) == root .. "/" then
    return full:sub(#root + 2)
  end
  return nil
end

--- Contenido del archivo en HEAD. `root` opcional: si se pasa, se usa ese repo
--- (para que coincida con el repo del buffer resuelto por `M.root(bufnr)`); si
--- no, cae en `M.root()` (cwd).
--- @param relpath string
--- @param root string|nil
--- @return string[]|nil
function M.head_content(relpath, root)
  root = root or M.root()
  if not root then return nil end
  local out = vim.fn.systemlist({ "git", "-C", root, "show", "HEAD:" .. relpath })
  if vim.v.shell_error ~= 0 then return nil end
  -- Normalizar CRLF: `git show` devuelve el contenido tal cual (con `\r` si el
  -- archivo es CRLF), pero Neovim quita el `\r` en buffers `fileformat=dos`.
  -- Sin esto, CADA línea diferiría por el `\r` -> "todo cambiado".
  for i, l in ipairs(out) do
    out[i] = (l:gsub("\r$", ""))
  end
  return out
end

function M.changed_files()
  local root = M.root()
  if not root then return {} end
  local tracked = vim.fn.systemlist({ "git", "-C", root, "diff", "--name-only", "HEAD" })
  if vim.v.shell_error ~= 0 then tracked = {} end
  local untracked = vim.fn.systemlist({ "git", "-C", root, "ls-files", "--others", "--exclude-standard" })
  if vim.v.shell_error ~= 0 then untracked = {} end
  local seen, out = {}, {}
  for _, f in ipairs(tracked) do if f ~= "" and not seen[f] then seen[f] = true; out[#out+1] = f end end
  for _, f in ipairs(untracked) do if f ~= "" and not seen[f] then seen[f] = true; out[#out+1] = f end end
  return out
end

return M
