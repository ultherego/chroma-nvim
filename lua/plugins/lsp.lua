-- LSP layer.
--
-- This is the part of the contract that changed most between reading the docs
-- and writing the config, so the reasoning is recorded here rather than in a
-- commit message.
--
-- On Neovim 0.12 the old pattern is gone:
--
--   require('lspconfig').terraformls.setup{}   -- DEPRECATED, will become an error
--
-- nvim-lspconfig no longer configures anything. It ships `lsp/<name>.lua`
-- files that Neovim discovers on its own, and `require('lspconfig')` now emits
-- a deprecation warning. Configuration happens through the native API instead:
-- vim.lsp.config() to define, vim.lsp.enable() to activate.
--
-- Resolution order for a server's settings (:help lsp-config-merge):
--
--   1. vim.lsp.config('*', ...)              lowest priority
--   2. lsp/<name>.lua        on runtimepath  <- provided by nvim-lspconfig
--   3. after/lsp/<name>.lua  on runtimepath  <- our per-server overrides
--   4. vim.lsp.config('<name>', ...)         highest priority
--
-- Per-server tweaks therefore live in after/lsp/, which is finally what the
-- contract's `after` directory is for.
--
-- mason-lspconfig v2 dropped `setup_handlers()` and `automatic_installation`
-- entirely; `automatic_enable` now calls vim.lsp.enable() for every installed
-- server. Both mason repos also moved to the `mason-org` organisation.

return {
  {
    "mason-org/mason.nvim",
    cmd = { "Mason", "MasonInstall", "MasonUpdate" },
    opts = {},
  },

  -- Non-LSP tooling (linters, formatters). The formatting and lint layers
  -- extend this list; only tools already verified as supported are listed.
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    event = "VeryLazy",
    dependencies = { "mason-org/mason.nvim" },
    opts = {
      ensure_installed = {
        -- tflint ships an LSP mode and nvim-lspconfig exposes lsp/tflint.lua,
        -- so installing it here also enables it as a language server and it
        -- attaches to terraform buffers on its own. That is the intended
        -- behaviour: diagnostics arrive natively over LSP. The lint layer must
        -- therefore NOT also register tflint with nvim-lint, or every finding
        -- would be reported twice.
        "tflint",
        -- nvim-lint supports these two by name
        "ansible-lint",
        "yamllint",
        -- conform supports these two by name
        "stylua",
        "shfmt",
      },
      run_on_start = true,
    },
  },

  -- SchemaStore: JSON and YAML schemas, consumed by after/lsp/yamlls.lua
  -- and after/lsp/jsonls.lua.
  {
    "b0o/SchemaStore.nvim",
    lazy = true,
    version = false,
  },

  -- Neovim 0.12 does NOT detect the `helm` filetype: a template sitting next
  -- to Chart.yaml is still detected as plain `yaml`. helm_ls only attaches to
  -- filetypes `helm` and `yaml.helm-values`, so without this plugin helm_ls
  -- would never start, and yamlls would instead try to parse Go templates as
  -- YAML and flood them with errors. nvim-lspconfig's own helm_ls doc points
  -- at this plugin. Last upstream push was 2025-09, acceptable for a syntax
  -- plugin; note its licence is unspecified.
  {
    "towolf/vim-helm",
    ft = { "helm", "yaml" },
  },

  {
    "mason-org/mason-lspconfig.nvim",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = {
      { "mason-org/mason.nvim", opts = {} },
      "neovim/nvim-lspconfig",
    },
    opts = {
      -- Names are nvim-lspconfig config names; mason-lspconfig maps them onto
      -- mason package names. Every one verified to exist in nvim-lspconfig's
      -- lsp/ directory before being listed here.
      ensure_installed = {
        "terraformls",
        "helm_ls",
        "dockerls",
        "docker_compose_language_service",
        "yamlls",
        "ansiblels",
        "bashls",
        "jsonls",
        "lua_ls",
      },
      -- Calls vim.lsp.enable() for installed servers. Replaces the removed
      -- setup_handlers() mechanism.
      --
      -- stylua is excluded deliberately. It is installed above as a conform
      -- formatter, but nvim-lspconfig also ships an lsp/stylua.lua (stylua has
      -- a `--lsp` mode), so automatic_enable would otherwise start it as a
      -- language server on every Lua buffer and have it compete with conform
      -- for formatting. Verified: without this, `stylua` attaches alongside
      -- lua_ls.
      automatic_enable = {
        exclude = { "stylua" },
      },
    },
    config = function(_, opts)
      -- Defaults applied to every server, set before anything is enabled.
      vim.lsp.config("*", {
        root_markers = { ".git" },
      })

      require("mason-lspconfig").setup(opts)
    end,
    keys = {
      { "<leader>li", "<cmd>checkhealth vim.lsp<cr>", desc = "LSP status" },
      { "<leader>ls", "<cmd>FzfLua lsp_document_symbols<cr>", desc = "Document symbols" },
      { "<leader>lS", "<cmd>FzfLua lsp_live_workspace_symbols<cr>", desc = "Workspace symbols" },
      { "<leader>ld", "<cmd>FzfLua lsp_document_diagnostics<cr>", desc = "Document diagnostics" },
      { "<leader>lm", "<cmd>Mason<cr>", desc = "Mason" },
      -- Rename, code action, references, implementation and type definition
      -- are Neovim 0.12 defaults (grn, gra, grr, gri, grt) and are not
      -- duplicated here.
    },
  },
}
