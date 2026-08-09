-- What a selection actually switches off.
--
-- These are negative on purpose. "Terraform selected, terraformls present" is
-- the easy half and would pass with no gating at all; the half that matters is
-- that nothing else came with it.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local state = require("chroma.state")

local T = new_set({
  hooks = {
    pre_case = function()
      state.forget()
    end,
    post_case = function()
      state.forget()
      -- The specs are read fresh each time: they ask the state when evaluated.
      for _, module in ipairs({ "plugins.lsp", "plugins.lint", "plugins.devops", "plugins.ui", "config.parsers" }) do
        package.loaded[module] = nil
      end
    end,
  },
})

---Runs `fn` with a selection in place, or with none at all.
---@param selected string[]|nil nil means no file, which is every component
---@param fn function
local function with(selected, fn)
  local home = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(home, "chroma"), "p")
  if selected then
    vim.fn.writefile(
      { vim.json.encode({ schema = 1, selected = selected }) },
      vim.fs.joinpath(home, "chroma", "components.json")
    )
  end

  local saved = vim.env.XDG_CONFIG_HOME
  vim.env.XDG_CONFIG_HOME = home
  state.forget()
  for _, module in ipairs({ "plugins.lsp", "plugins.lint", "plugins.devops", "plugins.ui", "config.parsers" }) do
    package.loaded[module] = nil
  end

  local ok, err = pcall(fn)

  vim.env.XDG_CONFIG_HOME = saved
  state.forget()
  vim.fn.delete(home, "rf")
  assert(ok, err)
end

---The options a spec produces, whether it declares them as a table or a function.
---@param module string
---@param name string
---@return table
local function opts_of(module, name)
  for _, entry in ipairs(require(module)) do
    if entry[1] == name then
      if type(entry.opts) == "function" then
        return entry.opts()
      end
      return entry.opts
    end
  end
  error(("no %s in %s"):format(name, module))
end

---Runs the lint spec's own config() against a stubbed nvim-lint, and returns
---what it registered. The contract is what config() reads, but what it writes
---is `linters_by_ft`, and that is the thing a buffer is linted from.
---@return table<string, string[]>
local function registered_linters()
  local saved = package.loaded.lint
  local stub = { linters = {}, try_lint = function() end }
  package.loaded.lint = stub

  local ok, err = pcall(function()
    for _, entry in ipairs(require("plugins.lint")) do
      if entry[1] == "mfussenegger/nvim-lint" then
        entry.config()
        return
      end
    end
    error("no nvim-lint spec in plugins.lint")
  end)

  package.loaded.lint = saved
  assert(ok, err)

  return stub.linters_by_ft
end

---The linters the lint layer would actually run for `path`, by driving the
---`:Lint` command it installs. Reaches the choices made inside config()'s
---closures, which `linters_by_ft` does not show.
---@param path string
---@param filetype string
---@return string[]
local function linters_run_for(path, filetype)
  local saved = package.loaded.lint
  local ran = {}
  package.loaded.lint = {
    linters = {},
    try_lint = function(names)
      ran = names
    end,
  }

  local ok, err = pcall(function()
    for _, entry in ipairs(require("plugins.lint")) do
      if entry[1] == "mfussenegger/nvim-lint" then
        entry.config()
      end
    end

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, path)
    vim.bo[buf].filetype = filetype
    vim.api.nvim_set_current_buf(buf)
    vim.cmd("Lint")
  end)

  package.loaded.lint = saved
  assert(ok, err)

  return ran
end

---The modules the configuration would set up, without any of them being real.
---@return string[] names, table<string, boolean> setups that actually ran
local function modules_set_up()
  local names = require("chroma.components").contributions("modules", (state.enabled_ids()))

  -- Every module the contract could name, stubbed — not just the ones expected,
  -- or a module that should not have been touched would be required for real
  -- and quietly succeed.
  local every, saved, ran = {}, {}, {}
  for _, component in pairs(require("chroma.components").load()) do
    for _, name in ipairs(component.nvim.modules or {}) do
      table.insert(every, name)
    end
  end

  for _, name in ipairs(every) do
    saved[name] = package.loaded[name]
    package.loaded[name] = {
      setup = function()
        ran[name] = true
      end,
    }
  end

  local ok, err = pcall(require("chroma.modules").setup, { keymaps = true })

  for _, name in ipairs(every) do
    package.loaded[name] = saved[name]
  end
  assert(ok, err)

  return names, ran
end

---The which-key group labels the current selection produces.
---@return string[]
local function whichkey_groups()
  local names = {}
  for _, item in ipairs(opts_of("plugins.ui", "folke/which-key.nvim").spec) do
    table.insert(names, item.group)
  end
  return names
end

---Whether a plugin spec is enabled under the current selection.
---@param module string
---@param name string
---@return boolean
local function spec_enabled(module, name)
  for _, entry in ipairs(require(module)) do
    if entry[1] == name then
      if entry.enabled == nil then
        return true
      end
      -- Not `f() or entry.enabled`: a function returning false falls through the
      -- `and` and the expression hands back the function, which is truthy.
      if type(entry.enabled) == "function" then
        return entry.enabled()
      end
      return entry.enabled
    end
  end
  error(("no %s in %s"):format(name, module))
end

-- ---------------------------------------------------------------------------
-- Terraform alone

T["terraform only"] = new_set()

T["terraform only"]["enables its own servers and no others"] = function()
  with({ "terraform" }, function()
    local servers = opts_of("plugins.lsp", "mason-org/mason-lspconfig.nvim").automatic_enable

    eq(vim.tbl_contains(servers, "terraformls"), true)
    eq(vim.tbl_contains(servers, "tflint"), true)
    -- The half that matters.
    eq(vim.tbl_contains(servers, "ansiblels"), false)
    eq(vim.tbl_contains(servers, "helm_ls"), false)
    eq(vim.tbl_contains(servers, "dockerls"), false)
    eq(vim.tbl_contains(servers, "docker_compose_language_service"), false)
    -- Core's own are still there: it is not optional.
    eq(vim.tbl_contains(servers, "yamlls"), true)
    eq(vim.tbl_contains(servers, "lua_ls"), true)
  end)
end

T["terraform only"]["does not bring the plugins of other components"] = function()
  with({ "terraform" }, function()
    eq(spec_enabled("plugins.devops", "ramilito/kubectl.nvim"), false)
    eq(spec_enabled("plugins.devops", "mfussenegger/nvim-ansible"), false)
    eq(spec_enabled("plugins.lsp", "towolf/vim-helm"), false)
  end)
end

T["terraform only"]["does not register other components' linters"] = function()
  with({ "terraform" }, function()
    local by_ft = registered_linters()

    -- Core's, which is not Terraform's to bring or to take away.
    eq(by_ft.yaml, { "yamllint" })
    -- The half that matters, and it is absence rather than an empty list: a
    -- filetype with no linters must not be registered at all, or nvim-lint has
    -- an entry for it.
    eq(by_ft.dockerfile, nil)
    eq(by_ft["yaml.ansible"], nil)
  end)
end

-- actionlint is chosen inside config() by path rather than by filetype, so it
-- is invisible in linters_by_ft and was gated by a condition nothing checked.
T["terraform only"]["does not lint workflows with actionlint"] = function()
  with({ "terraform" }, function()
    eq(linters_run_for("/tmp/repo/.github/workflows/ci.yml", "yaml"), { "yamllint" })
  end)
end

T["terraform only"]["compiles its parsers and not the rest"] = function()
  with({ "terraform" }, function()
    local parsers = require("config.parsers")

    eq(vim.tbl_contains(parsers, "terraform"), true)
    eq(vim.tbl_contains(parsers, "hcl"), true)
    eq(vim.tbl_contains(parsers, "helm"), false)
    eq(vim.tbl_contains(parsers, "gotmpl"), false)
    eq(vim.tbl_contains(parsers, "dockerfile"), false)
    -- Core's parsers stay: yaml and lua are not Terraform's to bring.
    eq(vim.tbl_contains(parsers, "yaml"), true)
    eq(vim.tbl_contains(parsers, "lua"), true)
  end)
end

T["terraform only"]["sets up its module and not the others"] = function()
  with({ "terraform" }, function()
    local names, ran = modules_set_up()

    eq(names, { "chroma-terraform" })
    -- What was asked for is one thing; what ran is the other, and it is the
    -- one that matters. An earlier version of this case compared the resolver
    -- against itself and would have survived setup() calls with no condition
    -- on them at all.
    eq(ran, { ["chroma-terraform"] = true })
  end)
end

-- Formatting was the last thing a selection did not reach: .tf files were
-- formatted by `terraform fmt` whatever was chosen.
T["terraform only"]["formats its own filetypes and no others"] = function()
  with({ "terraform" }, function()
    local by_ft = opts_of("plugins.formatting", "stevearc/conform.nvim").formatters_by_ft

    eq(type(by_ft.terraform), "function")
    eq(type(by_ft["terraform-vars"]), "function")
    eq(type(by_ft.hcl), "function")
    -- Core's, which every selection keeps.
    eq(by_ft.lua, { "stylua" })
  end)
end

-- The explicit Kubernetes mapping is Chroma's own decision about which paths
-- hold manifests, so it goes when the component does. The SchemaStore
-- catalogue is Core's and stays either way.
T["terraform only"]["maps no kubernetes schema"] = function()
  with({ "terraform" }, function()
    eq(require("chroma.schemas").yaml(), {})
  end)
end

-- A group heading over keys that do not exist reads as a broken feature rather
-- than an unselected one.
T["terraform only"]["labels its own which-key group and no others"] = function()
  with({ "terraform" }, function()
    local groups = whichkey_groups()

    eq(vim.tbl_contains(groups, "Terraform"), true)
    eq(vim.tbl_contains(groups, "Kubernetes"), false)
    eq(vim.tbl_contains(groups, "Ansible"), false)
    eq(vim.tbl_contains(groups, "AWS"), false)
    -- Core's own stay.
    eq(vim.tbl_contains(groups, "Git"), true)
  end)
end

-- ---------------------------------------------------------------------------
-- Other shapes

T["shapes"] = new_set()

-- Helm was deliberately made independent of Kubernetes. This is that decision,
-- checked rather than asserted.
T["shapes"]["helm alone brings no kubectl"] = function()
  with({ "helm" }, function()
    local servers = opts_of("plugins.lsp", "mason-org/mason-lspconfig.nvim").automatic_enable

    eq(vim.tbl_contains(servers, "helm_ls"), true)
    eq(spec_enabled("plugins.lsp", "towolf/vim-helm"), true)
    eq(spec_enabled("plugins.devops", "ramilito/kubectl.nvim"), false)
  end)
end

-- And so was Vault, from Ansible.
T["shapes"]["vault alone brings no ansible"] = function()
  with({ "vault" }, function()
    local servers = opts_of("plugins.lsp", "mason-org/mason-lspconfig.nvim").automatic_enable

    eq(state.is_enabled("vault"), true)
    eq(vim.tbl_contains(servers, "ansiblels"), false)
    eq(spec_enabled("plugins.devops", "mfussenegger/nvim-ansible"), false)
  end)
end

T["shapes"]["core alone brings no devops anything"] = function()
  with({}, function()
    local servers = opts_of("plugins.lsp", "mason-org/mason-lspconfig.nvim").automatic_enable
    local parsers = require("config.parsers")

    for _, server in ipairs({ "terraformls", "tflint", "helm_ls", "ansiblels", "dockerls" }) do
      eq({ server, vim.tbl_contains(servers, server) }, { server, false })
    end
    for _, parser in ipairs({ "terraform", "hcl", "helm", "dockerfile" }) do
      eq({ parser, vim.tbl_contains(parsers, parser) }, { parser, false })
    end

    eq(spec_enabled("plugins.devops", "ramilito/kubectl.nvim"), false)
    eq(spec_enabled("plugins.devops", "mfussenegger/nvim-ansible"), false)
    eq(spec_enabled("plugins.lsp", "towolf/vim-helm"), false)

    -- No module is set up at all, and none is even asked for.
    local names, ran = modules_set_up()
    eq(names, {})
    eq(ran, {})

    -- Nothing DevOps-specific is registered against a filetype.
    local by_ft = opts_of("plugins.formatting", "stevearc/conform.nvim").formatters_by_ft
    eq(by_ft.terraform, nil)
    eq(by_ft["terraform-vars"], nil)
    eq(by_ft.hcl, nil)
    eq(registered_linters().dockerfile, nil)
    eq(require("chroma.schemas").yaml(), {})

    -- Not one DevOps heading in which-key.
    for _, name in ipairs({ "Terraform", "Kubernetes", "Ansible", "AWS" }) do
      eq({ name, vim.tbl_contains(whichkey_groups(), name) }, { name, false })
    end

    -- Still an editor: core's own formatter, server, parser and linter.
    eq(by_ft.lua, { "stylua" })
    eq(vim.tbl_contains(servers, "lua_ls"), true)
    eq(vim.tbl_contains(parsers, "lua"), true)
    eq(registered_linters().yaml, { "yamllint" })
  end)
end

-- The schema mapping follows its component rather than the file extension it
-- happens to apply to.
T["shapes"]["kubernetes brings its schema, and only it brings it"] = function()
  with({ "kubernetes" }, function()
    local mapped = require("chroma.schemas").yaml()

    eq(vim.tbl_count(mapped), 1)
    for url, files in pairs(mapped) do
      eq(url:find("kubernetes%-json%-schema") ~= nil, true)
      eq(vim.tbl_contains(files, "**/*.k8s.yaml"), true)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- The upgrade nobody asked for

T["legacy"] = new_set()

-- The promise made when the state file was introduced: a configuration that has
-- never seen the CLI keeps everything it had.
T["legacy"]["no selection leaves every component running"] = function()
  with(nil, function()
    local servers = opts_of("plugins.lsp", "mason-org/mason-lspconfig.nvim").automatic_enable
    local parsers = require("config.parsers")

    for _, server in ipairs({ "terraformls", "tflint", "helm_ls", "ansiblels", "dockerls", "yamlls" }) do
      eq({ server, vim.tbl_contains(servers, server) }, { server, true })
    end
    for _, parser in ipairs({ "terraform", "hcl", "helm", "gotmpl", "dockerfile", "yaml" }) do
      eq({ parser, vim.tbl_contains(parsers, parser) }, { parser, true })
    end

    eq(spec_enabled("plugins.devops", "ramilito/kubectl.nvim"), true)
    eq(spec_enabled("plugins.devops", "mfussenegger/nvim-ansible"), true)
    eq(spec_enabled("plugins.lsp", "towolf/vim-helm"), true)

    -- Including the two the contract only learnt to describe in version 4: a
    -- configuration that predates the CLI keeps its Terraform formatting and
    -- its Kubernetes schema.
    local by_ft = opts_of("plugins.formatting", "stevearc/conform.nvim").formatters_by_ft
    eq(type(by_ft.terraform), "function")
    eq(type(by_ft.hcl), "function")
    eq(vim.tbl_count(require("chroma.schemas").yaml()), 1)

    local names = modules_set_up()
    eq(names, { "chroma-aws", "chroma-terraform", "chroma-vault" })

    eq(registered_linters()["yaml.ansible"], { "ansible_lint" })
    eq(registered_linters().dockerfile, { "hadolint" })
  end)
end

return T
