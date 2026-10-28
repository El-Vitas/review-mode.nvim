local plenary = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
vim.opt.runtimepath:append(plenary)
-- nui: los popups de comentarios (comments/mode.lua) lo usan.
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/nui.nvim")
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.cmd("runtime plugin/plenary.vim")
