-- Formatting layer. `lsp_format = "fallback"` hands anything without a dedicated
-- formatter to the language server: yamlls and dockerls format, helm_ls does not.
-- The fallback cannot rescue a missing binary — terraform-ls shells out to
-- `terraform fmt` itself.

--- Whichever of the two CLIs is installed, terraform first so nothing changes for
--- anyone who has it. A function, because the answer belongs to the machine and can
--- change while Neovim is running.
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

--- `hcl` is not a synonym for Terragrunt: Packer, Nomad, Vault and Consul share
--- the filetype, so only files terragrunt owns get its formatter.
---@param bufnr integer
---@return string[]
local function terragrunt_formatter(bufnr)
  local name = vim.fs.basename(vim.api.nvim_buf_get_name(bufnr))
  if name == "terragrunt.hcl" or name == "terragrunt.stack.hcl" then
    return { "terragrunt_hclfmt" }
  end
  return {}
end

--- Which filetypes get a formatter, and which formatter, from the enabled
--- components rather than from this file.
---
--- Formatting was the last thing a selection did not decide: a configuration
--- with `"selected": []` still had `terraform fmt` running on every .tf write,
--- which is Terraform support by any honest reading of the phrase. `needs` is
--- satisfied by any one of the names, because terraform and tofu are two ways
--- to have the same component.
---@return table<string, string[]|fun(bufnr: integer): string[]>
local function formatters_by_ft()
  local enabled = require("chroma.state").enabled_ids()

  local contributed = {}
  for _, name in ipairs(require("chroma.components").contributions("formatters", enabled)) do
    contributed[name] = true
  end

  -- yaml, helm and dockerfile are absent on purpose: their servers do it.
  local layers = {
    { filetypes = { "lua" }, needs = { "stylua" }, use = { "stylua" } },
    { filetypes = { "sh", "bash" }, needs = { "shfmt" }, use = { "shfmt" } },
    { filetypes = { "json" }, needs = { "jq" }, use = { "jq" } },
    {
      filetypes = { "terraform", "terraform-vars" },
      needs = { "terraform_fmt", "tofu_fmt" },
      use = terraform_formatter,
    },
    { filetypes = { "hcl" }, needs = { "terragrunt_hclfmt" }, use = terragrunt_formatter },
  }

  local by_ft = {}
  for _, layer in ipairs(layers) do
    local wanted = false
    for _, name in ipairs(layer.needs) do
      wanted = wanted or contributed[name] == true
    end
    if wanted then
      for _, filetype in ipairs(layer.filetypes) do
        by_ft[filetype] = layer.use
      end
    end
  end

  return by_ft
end

return {
  {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    cmd = { "ConformInfo" },
    opts = function()
      return {
        formatters_by_ft = formatters_by_ft(),

        default_format_opts = {
          lsp_format = "fallback",
        },

        format_on_save = function(bufnr)
          -- Set by :FormatDisable / :FormatEnable in lua/config/commands.lua.
          if vim.g.disable_autoformat or vim.b[bufnr].disable_autoformat then
            return
          end

          -- A decrypted vault holds plaintext secrets and formatters are
          -- subprocesses fed the buffer. Reformatting one would also rewrite the
          -- plaintext before this plugin's own writer re-encrypts it.
          if vim.b[bufnr].ansible_vault_plain then
            return
          end

          -- Past timeout_ms conform gives up silently, so large files are skipped
          -- audibly instead. Measured: 900 KB of YAML saved unformatted, no message.
          -- <leader>xf still formats them, asynchronously.
          --
          -- The buffer is what gets formatted, and this runs before the write, so
          -- the file on disk is the previous version — or nothing at all, for a
          -- buffer that has never been saved. get_offset past the last line is the
          -- buffer's own byte count, one byte per line ending.
          local max_bytes = 512 * 1024
          local bytes = vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr))
          if bytes > max_bytes then
            vim.notify(
              ("Not formatting on save: %.1f MB exceeds the synchronous budget. Use <leader>xf."):format(
                bytes / 1024 / 1024
              ),
              vim.log.levels.WARN
            )
            return
          end

          -- Raised from 1000 ms for slow formatters on files worth waiting for.
          return { timeout_ms = 3000, lsp_format = "fallback" }
        end,
      }
    end,
    keys = {
      {
        "<leader>xf",
        function()
          -- The same rule as format-on-save: a formatter is a subprocess fed the
          -- buffer, and a decrypted vault is not something to hand one. Said out
          -- loud here, because unlike the save path this was asked for.
          if vim.b[vim.api.nvim_get_current_buf()].ansible_vault_plain then
            vim.notify(
              "Not formatting: this buffer holds a decrypted vault, and formatters run as subprocesses.",
              vim.log.levels.WARN
            )
            return
          end
          require("conform").format({ async = true, lsp_format = "fallback" })
        end,
        mode = { "n", "v" },
        desc = "Format buffer or selection",
      },
      {
        "<leader>xF",
        function()
          -- The global flag only, because that is the only one this sets.
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
