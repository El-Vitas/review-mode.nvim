local store = require("review.core.store")

local M = {}

-- Mapas de renames por repo y base (declarado arriba para que set_base lo vea).
-- Clave "root\0base" → { [destino] = origen }. Un solo `git diff` por par
-- repo/base para todos los archivos, en vez de dos por cada archivo nuevo.
local rename_maps = {}

-- Base de comparación de review (contra qué se comparan las vistas / cambios).
-- "HEAD" (default), un hash/branch, o ":" para el index (staged). Se cambia con
-- :ReviewBase (ver features/base). head_content y changed_files la respetan.
M.base_ref = "HEAD"
-- Etiqueta legible de la base (subject del commit) para el statusline. La setea
-- la feature `base` al elegir/restaurar; nil = mostrar el ref pelado.
M.base_label = nil

function M.set_base(ref)
  M.base_ref = (ref == nil or ref == "") and "HEAD" or ref
  M.base_label = nil -- se re-setea desde la feature base si hay subject
  rename_maps = {} -- la base cambió → recalcular orígenes de renames
end

--- Base EFECTIVA para integraciones externas (neo-tree git_base, statusline,
--- etc.): nil cuando no hay base explícita (HEAD / index ":" / vacío), o el ref
--- concreto (commit/branch). ÚNICA fuente para traducir base_ref → "diff vs X".
--- Todo lo que abra/revele neo-tree o compare debe usar ESTO (no reimplementarlo).
function M.effective_base()
  local b = M.base_ref
  if not b or b == "" or b == "HEAD" or b == ":" then return nil end
  return b
end

-- Spec de `git show` para el archivo en la base actual: `<ref>:relpath`, o para
-- el index `:relpath`.
local function show_spec(relpath)
  if M.base_ref == ":" then return ":" .. relpath end
  return M.base_ref .. ":" .. relpath
end

-- Agrega a `map` los renames/copias de la salida de
-- `git diff -M --name-status -z <...>` como { [destino] = origen }, sin pisar
-- destinos que ya estén (el primer diff que se escanea tiene prioridad).
-- vim.fn.system() mapea los NUL a SOH (\1), por eso se separa por "\1" (igual
-- que neo-tree).
local function scan_renames(args, map)
  local out = vim.fn.system(args)
  if vim.v.shell_error ~= 0 then return end
  local parts = vim.split(out, "\1", { plain = true })
  local i = 1
  while i <= #parts and parts[i] ~= "" do
    local st = parts[i]
    if st:match("^[RC]") then -- rename/copy: <status>\1<old>\1<new>
      local old, new = parts[i + 1], parts[i + 2]
      if new and map[new] == nil then map[new] = old end
      i = i + 3
    else -- resto: <status>\1<path>
      i = i + 2
    end
  end
end

--- Si `relpath` es el DESTINO de un rename/copy vs la base, devuelve su path
--- ORIGEN (el que existe en la base). Si no, nil. Público para que otras
--- superficies (gitsigns) traten los renombrados de forma CONSISTENTE. `base`
--- opcional (default `M.base_ref`).
function M.rename_source(relpath, root, base)
  if not root then return nil end
  base = base or M.base_ref
  local key = root .. "\0" .. base
  local map = rename_maps[key]
  if not map then
    map = {}
    if base == ":" then
      -- index (staged) vs HEAD.
      scan_renames({ "git", "-C", root, "diff", "-M", "--name-status", "-z", "--cached" }, map)
    else
      -- 1) renames COMMITEADOS (base..HEAD): detección fiable aunque el archivo
      --    se haya editado después (el umbral -M se mide sobre el commit, no el
      --    working tree). 2) después, renames sin commitear (base vs working).
      scan_renames({ "git", "-C", root, "diff", "-M", "--name-status", "-z", base, "HEAD", "--" }, map)
      scan_renames({ "git", "-C", root, "diff", "-M", "--name-status", "-z", base, "--" }, map)
    end
    rename_maps[key] = map
  end
  return map[relpath]
end
local rename_source = M.rename_source

-- Cache de la raíz del repo por directorio. `git rev-parse` es un subproceso y
-- root()/rel_path() se llaman muy seguido (render en BufEnter, sync de vistas,
-- etc.). La raíz de un directorio es estable, así que la cacheamos: string =
-- raíz encontrada, false = ese dir no está en un repo (usar fallback por cwd).
local root_cache = {}

--- Limpia los caches de raíces y de renames. Se llama al volver el foco a
--- Neovim, porque un `git mv`, un commit o un `git init` hechos afuera los dejan
--- desactualizados.
function M.clear_cache()
  root_cache = {}
  rename_maps = {}
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
  local out = vim.fn.systemlist({ "git", "-C", root, "show", show_spec(relpath) })
  if vim.v.shell_error ~= 0 then
    -- El path actual no existe en la base: puede ser un RENAME. Buscar su path
    -- viejo y diffear contra ESE (así un renombrado no aparece como "nuevo"
    -- entero, consistente con el sidebar que lo marca R).
    local old = rename_source(relpath, root)
    if not old then return nil end
    local spec = (M.base_ref == ":") and (":" .. old) or (M.base_ref .. ":" .. old)
    out = vim.fn.systemlist({ "git", "-C", root, "show", spec })
    if vim.v.shell_error ~= 0 then return nil end
  end
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
  -- Cambios vs la base actual. Para el index (":") comparamos working vs index
  -- (sin ref); para un commit/branch/HEAD, `git diff --name-only <ref>`.
  -- `-M`: detectar renames explícitamente (no depender del default de git) para
  -- que un renombrado aparezca UNA vez (path nuevo), no como borrado+creado.
  local diff_cmd = { "git", "-C", root, "diff", "-M", "--name-only" }
  if M.base_ref ~= ":" then diff_cmd[#diff_cmd + 1] = M.base_ref end
  local tracked = vim.fn.systemlist(diff_cmd)
  if vim.v.shell_error ~= 0 then tracked = {} end
  local untracked = vim.fn.systemlist({ "git", "-C", root, "ls-files", "--others", "--exclude-standard" })
  if vim.v.shell_error ~= 0 then untracked = {} end
  local seen, out = {}, {}
  for _, f in ipairs(tracked) do if f ~= "" and not seen[f] then seen[f] = true; out[#out+1] = f end end
  for _, f in ipairs(untracked) do if f ~= "" and not seen[f] then seen[f] = true; out[#out+1] = f end end
  return out
end

return M
