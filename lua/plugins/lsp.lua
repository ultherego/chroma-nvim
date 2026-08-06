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
    cmd = { "Mason", "MasonInstall", "MasonUpdate", "MasonVersions" },
    opts = {},
    config = function(_, opts)
      require("mason").setup(opts)

      -- Prints installed packages as `name@version`, the exact form the
      -- ensure_installed lists below use.
      --
      -- Pinning versions is only sustainable if raising them is mechanical:
      -- run this, compare, paste. Without it the pins rot, which is worse than
      -- not pinning at all — you get an old toolchain *and* the illusion of
      -- deliberate choice.
      vim.api.nvim_create_user_command("MasonVersions", function()
        local lines = {}
        for _, pkg in ipairs(require("mason-registry").get_installed_packages()) do
          local ok, id = pcall(function()
            return pkg:get_receipt()._value.source.id
          end)
          table.insert(lines, ("%s@%s"):format(pkg.name, (ok and id and id:match("@([^@]+)$")) or "?"))
        end
        table.sort(lines)
        vim.print(table.concat(lines, "\n"))
      end, { desc = "Print installed Mason packages as name@version" })
    end,
  },

  -- Non-LSP tooling (linters, formatters). The formatting and lint layers
  -- extend this list; only tools already verified as supported are listed.
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    event = "VeryLazy",
    dependencies = { "mason-org/mason.nvim" },
    opts = {
      -- Pinned with `package@version`, which Mason supports directly.
      --
      -- lazy-lock.json pins plugins; it says nothing about the binaries Mason
      -- fetches, so without this a fresh install six months from now gets
      -- different tool versions and different diagnostics from the same
      -- configuration.
      --
      -- Two things this deliberately does NOT cover, because they turned out
      -- to be pinned already: treesitter parsers carry explicit revisions in
      -- nvim-treesitter's own parsers.lua, and kubectl.nvim downloads the
      -- binary matching its checked-out release — both therefore follow
      -- lazy-lock.json.
      --
      -- The cost is that these have to be raised by hand. `:MasonVersions`
      -- prints what is installed, in the exact form used here.
      ensure_installed = {
        -- tflint ships an LSP mode and nvim-lspconfig exposes lsp/tflint.lua,
        -- so installing it here also enables it as a language server and it
        -- attaches to terraform buffers on its own. That is the intended
        -- behaviour: diagnostics arrive natively over LSP. The lint layer must
        -- therefore NOT also register tflint with nvim-lint, or every finding
        -- would be reported twice.
        "tflint@v0.64.0",
        -- nvim-lint linters (see plugins/lint.lua)
        "ansible-lint@26.6.0",
        "yamllint@1.38.0",
        "hadolint@v2.15.1",
        "actionlint@v1.7.12",
        -- conform formatters (see plugins/formatting.lua)
        "stylua@v2.5.2",
        "shfmt@v3.13.1",
        "jq@jq-1.7",
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
      -- Names are nvim-lspconfig config names, which mason-lspconfig maps onto
      -- Mason packages; every one was verified to exist in nvim-lspconfig's
      -- lsp/ directory. The version after `@` is the Mason package's, pinned
      -- for the same reason as the tools above.
      ensure_installed = {
        "terraformls@v0.39.0",
        "helm_ls@v0.5.4",
        "dockerls@0.15.0",
        "docker_compose_language_service@1.0.0",
        "yamlls@1.24.0",
        "ansiblels@26.6.0",
        "bashls@5.6.0",
        "jsonls@4.10.0",
        "lua_ls@3.18.2",
      },
      -- An explicit allow-list, not `true` and not an exclude list.
      --
      -- `automatic_enable = true` enables every server Mason has installed,
      -- including ones installed by hand months ago for an unrelated project.
      -- That silently widens what runs without any change to this repository,
      -- and can produce duplicate diagnostics from competing servers. Naming
      -- the list means the set of servers is a property of the config rather
      -- than of whatever happens to be in the Mason directory.
      --
      -- tflint is on the list on purpose: it ships an LSP mode, and Terraform
      -- diagnostics arrive through it. That is why plugins/lint.lua must not
      -- also register tflint with nvim-lint.
      --
      -- stylua is NOT on the list even though it is installed. It is a conform
      -- formatter here, but nvim-lspconfig also ships lsp/stylua.lua, and an
      -- unrestricted automatic_enable starts it as a language server on every
      -- Lua buffer where it competes with conform. Verified.
      automatic_enable = {
        "terraformls",
        "tflint",
        "helm_ls",
        "dockerls",
        "docker_compose_language_service",
        "yamlls",
        "ansiblels",
        "bashls",
        "jsonls",
        "lua_ls",
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
