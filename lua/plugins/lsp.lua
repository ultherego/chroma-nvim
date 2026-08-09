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

  -- Everything Mason installs: language servers, linters and formatters.
  --
  -- One provisioner, and that is the change worth explaining. mason-lspconfig
  -- also has an `ensure_installed`, and it deliberately does nothing when
  -- Neovim is headless — measured: after `chroma install` the servers were
  -- simply absent, and the first interactive session started fetching them
  -- while the user watched. An installer whose result finishes installing
  -- itself the first time somebody opens it has not finished installing.
  --
  -- So mason-tool-installer provisions all of it, in headless and out, and
  -- mason-lspconfig keeps the job it is best at: translating names and enabling
  -- what is installed.
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    event = "VeryLazy",
    dependencies = {
      "mason-org/mason.nvim",
      -- Not decoration: this plugin looks mason-lspconfig up to translate
      -- `bashls` into `bash-language-server`, and the pins below are written in
      -- the names the component contract uses.
      "mason-org/mason-lspconfig.nvim",
    },
    opts = function()
      -- Pinned by hand; which of them are wanted comes from the enabled
      -- components, so a machine that never selected Ansible fetches neither
      -- ansiblels nor ansible-lint.
      --
      -- `{ name, version = ... }`, never `"name@version"`. This plugin passes a
      -- string entry to the registry as a package name and nothing splits it,
      -- so the string form raised `Cannot find package` and installed nothing.
      --
      -- One table rather than two, because `tflint` is in it twice over: the
      -- contract lists it as a server *and* as a Mason package, and two tables
      -- would be two places to keep one version.
      local pins = {
        -- Language servers, by the names nvim-lspconfig and the contract use.
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
      -- An allow-list, not `true`: that would enable every server Mason has ever
      -- installed, including stylua, which would then compete with conform. The
      -- list is the enabled components' own, so a selection without Kubernetes
      -- never installs helm_ls and never enables it.
      local wanted = require("chroma.components").contributions("servers", require("chroma.state").enabled_ids())

      -- Empty on purpose. This plugin's own `ensure_installed` does nothing in
      -- a headless Neovim, which is exactly where the installer runs, so
      -- provisioning belongs to mason-tool-installer above. What is left here
      -- is what this plugin is for: enabling the servers that are installed.
      return { ensure_installed = {}, automatic_enable = wanted }
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
