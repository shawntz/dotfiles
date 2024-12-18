return {
  -- colorscheme
  "ellisonleao/gruvbox.nvim",
  priority = 1000,
  config = function()
    -- load colorscheme
    vim.cmd([[colorscheme gruvbox]])
  end,
}
