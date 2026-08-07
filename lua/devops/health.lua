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
    -- Mason's own requirements, which this list did not cover. Without them a
    -- server installs right up to the point of unpacking and fails there,
    -- reported as a Mason error about an archive rather than as a missing
    -- tool. Taken from mason.nvim's Requirements section, which lists git,
    -- curl or wget, unzip, GNU tar and gzip for Unix.
    { cmd = "unzip", what = "unpacking Mason packages" },
    { cmd = "gzip", what = "unpacking Mason packages" },
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

local function check_lockfile()
  health.start("Plugin lockfile")

  local path = vim.fs.joinpath(vim.fn.stdpath("config"), "lazy-lock.json")
  local contents = vim.uv.fs_stat(path) and table.concat(vim.fn.readfile(path), "\n") or nil

  if not contents then
    health.warn(
      ("No lazy-lock.json at %s"):format(path),
      "plugin versions are not pinned; run :Lazy sync and commit the result"
    )
    return
  end

  -- A corrupted lockfile does not stop Neovim starting — lazy.nvim falls back
  -- to whatever is installed and says nothing. What is lost is silent: the
  -- pinned versions, and any chance of :Lazy restore working. Verified that a
  -- broken file still boots all plugins with no message.
  local ok, decoded = pcall(vim.json.decode, contents)
  if not ok or type(decoded) ~= "table" then
    health.error(
      "lazy-lock.json is not valid JSON",
      "plugin versions are no longer pinned and :Lazy restore will not work. "
        .. "Restore it from git, or run :Lazy sync to regenerate it."
    )
    return
  end

  health.ok(("lazy-lock.json pins %d plugins"):format(vim.tbl_count(decoded)))
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
    { cmd = "aws", what = "the AWS profile and region switcher (<leader>Ap)" },
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

  -- Where :TerraformPlan will put the plan it writes. A plan quotes variable
  -- values, so a runtime directory that is not private is a refusal, not a
  -- warning at write time — reported here so it is known before a plan is run.
  local plan_dir, plan_err = require("terraform.runtime").secure_dir("terraform.nvim")
  if plan_dir then
    health.ok(("Plan files will be written to %s (tmpfs, 0700)"):format(plan_dir))
  else
    health.warn(plan_err, ":TerraformPlan will refuse rather than write a plan to persistent storage")
  end

  if vim.fn.executable("kubectl") == 1 then
    -- KUBECONFIG is a path LIST, not a path. kubectl merges every entry, and
    -- splitting on the platform separator is the difference between reporting
    -- a perfectly good multi-cluster setup as missing and reading it correctly.
    local separator = vim.fn.has("win32") == 1 and ";" or ":"
    local entries = vim.env.KUBECONFIG and vim.split(vim.env.KUBECONFIG, separator, { trimempty = true })
      or { vim.fs.joinpath(vim.env.HOME, ".kube", "config") }

    local present, missing = {}, {}
    for _, entry in ipairs(entries) do
      local path = vim.fs.normalize(entry)
      table.insert(vim.uv.fs_stat(path) and present or missing, path)
    end

    if #present > 0 then
      health.ok(("kubeconfig: %s"):format(table.concat(present, ", ")))
      if #missing > 0 then
        health.warn(
          ("KUBECONFIG also lists files that do not exist: %s"):format(table.concat(missing, ", ")),
          "kubectl ignores them, but the list is probably not what you intended"
        )
      end
    else
      health.warn(
        ("No kubeconfig found (looked at %s) — the cluster views will have nothing to show"):format(
          table.concat(missing, ", ")
        ),
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
  check_lockfile()
  check_pickers()
  check_devops()
  check_terminal()
end

return M
