-- Formatting layer.
--
-- Formatter names verified against conform's own doc/conform.txt before use.
--
-- One deliberate design point: `lsp_format = "fallback"`. Where no dedicated
-- formatter is configured, conform hands the job to the language server.
--
-- Verified by inspecting documentFormattingProvider on the attached client:
--
--   yamlls    true   reformats a manifest correctly
--   dockerls  true
--   helm_ls   nil    does NOT format
--
-- So YAML and Dockerfiles are genuinely covered by their servers, and Helm
-- templates are simply not formatted by anything. An earlier version of this
-- comment claimed helm was covered; it was not, and Go templates interleaved
-- with YAML are not something a YAML formatter could safely handle anyway.
--
-- Installing an opinionated YAML formatter on top of yamlls would only produce
-- noisy diffs in Kubernetes manifests.
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

        -- `hcl` is not a synonym for Terragrunt: Packer, Nomad, Vault and
        -- Consul all use the same filetype, and running terragrunt's
        -- formatter over their files is not something to do by default.
        -- Restricted to files terragrunt actually owns; everything else falls
        -- through to the language server, or to nothing.
        hcl = function(bufnr)
          local name = vim.fs.basename(vim.api.nvim_buf_get_name(bufnr))
          if name == "terragrunt.hcl" or name == "terragrunt.stack.hcl" then
            return { "terragrunt_hclfmt" }
          end
          return {}
        end,

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
          -- Reflects the state that actually applies to this buffer, which is
          -- the local flag when one is set and the global one otherwise.
          local off = vim.b.disable_autoformat
          if off == nil then
            off = vim.g.disable_autoformat
          end
          vim.cmd(off and "FormatEnable" or "FormatDisable")
        end,
        desc = "Toggle format on save (global)",
      },
      {
        "<leader>xb",
        function()
          vim.cmd(vim.b.disable_autoformat and "FormatEnable!" or "FormatDisable!")
        end,
        desc = "Toggle format on save (this buffer)",
      },
      { "<leader>xi", "<cmd>ConformInfo<cr>", desc = "Formatter info" },
    },
  },
}
