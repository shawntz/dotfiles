return {
  "nvim-treesitter/nvim-treesitter",
  run = ":TSUpdate",
  config = function()
    require("nvim-treesitter.configs").setup({
      ensure_installed = { "markdown", "markdown_inline", "r", "rnoweb", "yaml", "csv" },
      highlight = { enable = true },
    })
  end,
}
