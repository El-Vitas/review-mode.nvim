-- Alias en minúscula para los comandos de review.nvim (centralizado).
-- Cada feature registra su comando capitalizado en su propio setup.
--
-- Solo expanden cuando la línea de comandos es EXACTAMENTE el alias. Un
-- `cnoreabbrev` simple expande en cualquier palabra: `:%s/rl/x/g` pasaba a
-- `:%s/Rl/x/g` y `:g/rt/d` borraba las líneas con "Rt".
local aliases = {
  rcm = "Rcm", rl = "Rl", rlf = "Rlf", rt = "Rt", rp = "Rp", rpa = "Rpa", rpc = "Rpc",
  ryf = "Ryf", rya = "Rya", rv = "Rv", rvn = "Rvn", rvi = "Rvi", rvs = "Rvs", rs = "Rs",
}
for lower, cmd in pairs(aliases) do
  vim.cmd(("cnoreabbrev <expr> %s (getcmdtype() ==# ':' && getcmdline() ==# '%s') ? '%s' : '%s'")
    :format(lower, lower, cmd, lower))
end
