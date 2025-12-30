-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
vim.opt.relativenumber = false
vim.opt.relativenumber = true
-- vim.opt.cursorline = false

vim.api.nvim_create_autocmd({ "InsertEnter" }, {
  callback = function()
    vim.opt.cursorline = false
  end,
})

vim.api.nvim_create_autocmd({ "InsertLeave" }, {
  callback = function()
    vim.opt.cursorline = true
  end,
})
