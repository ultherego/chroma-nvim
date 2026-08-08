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
      for _, module in ipairs({ "plugins.lsp", "plugins.lint", "plugins.devops", "config.parsers" }) do
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
  for _, module in ipairs({ "plugins.lsp", "plugins.lint", "plugins.devops", "config.parsers" }) do
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
    require("plugins.lint")
    -- The spec registers them in its config(), which needs the plugin; the
    -- contract is what it reads, so that is what is checked.
    local linters = require("chroma.components").contributions("linters", state.enabled_ids())

    eq(vim.tbl_contains(linters, "yamllint"), true)
    eq(vim.tbl_contains(linters, "hadolint"), false)
    eq(vim.tbl_contains(linters, "ansible_lint"), false)
    eq(vim.tbl_contains(linters, "actionlint"), false)
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
    eq(state.is_enabled("terraform"), true)
    eq(state.is_enabled("vault"), false)
    eq(state.is_enabled("aws"), false)
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

    -- Still an editor.
    eq(vim.tbl_contains(servers, "lua_ls"), true)
    eq(vim.tbl_contains(parsers, "lua"), true)
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
  end)
end

return T
