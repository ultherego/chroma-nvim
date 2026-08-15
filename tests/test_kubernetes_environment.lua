-- What a cluster subprocess is given of the editor's environment.
--
-- The mechanism, not a provider: these cases never mention a cloud. A variable
-- that exists when the subprocess is built is a variable the subprocess gets,
-- whether Chroma has heard of it or not.
--
-- `kubectl.nvim` is not loaded by this suite, so the command layer is a
-- stand-in shaped like the one at the pinned commit: `PATH` and friends under
-- string keys, and whatever was configured as `KEY=VALUE` strings in the array
-- part.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local kubernetes = require("chroma.kubernetes")

local VARIABLE = "CHROMA_KUBE_AUTH"
local UNKNOWN = "CHROMA_CORP_CLUSTER_SOCKET"

local T = new_set({
  hooks = {
    pre_case = function()
      vim.env[VARIABLE] = nil
      vim.env[UNKNOWN] = nil
    end,
    post_case = function()
      vim.env[VARIABLE] = nil
      vim.env[UNKNOWN] = nil
    end,
  },
})

---A stand-in for `kubectl.actions.commands`.
---@param explicit string[]|nil what the plugin was configured to add
---@return table
local function command_layer(explicit)
  local module = { calls = 0 }

  module.configure_command = function(cmd, envs, args)
    module.calls = module.calls + 1

    local env = { PATH = vim.fn.environ().PATH }
    vim.list_extend(env, explicit or {})
    vim.list_extend(env, envs or {})

    local argv = { cmd }
    vim.list_extend(argv, args or {})

    return { env = env, args = argv }
  end

  return module
end

---Runs `fn` with `module` standing in for the plugin's command layer.
---@param module table
---@param fn fun(module: table)
local function with(module, fn)
  local saved = package.loaded["kubectl.actions.commands"]
  package.loaded["kubectl.actions.commands"] = module

  local ok, err = pcall(fn, module)

  package.loaded["kubectl.actions.commands"] = saved
  assert(ok, err)
end

---What a real child process sees, spawned the way `kubectl.nvim` spawns.
---@param env table
---@return string
local function child_sees(env)
  local process = vim.system({ "sh", "-c", ('printf %%s "$%s"'):format(VARIABLE) }, {
    text = true,
    env = env,
    clear_env = true,
  })

  return process:wait(5000).stdout or ""
end

T["the environment"] = new_set()

T["the environment"]["is what the subprocess is given"] = function()
  vim.env[VARIABLE] = "A"

  with(command_layer(), function(module)
    kubernetes.setup()

    eq(module.configure_command("kubectl", nil, { "get", "pods" }).env[VARIABLE], "A")
  end)
end

T["the environment"]["is read for every spawn, not once at setup"] = function()
  -- `<leader>Ap` changes a profile in the middle of a session. A snapshot
  -- taken when the plugin was configured would answer with the old one.
  vim.env[VARIABLE] = "A"

  with(command_layer(), function(module)
    kubernetes.setup()

    eq(module.configure_command("kubectl", nil, {}).env[VARIABLE], "A")

    vim.env[VARIABLE] = "B"

    eq(module.configure_command("kubectl", nil, {}).env[VARIABLE], "B")
  end)
end

T["the environment"]["carries a variable Chroma has never heard of"] = function()
  -- No allowlist: the next provider, the next helper, the next proxy.
  vim.env[UNKNOWN] = "/run/cluster-helper.sock"

  with(command_layer(), function(module)
    kubernetes.setup()

    eq(module.configure_command("kubectl", nil, {}).env[UNKNOWN], "/run/cluster-helper.sock")
  end)
end

T["the environment"]["is not what the editor started with, but what it has now"] = function()
  vim.env[VARIABLE] = "A"

  with(command_layer(), function(module)
    kubernetes.setup()

    eq(child_sees(module.configure_command("kubectl", nil, {}).env), "A")

    vim.env[VARIABLE] = "B"

    eq(child_sees(module.configure_command("kubectl", nil, {}).env), "B")
  end)
end

T["the plugin's own values"] = new_set()

T["the plugin's own values"]["win over the environment"] = function()
  vim.env[VARIABLE] = "from the session"

  with(command_layer({ VARIABLE .. "=from the plugin" }), function(module)
    kubernetes.setup()

    eq(module.configure_command("kubectl", nil, {}).env[VARIABLE], "from the plugin")
  end)
end

T["the plugin's own values"]["win when a caller passes them, too"] = function()
  vim.env[VARIABLE] = "from the session"

  with(command_layer(), function(module)
    kubernetes.setup()

    local command = module.configure_command("kubectl", { VARIABLE .. "=from the caller" }, {})

    eq(command.env[VARIABLE], "from the caller")
  end)
end

T["the plugin's own values"]["win under a string key as well as in the array"] = function()
  vim.env.KUBECONFIG = "/from/the/session"

  local module = command_layer()
  local configure = module.configure_command
  module.configure_command = function(...)
    local command = configure(...)
    command.env.KUBECONFIG = "/from/the/plugin"
    return command
  end

  with(module, function()
    kubernetes.setup()

    eq(module.configure_command("kubectl", nil, {}).env.KUBECONFIG, "/from/the/plugin")
  end)

  vim.env.KUBECONFIG = nil
end

T["the plugin's own values"]["survive an entry that names no variable"] = function()
  vim.env[VARIABLE] = "A"

  with(command_layer({ "NOT_AN_ASSIGNMENT" }), function(module)
    kubernetes.setup()

    eq(module.configure_command("kubectl", nil, {}).env[VARIABLE], "A")
  end)
end

T["everything else"] = new_set()

T["everything else"]["is left alone: the argument vector is the plugin's"] = function()
  with(command_layer(), function(module)
    kubernetes.setup()

    eq(module.configure_command("kubectl", nil, { "get", "pods", "-A" }).args, { "kubectl", "get", "pods", "-A" })
  end)
end

T["everything else"]["includes the command layer itself: setup does not stack"] = function()
  with(command_layer(), function(module)
    kubernetes.setup()
    local wrapped = module.configure_command

    kubernetes.setup()

    eq(module.configure_command == wrapped, true)
  end)
end

return T
