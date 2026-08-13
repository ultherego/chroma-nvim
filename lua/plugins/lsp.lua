-- LSP layer, on the native 0.12 API: nvim-lspconfig only ships lsp/<name>.lua
-- and Neovim discovers them. Per-server overrides go in after/lsp/.

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
          -- `_value` is the receipt's internal table, not a promised interface,
          -- so a Mason release reshaping it prints `?` rather than breaking.
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

  -- One provisioner for everything Mason installs. mason-lspconfig's own
  -- `ensure_installed` deliberately does nothing when Neovim is headless —
  -- measured: after `chroma install` the servers were simply absent — which is
  -- exactly where the installer runs.
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    event = "VeryLazy",
    dependencies = {
      "mason-org/mason.nvim",
      -- Looked up to translate `bashls` into `bash-language-server`.
      "mason-org/mason-lspconfig.nvim",
    },
    opts = function()
      -- `{ name, version = ... }`, never `"name@version"`: a string entry goes
      -- to the registry as a package name and nothing splits it, which raised
      -- `Cannot find package` and installed nothing. One table rather than two,
      -- because `tflint` is both a server and a Mason package.
      local pins = {
        terraformls = "v0.39.0",
        helm_ls = "v0.5.4",
        dockerls = "0.15.0",
        docker_compose_language_service = "1.0.0",
        yamlls = "1.24.0",
        ansiblels = "26.6.0",
        bashls = "5.6.0",
        jsonls = "4.10.0",
        lua_ls = "3.18.2",
        -- tflint runs as a language server, which is why plugins/lint.lua must
        -- not register it with nvim-lint as well.
        tflint = "v0.64.0",
        -- nvim-lint linters (see plugins/lint.lua)
        ["ansible-lint"] = "26.6.0",
        yamllint = "1.38.0",
        hadolint = "v2.15.1",
        actionlint = "v1.7.12",
        -- conform formatters (see plugins/formatting.lua)
        stylua = "v2.5.2",
        shfmt = "v3.13.1",
        jq = "jq-1.7",
      }

      local components = require("chroma.components")
      local enabled = require("chroma.state").enabled_ids()

      local ensure, seen = {}, {}
      for _, kind in ipairs({ "servers", "mason" }) do
        for _, name in ipairs(components.contributions(kind, enabled)) do
          if not seen[name] and pins[name] then
            seen[name] = true
            table.insert(ensure, { name, version = pins[name] })
          end
        end
      end

      return { ensure_installed = ensure, run_on_start = true }
    end,
  },

  -- Consumed by after/lsp/yamlls.lua and after/lsp/jsonls.lua.
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
    -- Not lazy: detection cannot be triggered by the filetype it decides, so
    -- loading on `ft` was a cycle. One ftdetect and one syntax file.
    lazy = false,
    init = function()
      -- Upstream hooks `FileType yaml,text,gotmpl`, and measured, Neovim does
      -- not name the last of those — `vim.filetype.match` answers nil for
      -- `values.gotmpl`. Naming it is enough; the plugin decides from there.
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
      -- An allow-list, not `true`: that would enable every server Mason ever
      -- installed, stylua included, which would then compete with conform.
      local wanted = require("chroma.components").contributions("servers", require("chroma.state").enabled_ids())

      -- Empty on purpose; provisioning belongs to mason-tool-installer above.
      -- What is left here is enabling the servers that are installed.
      return { ensure_installed = {}, automatic_enable = wanted }
    end,
    config = function(_, opts)
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
