-- Formatting layer.
--
-- Formatter names verified against conform's own doc/conform.txt before use.
--
-- One deliberate design point: `lsp_format = "fallback"`. Where no dedicated
-- formatter is configured, conform hands the job to the language server.
--
-- YAML, helm and dockerfile rely on this and it was verified to work: yamlls
-- ships with formatting enabled and reformats a manifest correctly. Installing
-- an opinionated YAML formatter on top would only produce noisy diffs in
-- Kubernetes manifests.
--
-- What the fallback does NOT do is rescue a missing binary. terraform_fmt
-- needs the `terraform` CLI, and terraform-ls is not a substitute — it shells
-- out to `terraform fmt` itself and answers with
--
--   "Terraform (CLI) is required. Please install Terraform or make it
--    available in $PATH"
--
-- So Terraform files stay unformatted until the terraform binary is on PATH.
-- That is a machine prerequisite, not something configuration can paper over.

return {
  {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    cmd = { "ConformInfo" },
    opts = {
      formatters_by_ft = {
        lua = { "stylua" },

        -- Terraform's own canonical formatter; falls back to terraform-ls
        -- when the terraform binary is absent.
        terraform = { "terraform_fmt" },
        ["terraform-vars"] = { "terraform_fmt" },

        -- In this stack a bare .hcl file is almost always Terragrunt, and
        -- terragrunt is installed locally.
        hcl = { "terragrunt_hclfmt" },

        sh = { "shfmt" },
        bash = { "shfmt" },

        json = { "jq" },

        -- yaml, helm and dockerfile are intentionally absent: they are served
        -- by their language servers through the fallback above.
      },

      default_format_opts = {
        lsp_format = "fallback",
      },

      format_on_save = function(bufnr)
        -- Respects :FormatDisable / :FormatEnable, defined in
        -- lua/config/commands.lua.
        if vim.g.disable_autoformat or vim.b[bufnr].disable_autoformat then
          return
        end
        return { timeout_ms = 1000, lsp_format = "fallback" }
      end,
    },
    keys = {
      {
        "<leader>xf",
        function()
          require("conform").format({ async = true, lsp_format = "fallback" })
        end,
        mode = { "n", "v" },
        desc = "Format buffer or selection",
      },
      {
        "<leader>xF",
        function()
          if vim.g.disable_autoformat then
            vim.cmd("FormatEnable")
          else
            vim.cmd("FormatDisable")
          end
        end,
        desc = "Toggle format on save",
      },
      { "<leader>xi", "<cmd>ConformInfo<cr>", desc = "Formatter info" },
    },
  },
}
