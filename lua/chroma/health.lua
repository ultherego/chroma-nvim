-- Health check for Chroma Neovim: `:checkhealth chroma`.

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
    -- Mason unpacks its packages with these, and fails at unpacking without them.
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

  -- A corrupted lockfile does not stop Neovim starting; it silently costs the
  -- pinned versions and any chance of :Lazy restore.
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
        .. 'and reports "Terraform (CLI) is required". See :help chroma-nvim-formatting-tf'
    )
  end

  -- A plan quotes variable values, so a runtime directory that is not private is
  -- a refusal rather than a warning.
  local plan_dir, plan_err = require("chroma-terraform.runtime").secure_dir("chroma-terraform.nvim")
  if plan_dir then
    health.ok(("Plan files will be written to %s (private, 0700)"):format(plan_dir))
  else
    health.warn(plan_err, ":TerraformPlan will refuse rather than write a plan outside it")
  end

  if vim.fn.executable("kubectl") == 1 then
    -- KUBECONFIG is a path LIST, not a path: kubectl merges every entry.
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
        .. "See :help chroma-nvim-zellij"
    )
  else
    health.info("Not running inside Zellij — the remaps described in :help chroma-nvim-zellij are harmless here")
  end

  if vim.env.KITTY_WINDOW_ID then
    health.ok("Running inside Kitty — catppuccin offsets its blue channel to avoid Kitty's transparency quirk")
  end
end

--- One line per component: whether the machine can actually run it. The checks
--- above ask "is this tool here"; this asks "is this feature usable", which is
--- the question the installer will ask too, from the same files.
local function check_components()
  health.start("Components")

  local contract = require("chroma.components")
  -- From the files, not from the session's copy: this repository is also a
  -- configuration directory, so a health check run after editing a component
  -- should report the component as it now is.
  contract.forget()
  require("chroma.state").forget()

  local components, problems = contract.load()

  for _, problem in ipairs(problems) do
    health.error(("component contract: %s"):format(problem))
  end

  -- Which of the three the editor is in. Safe mode is the one worth finding
  -- here: its error is printed once at startup, and startup is exactly when
  -- nobody is reading messages.
  local state = require("chroma.state")
  local enabled, mode = state.enabled_ids()
  if mode == state.SAFE and (#problems > 0 or components[state.CORE] == nil) then
    -- Safe mode has two causes and they need different advice. Naming the
    -- selection here when the contract is what broke would send somebody to
    -- edit a file that is perfectly fine.
    health.error(
      ("The component contract could not be read in full, so nothing optional is running (%s)"):format(
        #enabled > 0 and table.concat(enabled, ", ") or "not even core"
      ),
      "fix the component files reported above; the selection was not the problem"
    )
  elseif mode == state.SAFE then
    health.error(
      ("%s exists but could not be read, so only core is running"):format(state.path()),
      "fix the file, or delete it to go back to running every component"
    )
  elseif mode == state.LEGACY then
    health.ok(("No selection at %s — every component is running"):format(state.path()))
  else
    health.ok(("Selection at %s — running %s"):format(state.path(), table.concat(enabled, ", ")))
  end

  for _, problem in ipairs(contract.resolve_problems(components)) do
    health.error(("component contract: %s"):format(problem))
  end

  local ids = vim.tbl_keys(components)
  table.sort(ids)

  -- Said once, rather than implied nine times: this checks presence. Whether a
  -- tool is new enough is `chroma doctor`, which owns the knowledge of how to
  -- ask each executable what version it is. A second copy of that here would be
  -- a second thing to keep in step with reality.
  local constrained = false

  for _, id in ipairs(ids) do
    local component = components[id]
    local missing = {}

    for _, tool in ipairs(contract.tools(component)) do
      if tool.version then
        constrained = true
      end
      if tool.level == "required" and not contract.satisfied(tool) then
        table.insert(missing, table.concat(tool.names, " or "))
      end
    end

    if #missing == 0 then
      health.ok(("%s — ready"):format(component.name))
    else
      health.warn(
        ("%s — missing %s"):format(component.name, table.concat(missing, ", ")),
        ("nothing else is affected; the rest of the editor works without %s"):format(component.name)
      )
    end
  end

  if constrained then
    health.info("`ready` here means present. `chroma doctor` also checks that versions meet the contract.")
  end
end

function M.check()
  check_neovim()
  check_core()
  check_lockfile()
  check_pickers()
  check_devops()
  check_components()
  check_terminal()
end

return M
