local M = {}
local _features = {}

function M.register(feature)
  assert(feature and feature.name and feature.setup, "invalid feature")
  _features[feature.name] = feature
end

function M.features()
  return _features
end

-- Clears the feature registry. For tests (keeps real features
-- self-registered by other specs from contaminating a registry test).
function M._reset()
  _features = {}
end

-- Propagates the global `leader` to each feature (unless the feature has its
-- own). Without this, feature keymaps never see the global leader.
function M.setup(core, opts)
  opts = opts or {}
  local fopts = opts.features or {}
  local global_leader = opts.leader or "<leader>r"
  for name, feature in pairs(_features) do
    local cfg = fopts[name] or {}
    cfg.leader = cfg.leader or global_leader
    if cfg.enabled ~= false then
      feature.setup(core, cfg)
    end
  end
end

return M
