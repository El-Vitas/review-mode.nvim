-- Lowercase aliases for the review.nvim commands (centralized).
-- Each feature registers its capitalized command in its own setup.
--
-- They only expand when the command line is EXACTLY the alias. A plain
-- `cnoreabbrev` expands on any word: `:%s/rl/x/g` turned into
-- `:%s/Rl/x/g` and `:g/rt/d` deleted the lines containing "Rt".
local aliases = {
  rcm = "Rcm", rl = "Rl", rlf = "Rlf", rt = "Rt", rp = "Rp", rpa = "Rpa", rpc = "Rpc",
  ryf = "Ryf", rya = "Rya", rv = "Rv", rvn = "Rvn", rvi = "Rvi", rvs = "Rvs", rs = "Rs",
}
for lower, cmd in pairs(aliases) do
  vim.cmd(("cnoreabbrev <expr> %s (getcmdtype() ==# ':' && getcmdline() ==# '%s') ? '%s' : '%s'")
    :format(lower, lower, cmd, lower))
end
