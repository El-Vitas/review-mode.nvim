local store = require("review.core.store")

local M = {}

-- Cache del ORIGEN de un rename (declarado arriba para que set_base lo vea).
-- Clave "root\0base\0relpath"; `false` = no es rename (archivo nuevo de verdad).
local rename_cache = {}

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
  rename_cache = {} -- la base cambió → recalcular orígenes de renames
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

--- Si `relpath` es el DESTINO de un rename/copy vs la base, devuelve su path
--- ORIGEN (el que existe en la base). Si no, nil. Consistente con cómo git
--- detecta renames en el resto de superficies (sidebar, statusline).
-- Escanea la salida de `git diff -M --name-status -z <...>` buscando un rename/
-- copy cuyo DESTINO sea `relpath`; devuelve su ORIGEN. OJO: vim.fn.system()
-- mapea los NUL a SOH (\1), por eso separamos por "\1" (igual que neo-tree).
local function scan_rename(args, relpath)
  local out = vim.fn.system(args)
  if vim.v.shell_error ~= 0 then return nil end
  local parts = vim.split(out, "\1", { plain = true })
  local i = 1
  while i <= #parts and parts[i] ~= "" do
    local st = parts[i]
    if st:match("^[RC]") then -- rename/copy: <status>\1<old>\1<new>
      if parts[i + 2] == relpath then return parts[i + 1] end
      i = i + 3
    else -- resto: <status>\1<path>
      i = i + 2
    end
  end
  return nil
end

--- Si `relpath` es el DESTINO de un rename/copy vs la base, devuelve su path
--- ORIGEN (el que existe en la base). Público para que otras superficies
--- (gitsigns) traten los renombrados de forma CONSISTENTE. `base` opcional
--- (default `M.base_ref`).
function M.rename_source(relpath, root, base)
  base = base or M.base_ref
  local key = (root or "") .. "\0" .. base .. "\0" .. relpath
  local c = rename_cache[key]
  if c ~= nil then return c or nil end

  local found
  if base == ":" then
    -- index (staged) vs HEAD.
    found = scan_rename({ "git", "-C", root, "diff", "-M", "--name-status", "-z", "--cached" }, relpath)
  else
    -- 1) rename COMMITTED (base..HEAD): detección fiable aunque el archivo se
    --    haya editado después (el umbral -M se mide sobre el commit, no el
    --    working tree). 2) fallback: rename sin commitear (base vs working).
    found = scan_rename({ "git", "-C", root, "diff", "-M", "--name-status", "-z", base, "HEAD" }, relpath)
    if not found then
      found = scan_rename({ "git", "-C", root, "diff", "-M", "--name-status", "-z", base }, relpath)
    end
  end
  rename_cache[key] = found or false
  return found
end
local rename_source = M.rename_source

-- Cache de la raíz del repo por directorio. `git rev-parse` es un subproceso y
-- root()/rel_path() se llaman muy seguido (render en BufEnter, sync de vistas,
-- etc.). La raíz de un directorio es estable, así que la cacheamos: string =
-- raíz encontrada, false = ese dir no está en un repo (usar fallback por cwd).
local root_cache = {}

--- Limpia el cache de raíces (por si cambió la estructura de repos).
function M.clear_cache()
  root_cache = {}
  rename_cache = {}
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
