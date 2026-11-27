local store = require("review.core.store")

local M = {}

-- Rename maps per repo and base (declared at the top so set_base can see it).
-- Key "root\0base" → { map = { [destination] = origin }, stamp = fingerprint }. A single
-- `git diff` per repo/base pair for all files, instead of two for each
-- new file. Against a distant base that diff takes hundreds of ms, so the
-- map is not thrown away when focus returns: it is recomputed only if the fingerprint changed.
local rename_maps = {}

-- Review comparison base (what the views / changes are compared against).
-- "HEAD" (default), a hash/branch, or ":" for the index (staged). Changed with
-- :ReviewBase (see features/base). head_content and changed_files respect it.
M.base_ref = "HEAD"
-- Human-readable label of the base (commit subject) for the statusline. Set by
-- the `base` feature when choosing/restoring; nil = show the bare ref.
M.base_label = nil

function M.set_base(ref)
  M.base_ref = (ref == nil or ref == "") and "HEAD" or ref
  M.base_label = nil -- re-set from the base feature if there is a subject
  rename_maps = {} -- the base changed → recompute rename origins
end

--- EFFECTIVE base for external integrations (neo-tree git_base, statusline,
--- etc.): nil when there is no explicit base (HEAD / index ":" / empty), or the
--- concrete ref (commit/branch). The ONLY source to translate base_ref → "diff vs X".
--- Anything that opens/reveals neo-tree or compares must use THIS (do not reimplement it).
function M.effective_base()
  local b = M.base_ref
  if not b or b == "" or b == "HEAD" or b == ":" then return nil end
  return b
end

-- `git show` spec for the file in the current base: `<ref>:relpath`, or for
-- the index `:relpath`.
local function show_spec(relpath)
  if M.base_ref == ":" then return ":" .. relpath end
  return M.base_ref .. ":" .. relpath
end

-- Adds to `map` the renames/copies from the output of
-- `git diff -M --name-status -z <...>` as { [destination] = origin }, without overwriting
-- destinations already present (the first diff scanned has priority).
local function scan_renames(out, map)
  local parts = vim.split(out, "\0", { plain = true })
  local i = 1
  while i <= #parts and parts[i] ~= "" do
    local st = parts[i]
    if st:match("^[RC]") then -- rename/copy: <status>\0<old>\0<new>
      local old, new = parts[i + 1], parts[i + 2]
      if new and map[new] == nil then map[new] = old end
      i = i + 3
    else -- rest: <status>\0<path>
      i = i + 2
    end
  end
end

-- Rename computations in progress, keyed the same as `rename_maps`.
local inflight = {}

-- Launches (or reuses) the background computation of the rename map for root/base.
-- Detecting renames costs git ~115 ms per diff in a large repo against a distant
-- base; running it separately, the map is usually ready before the first file
-- that needs it is opened. Returns the current entry or the job.
local function renames_job(root, base)
  local key = root .. "\0" .. base
  local stamp = M.repo_stamp(root)
  local entry = rename_maps[key]
  if entry and entry.stamp == stamp then return entry end
  local job = inflight[key]
  if job and job.stamp == stamp then return job end

  -- 1) COMMITTED renames (base..HEAD): reliable detection even if the file was
  --    edited afterwards (the -M threshold is measured on the commit, not the
  --    working tree). 2) then, uncommitted renames (base vs working).
  -- With the base on the index (":"): index vs HEAD.
  local diffs = base == ":" and { { "--cached" } } or { { base, "HEAD", "--" }, { base, "--" } }
  job = { stamp = stamp, outs = {}, procs = {}, left = #diffs }
  inflight[key] = job
  local function finish()
    if job.done then return end
    job.done = true
    local map = {}
    for i = 1, #diffs do scan_renames(job.outs[i] or "", map) end
    job.map = map
    if inflight[key] == job then
      inflight[key] = nil
      rename_maps[key] = { map = map, stamp = job.stamp }
    end
  end
  job.finish = finish
  for i, args in ipairs(diffs) do
    local cmd = vim.list_extend({ "git", "-C", root, "diff", "-M", "--name-status", "-z" }, args)
    local ok, proc = pcall(vim.system, cmd, { text = false }, function(res)
      job.outs[i] = res.code == 0 and res.stdout or ""
      job.left = job.left - 1
      if job.left == 0 then vim.schedule(finish) end
    end)
    if ok then job.procs[i] = proc else job.outs[i] = ""; job.left = job.left - 1 end
  end
  if job.left == 0 then finish() end
  return job
end

--- Computes in the background the renames of the current base for repo `root`
--- (default: the cwd's), if they are not already up to date. Does not block.
--- @param root string|nil
function M.prefetch_renames(root)
  root = root or M.root()
  if root then renames_job(root, M.base_ref) end
end

--- If `relpath` is the DESTINATION of a rename/copy vs the base, returns its
--- ORIGIN path (the one that exists in the base). Otherwise nil. Public so other
--- surfaces (gitsigns) treat renamed files CONSISTENTLY. `base` is
--- optional (default `M.base_ref`). If the map is not ready, it waits for the
--- computation in progress (or launches it) instead of running another one.
function M.rename_source(relpath, root, base)
  if not root then return nil end
  local job = renames_job(root, base or M.base_ref)
  if not job.map then
    for i, p in pairs(job.procs) do
      local ok, res = pcall(p.wait, p)
      if job.outs[i] == nil then job.outs[i] = (ok and res.code == 0 and res.stdout) or "" end
    end
    job.finish()
  end
  return job.map[relpath]
end
local rename_source = M.rename_source

-- Cache of the repo root per directory. `git rev-parse` is a subprocess and
-- root()/rel_path() are called very often (render on BufEnter, view sync,
-- etc.). A directory's root is stable, so we cache it: string =
-- root found, false = that dir is not in a repo (use the cwd fallback).
local root_cache = {}
-- .git folder of each root (in a worktree it is not `<root>/.git`).
local gitdir_cache = {}

--- Cheap fingerprint of the repo state, without spawning processes after the
--- first time: mtime and size of the index, of HEAD and of HEAD's reflog. A `git mv`
--- rewrites the index; a commit, a checkout or a reset adds a line to the
--- reflog. Editing files touches none of that, and it does not change renames either (a
--- rename without `git add` is not a rename for git).
--- @param root string
--- @return string
function M.repo_stamp(root)
  local dir = gitdir_cache[root]
  if dir == nil then
    local out = vim.fn.systemlist({ "git", "-C", root, "rev-parse", "--absolute-git-dir" })
    dir = (vim.v.shell_error == 0 and out[1]) or false
    gitdir_cache[root] = dir
  end
  if not dir then return "" end
  local function mt(p)
    local st = vim.uv.fs_stat(p)
    return st and (st.mtime.sec .. "." .. st.mtime.nsec .. ":" .. st.size) or "-"
  end
  return mt(dir .. "/index") .. "|" .. mt(dir .. "/HEAD") .. "|" .. mt(dir .. "/logs/HEAD")
end

--- Clears the root cache. Called when focus returns to Neovim, because a
--- `git init` or a clone done outside leaves it stale. Renames are not
--- discarded: `rename_source` recomputes them only if `repo_stamp` changed.
function M.clear_cache()
  root_cache = {}
  gitdir_cache = {}
end

--- Repo root. If `bufnr` is passed, it resolves it from the DIRECTORY OF THE
--- FILE of that buffer (`git -C <dir> rev-parse`), so it works
--- even if Neovim's cwd is elsewhere (typical case: opening nvim in ~ and
--- editing a project, or jumping between files with telescope/harpoon). If there
--- is no bufnr, or the file is not in a repo, it falls back to `store.root_fn()`
--- (cwd detection, and the override point in tests).
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
  -- Resolve symlinks so the prefix matches (git returns the canonical
  -- path; the buffer name may come through a symlink).
  full = vim.fn.resolve(full)
  root = vim.fn.resolve(root):gsub("/$", "")
  if full:sub(1, #root + 1) == root .. "/" then
    return full:sub(#root + 2)
  end
  return nil
end

--- Content of the file at HEAD. `root` is optional: if passed, that repo is used
--- (so it matches the buffer's repo resolved by `M.root(bufnr)`); if
--- not, it falls back to `M.root()` (cwd).
--- @param relpath string
--- @param root string|nil
--- @return string[]|nil
function M.head_content(relpath, root)
  root = root or M.root()
  if not root then return nil end
  local out = vim.fn.systemlist({ "git", "-C", root, "show", show_spec(relpath) })
  if vim.v.shell_error ~= 0 then
    -- The current path does not exist in the base: it may be a RENAME. Look up its
    -- old path and diff against THAT one (so a renamed file does not show up as
    -- entirely "new", consistent with the sidebar that marks it R).
    local old = rename_source(relpath, root)
    if not old then return nil end
    local spec = (M.base_ref == ":") and (":" .. old) or (M.base_ref .. ":" .. old)
    out = vim.fn.systemlist({ "git", "-C", root, "show", spec })
    if vim.v.shell_error ~= 0 then return nil end
  end
  -- Normalize CRLF: `git show` returns the content as is (with `\r` if the
  -- file is CRLF), but Neovim strips the `\r` in `fileformat=dos` buffers.
  -- Without this, EVERY line would differ by the `\r` -> "everything changed".
  for i, l in ipairs(out) do
    out[i] = (l:gsub("\r$", ""))
  end
  return out
end

--- Content the views compare against: the base's (`head_content`),
--- or `{}` if the file does NOT exist in the base (it is new relative to it: all its
--- content is added). `nil` if it is ignored by git (node_modules, build…):
--- that is not new project content and is not marked.
--- @param relpath string
--- @param root string|nil
--- @return string[]|nil
function M.base_lines(relpath, root)
  local head = M.head_content(relpath, root)
  if head then return head end
  root = root or M.root()
  if not root then return nil end
  vim.fn.system({ "git", "-C", root, "check-ignore", "-q", "--", relpath })
  if vim.v.shell_error == 0 then return nil end -- ignored
  return {}
end

function M.changed_files()
  local root = M.root()
  if not root then return {} end
  -- Changes vs the current base. For the index (":") we compare working vs index
  -- (no ref); for a commit/branch/HEAD, `git diff --name-only <ref>`.
  -- `-M`: detect renames explicitly (do not depend on git's default) so
  -- a renamed file shows up ONCE (new path), not as deleted+created.
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
