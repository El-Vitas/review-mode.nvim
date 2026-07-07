local plenary = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
vim.opt.runtimepath:append(plenary)
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.cmd("runtime plugin/plenary.vim")
