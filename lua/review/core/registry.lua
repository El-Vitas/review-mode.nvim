local M = {}
local _features = {}

function M.register(feature)
  assert(feature and feature.name and feature.setup, "feature inválida")
  _features[feature.name] = feature
end

function M.features()
  return _features
end

-- Limpia el registro de features. Para tests (evita que features reales
-- auto-registradas por otros specs contaminen un test del registry).
function M._reset()
  _features = {}
end

-- Propaga el `leader` global a cada feature (salvo que la feature tenga uno
-- propio). Sin esto, los keymaps de las features nunca ven el leader global.
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
