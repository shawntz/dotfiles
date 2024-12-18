return {
  "dundalek/lazy-lsp.nvim",
  dependencies = {
    "neovim/nvim-lspconfig",
    { "VonHeikemen/lsp-zero.nvim", branch = "v3.x" },
    "hrsh7th/cmp-nvim-lsp",
    "hrsh7th/nvim-cmp",
  },
  config = function()
    require("lazy-lsp").setup {}
  end
}
