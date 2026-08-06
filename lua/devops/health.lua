-- Health check for DevOps nVim: `:checkhealth devops`.
--
-- This exists because most of this configuration is a front-end for external
-- programs. When ripgrep is missing, the failure surfaces as an unhelpful
-- error from inside a picker; when the terraform CLI is missing, formatting
-- silently does nothing. Guarding every call site would scatter the same
-- three lines across a dozen files, so the question is answered in one place
-- instead, in the form Neovim already has a command for.
--
-- Nothing here changes behaviour. It reports.

local M = {}

local health = vim.health

---@class devops.Tool
---@field cmd string          executable to look for
---@field what string         what stops working without it
---@field advice? string      how to get it

---@param tools devops.Tool[]
---@param severity fun(msg: string, advice?: string|string[])
local function check_all(tools, severity)
  for _, tool in ipairs(tools) do
    if vim.fn.executable(tool.cmd) == 1 then
      -- Version output is noisy and inconsistent between tools, so only the
      -- fact of presence is reported.
      health.ok(("`%s` found — %s"):format(tool.cmd, tool.what))
    else
      severity(("`%s` not found — %s"):format(tool.cmd, tool.what), tool.advice)
    end
  end
end

local function check_neovim()
  health.start("Neovim")

  if vim.fn.has("nvim-0.12") == 1 then
    health.ok(("Neovim %s"):format(vim.version()))
  else
    health.error(
      "Neovim 0.12 or newer is required",
      "This config uses the native LSP API (vim.lsp.config/enable) and the "
        .. "rewritten nvim-treesitter, neither of which exists earlier."
    )
  end
end

local function check_core()
  health.start("Core tooling")

  check_all({
    { cmd = "git", what = "plugin management", advice = "git >= 2.19 is required for partial clones" },
    { cmd = "curl", what = "downloading parsers and prebuilt binaries" },
    { cmd = "tar", what = "unpacking treesitter grammars" },
    {
      cmd = "tree-sitter",
      what = "compiling treesitter parsers",
      advice = "install tree-sitter-cli >= 0.26.1 from your package manager, not from npm",
    },
  }, health.error)

  if vim.fn.executable("cc") == 1 or vim.fn.executable("gcc") == 1 or vim.fn.executable("clang") == 1 then
    health.ok("A C compiler is available — treesitter parsers can be built")
  else
    health.error("No C compiler found — treesitter parsers cannot be built", "install gcc or clang")
  end
end

local function check_pickers()
  health.start("Search and navigation")

  check_all({
    { cmd = "fzf", what = "every picker", advice = "fzf > 0.36 is required" },
    { cmd = "rg", what = "grep pickers (<leader>fg, <leader>fw)" },
    { cmd = "fd", what = "project detection in project.nvim" },
    { cmd = "bat", what = "file previews in the fzf-native profile" },
  }, health.warn)

  check_all({
    { cmd = "yazi", what = "the file manager (<leader>fy)" },
    { cmd = "lazygit", what = "the git UI (<leader>gg)" },
  }, health.warn)
end

local function check_devops()
  health.start("DevOps tooling")

  -- These are all optional in the sense that the editor still works without
  -- them; they are only needed for the workflow they belong to.
  check_all({
    { cmd = "kubectl", what = "the Kubernetes views (<leader>kk)" },
    { cmd = "helm", what = "the Helm view inside kubectl.nvim" },
    { cmd = "ansible", what = "running playbooks (<leader>ar)" },
    { cmd = "terragrunt", what = "formatting terragrunt.hcl files" },
  }, health.warn)

  -- Terraform is called out separately because its absence has a specific,
  -- easily misdiagnosed symptom.
  if vim.fn.executable("terraform") == 1 or vim.fn.executable("tofu") == 1 then
    health.ok("`terraform` or `tofu` found — .tf files can be formatted")
  else
    health.warn(
      "Neither `terraform` nor `tofu` found — .tf files will not be formatted",
      "terraform-ls is not a substitute: it shells out to `terraform fmt` itself "
        .. 'and reports "Terraform (CLI) is required". See :help devops-nvim-formatting-tf'
    )
  end

  if vim.fn.executable("kubectl") == 1 then
    local kubeconfig = vim.env.KUBECONFIG or (vim.env.HOME .. "/.kube/config")
    if vim.uv.fs_stat(kubeconfig) then
      health.ok(("kubeconfig found at %s"):format(kubeconfig))
    else
      health.warn(
        ("No kubeconfig at %s — the cluster views will have nothing to show"):format(kubeconfig),
        "set KUBECONFIG or create ~/.kube/config"
      )
    end
  end
end

local function check_terminal()
  health.start("Terminal integration")

  if vim.env.ZELLIJ then
    health.ok("Running inside Zellij")
    health.info(
      "Zellij captures Ctrl-g/q/h/o/b/s/t/p/n and most Alt combinations before "
        .. "Neovim sees them. Plugin defaults landing on those keys are remapped "
        .. "by this config; Neovim's own Ctrl-h and Ctrl-o cannot be recovered. "
        .. "See :help devops-nvim-zellij"
    )
  else
    health.info("Not running inside Zellij — the remaps described in :help devops-nvim-zellij are harmless here")
  end

  if vim.env.KITTY_WINDOW_ID then
    health.ok("Running inside Kitty — catppuccin offsets its blue channel to avoid Kitty's transparency quirk")
  end
end

function M.check()
  check_neovim()
  check_core()
  check_pickers()
  check_devops()
  check_terminal()
end

return M
