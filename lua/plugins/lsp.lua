-- LSP layer, on the native 0.12 API: nvim-lspconfig only ships lsp/<name>.lua
-- and Neovim discovers them. Per-server overrides go in after/lsp/.
-- See :help chroma-nvim-lsp and :help lsp-config-merge.

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
    opts = function()
      -- Pinned by hand here; which of them are wanted comes from the enabled
      -- components, so a machine that never selected Ansible does not fetch
      -- ansible-lint.
      --
      -- `{ name, version = ... }`, not `"name@version"`. This plugin passes a
      -- string entry to the registry as a package name and nothing splits it,
      -- so `"yamllint@1.38.0"` raised `Cannot find package` and nothing was
      -- ever installed — measured during the first real end-to-end install,
      -- and invisible until then because the tools were already on the machine
      -- that wrote the pins. Upstream's own README documents the table form.
      -- mason-lspconfig, which pins the servers below, is a different plugin
      -- and does parse `name@version`.
      local pins = {
        -- Runs as a language server, so plugins/lint.lua must not register it
        -- with nvim-lint as well.
        { "tflint", version = "v0.64.0" },
        -- nvim-lint linters (see plugins/lint.lua)
        { "ansible-lint", version = "26.6.0" },
        { "yamllint", version = "1.38.0" },
        { "hadolint", version = "v2.15.1" },
        { "actionlint", version = "v1.7.12" },
        -- conform formatters (see plugins/formatting.lua)
        { "stylua", version = "v2.5.2" },
        { "shfmt", version = "v3.13.1" },
        { "jq", version = "jq-1.7" },
      }

      local wanted = require("chroma.components").contributions("mason", require("chroma.state").enabled_ids())
      local keep = {}
      for _, pin in ipairs(pins) do
        if vim.tbl_contains(wanted, pin[1]) then
          table.insert(keep, pin)
        end
      end

      return { ensure_installed = keep, run_on_start = true }
    end,
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
    enabled = function()
      return require("chroma.state").contributes("plugins", "vim-helm")
    end,
    -- Not lazy. Its whole job is detection, and detection cannot be triggered by
    -- the filetype it is there to decide. Loading it on `ft` meant a chart file
    -- opened as the first file of a session never loaded it, so nothing detected
    -- helm and nothing loaded it — a cycle. It ships one ftdetect and one syntax
    -- file, so eager loading costs nothing worth measuring.
    lazy = false,
    init = function()
      -- Upstream hooks `FileType yaml,text,gotmpl`, which assumes Neovim names
      -- the last of those. Measured: it does not — `vim.filetype.match` answers
      -- nil for `values.gotmpl` — so a helmfile values template was the one class
      -- its detection could never see. Naming it is enough; the plugin decides
      -- from there whether it is Helm's.
      vim.filetype.add({ extension = { gotmpl = "gotmpl" } })
    end,
  },

  {
    "mason-org/mason-lspconfig.nvim",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = {
      { "mason-org/mason.nvim", opts = {} },
      "neovim/nvim-lspconfig",
    },
    opts = function()
      -- nvim-lspconfig config names; the version after `@` is the Mason package's.
      local pins = {
        "terraformls@v0.39.0",
        "helm_ls@v0.5.4",
        "dockerls@0.15.0",
        "docker_compose_language_service@1.0.0",
        "yamlls@1.24.0",
        "ansiblels@26.6.0",
        "bashls@5.6.0",
        "jsonls@4.10.0",
        "lua_ls@3.18.2",
      }

      -- An allow-list, not `true`: that would enable every server Mason has ever
      -- installed, including stylua, which would then compete with conform. The
      -- list is now the enabled components' own, so a selection without
      -- Kubernetes never installs helm_ls and never enables it.
      local wanted = require("chroma.components").contributions("servers", require("chroma.state").enabled_ids())

      local install = {}
      for _, pin in ipairs(pins) do
        if vim.tbl_contains(wanted, pin:match("^([^@]+)")) then
          table.insert(install, pin)
        end
      end

      return { ensure_installed = install, automatic_enable = wanted }
    end,
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
