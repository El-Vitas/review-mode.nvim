local M = {}
local subs = {}

function M.on(name, cb)
  subs[name] = subs[name] or {}
  table.insert(subs[name], cb)
end

function M.emit(name, payload)
  for _, cb in ipairs(subs[name] or {}) do
    vim.schedule(function()
      local ok, err = pcall(cb, payload or {})
      if not ok then vim.notify("review event " .. name .. ": " .. tostring(err), vim.log.levels.ERROR) end
    end)
  end
end

-- Limpia todas las suscripciones. Necesario en tests para evitar fuga de
-- estado entre casos (los `subs` son module-local y persisten entre `it`).
function M._reset()
  subs = {}
end

return M
