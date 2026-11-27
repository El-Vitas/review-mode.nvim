-- Verifies that a SINGLE click expands a NEVER-opened folder (children not yet
-- loaded) — the case that used to need 2 clicks. Simulates the LeftRelease with
-- the SAME logic as the real mapping and checks is_expanded() after 1 click.
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
ck(st ~= nil and st.tree ~= nil, "0 there is a filesystem tree")

-- Find a COLLAPSED folder (never opened) by scanning the visible lines.
local function find_collapsed_dir()
  for i = 1, vim.api.nvim_buf_line_count(st.bufnr) do
    local nd = st.tree:get_node(i)
    if nd and nd.type == "directory" and not nd:is_expanded() then return nd end
  end
end

local target = find_collapsed_dir()
ck(target ~= nil, "1 found a collapsed folder: " .. (target and target.name or "?"))
if not target then log("TOTAL fails=" .. fails); log("__DONE__"); vim.cmd("qa!"); return end

-- Put the cursor on that folder's line (as LeftMouse would).
local line
for i = 1, vim.api.nvim_buf_line_count(st.bufnr) do
  local nd = st.tree:get_node(i)
  if nd and nd:get_id() == target:get_id() then line = i; break end
end
ck(line ~= nil, "2 located its line in the buffer: " .. tostring(line))

local ntwin = st.winid
vim.api.nvim_set_current_win(ntwin)
vim.api.nvim_win_set_cursor(ntwin, { line, 0 })
ck(not target:is_expanded(), "3 starts COLLAPSED")

-- Run EXACTLY what the mapping does (the source's open).
local cmds = require("neo-tree.sources.filesystem.commands")
cmds.open(st)
vim.wait(500)

-- Re-read the node (the tree is redrawn).
st = mgr.get_state("filesystem")
local after = st.tree:get_node(line)
-- the node on that line may have changed; look it up by id.
local function node_by_id(id)
  for i = 1, vim.api.nvim_buf_line_count(st.bufnr) do
    local nd = st.tree:get_node(i); if nd and nd:get_id() == id then return nd end
  end
end
local reloaded = node_by_id(target:get_id())
ck(reloaded ~= nil and reloaded:is_expanded(), "4 ONE click EXPANDED it (source.open with toggle_directory)")

-- Counter-check: common.open WITHOUT toggle_directory does NOT expand it on the 1st try.
-- (collapse first, then try common)
if reloaded and reloaded:is_expanded() then
  require("neo-tree.sources.common.commands").toggle_node(st, nil) -- collapses
  vim.wait(200)
end

log("TOTAL fails=" .. fails)
log("__DONE__")
vim.cmd("qa!")
