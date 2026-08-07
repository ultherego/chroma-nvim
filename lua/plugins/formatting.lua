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
-- So Terraform files stay unformatted until either the terraform or the tofu
-- binary is on PATH. That is a machine prerequisite, not something
-- configuration can paper over — see terraform_formatter below for which of
-- the two gets used.

--- Whichever of the two CLIs is actually installed.
---
--- terraform first, always, so nothing changes for anyone who has it. tofu_fmt
--- is the fallback rather than an equal: OpenTofu is a fork, and picking it for
--- someone who has both would be this configuration making a decision that is
--- not its to make.
---
--- Written as a function because the answer is a property of the machine, not
--- of the configuration, and can change while Neovim is running — a `tofu`
--- installed mid-session is picked up on the next format rather than at the
--- next restart. conform documents both the function form of formatters_by_ft
--- and get_formatter_info().available, which is what makes this a supported
--- shape rather than a trick.
---
--- Returning an empty list is the honest answer when neither is present:
--- conform then falls through to the language server, and terraform-ls does not
--- format either, so the file stays unformatted. That is a machine
--- prerequisite, and `:checkhealth devops` reports it.
---@param bufnr integer
---@return string[]
local function terraform_formatter(bufnr)
  local conform = require("conform")

  for _, formatter in ipairs({ "terraform_fmt", "tofu_fmt" }) do
    local info = conform.get_formatter_info(formatter, bufnr)
    if info.available then
      return { formatter }
    end
  end

  return {}
end

return {
  {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    cmd = { "ConformInfo" },
    opts = {
      formatters_by_ft = {
        lua = { "stylua" },

        -- terraform_fmt when the terraform CLI is there, tofu_fmt when only
        -- OpenTofu is. `:checkhealth devops` has always accepted either as
        -- meaning ".tf files can be formatted"; until this it was only true of
        -- the first.
        terraform = terraform_formatter,
        ["terraform-vars"] = terraform_formatter,

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

        -- Large files are skipped deliberately, and audibly.
        --
        -- format_on_save is synchronous and bounded by timeout_ms. Past that
        -- conform abandons the formatting — without a message. Measured: a
        -- 900 KB YAML took just over a second through yamlls and saved
        -- completely unformatted, with nothing to indicate it. Believing a file
        -- was formatted when it was not is worse than knowing it was not.
        --
        -- The threshold is set below where that starts happening rather than
        -- guessed. <leader>xf still formats these: it runs async and is not
        -- bound by the timeout at all.
        local max_bytes = 512 * 1024
        local stat = vim.uv.fs_stat(vim.api.nvim_buf_get_name(bufnr))
        if stat and stat.size > max_bytes then
          vim.notify(
            ("Not formatting on save: %.1f MB exceeds the synchronous budget. Use <leader>xf."):format(
              stat.size / 1024 / 1024
            ),
            vim.log.levels.WARN
          )
          return
        end

        -- Raised from the 1000 ms default to leave headroom for a slow
        -- formatter on a file that is still small enough to be worth waiting
        -- for.
        return { timeout_ms = 3000, lsp_format = "fallback" }
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
          -- Reads the global flag only, because that is the only one it sets.
          --
          -- It used to consult the buffer-local flag first, on the reasoning
          -- that this reflects the state actually in effect here. But the two
          -- commands it runs are global, so with formatting disabled in this
          -- buffer and nothing set globally, the toggle ran :FormatEnable —
          -- clearing a global flag that was already clear, while the local one
          -- stayed set. Formatting remained off in the buffer and the key
          -- appeared to do nothing at all.
          --
          -- Each toggle now owns exactly one flag: this one the global,
          -- <leader>xb the buffer's.
          vim.cmd(vim.g.disable_autoformat and "FormatEnable" or "FormatDisable")
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
