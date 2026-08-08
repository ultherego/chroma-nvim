-- LSP layer, on the native 0.12 API: nvim-lspconfig only ships lsp/<name>.lua
-- and Neovim discovers them. Per-server overrides go in after/lsp/.
-- See :help devops-nvim-lsp and :help lsp-config-merge.

return {
  {
    "mason-org/mason.nvim",
    cmd = { "Mason", "MasonInstall", "MasonUpdate", "MasonVersions" },
    opts = {},
    config = function(_, opts)
      require("mason").setup(opts)

      -- Prints `name@version`, the form the ensure_installed lists use, so pins
      -- can be raised by comparing rather than by hand.
      vim.api.nvim_create_user_command("MasonVersions", function()
        local lines = {}
        for _, pkg in ipairs(require("mason-registry").get_installed_packages()) do
          -- `_value` is the receipt's internal table, not a promised interface.
          -- The pcall is why a Mason release reshaping it prints `?` instead of
          -- breaking the command; check the shape after upgrading Mason.
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
      -- lazy-lock.json pins plugins, not the binaries Mason fetches. Raised by
      -- hand; `:MasonVersions` prints them in this form.
      ensure_installed = {
        -- Runs as a language server, so plugins/lint.lua must not register it
        -- with nvim-lint as well.
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

  -- Neovim does not detect the `helm` filetype, so without this helm_ls never
  -- attaches and yamlls parses Go templates as YAML. Licence unspecified.
  {
    "towolf/vim-helm",
    ft = { "helm", "yaml" },
    init = function()
      -- The plugin brings its own detection for chart templates, but it is an
      -- autocommand the plugin installs — and the plugin is loaded by filetype.
      -- Measured: Neovim calls `templates/_helpers.tpl` smarty, so opening one as
      -- the first file of a session never loads vim-helm, never installs the
      -- autocommand, and leaves it smarty with no helm_ls and no helm parser.
      -- Opening a chart's YAML first hid this, which is why it looked like it
      -- worked.
      --
      -- Decided here instead, before anything is loaded, so the answer does not
      -- depend on what was opened first.
      vim.filetype.add({
        pattern = {
          [".*/templates/.*%.tpl"] = function(path)
            -- A `.tpl` under `templates/` is Helm's only if a chart says so.
            return vim.fs.root(path, "Chart.yaml") and "helm" or nil
          end,
        },
      })
    end,
  },

  {
    "mason-org/mason-lspconfig.nvim",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = {
      { "mason-org/mason.nvim", opts = {} },
      "neovim/nvim-lspconfig",
    },
    opts = {
      -- nvim-lspconfig config names; the version after `@` is the Mason package's.
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
      -- An allow-list, not `true`: that would enable every server Mason has ever
      -- installed, including stylua, which would then compete with conform.
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
      -- grn, gra, grr, gri, grt are 0.12 defaults and are not duplicated here.
    },
  },
}
