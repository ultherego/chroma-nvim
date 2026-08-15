---What a cluster subprocess sees of the environment.
---
---`kubectl.nvim` builds every subprocess environment in
---`kubectl.actions.commands.configure_command` and spawns with
---`clear_env = true`, keeping `PATH`, `HOME`, `KUBECONFIG` and `KUBECACHEDIR`
---of the editor's own environment and nothing else. Authentication needs more
---than that, and what it needs depends on the cluster: `AWS_PROFILE` for EKS,
---`GOOGLE_APPLICATION_CREDENTIALS` for GKE, `AZURE_CONFIG_DIR`, a proxy, a CA
---bundle, a socket a company helper listens on. `<leader>Ap` changes the
---profile inside the session, and a stripped environment means the change
---reaches nothing.
---
---So: the environment is read at every spawn, and the plugin's own values win
---over it. Chroma decides nothing about authentication here and names no
---provider — it stops an environment from being thrown away.
---
---Not a module a component contributes: a compatibility layer over one
---plugin, installed from that plugin's own `config`.

local M = {}

---The command tables already wrapped. Weak keys: a reloaded plugin is a new
---table, and holding the old one would keep a dead module alive.
local patched = setmetatable({}, { __mode = "k" })

---The editor's environment as it is now, with `explicit` applied over it.
---
---`configure_command` produces a hybrid: `PATH` and friends under string keys,
---and whatever `kubectl_cmd.env` or a caller passed as `KEY=VALUE` strings in
---the array part. Measured on 0.12.4: `vim.system` reads the string keys and
---ignores the array part, so everything is normalised to the form that is
---actually delivered to the child.
---@param explicit table|nil the environment `kubectl.nvim` asked for
---@return table<string, string>
local function merged(explicit)
  local environment = vim.fn.environ()

  for key, value in pairs(explicit or {}) do
    if type(key) == "number" then
      -- An entry with no `=` names no variable, and vim.system would not have
      -- carried it either.
      local name, set = tostring(value):match("^([^=]+)=(.*)$")
      if name then
        environment[name] = set
      end
    else
      environment[key] = value
    end
  end

  return environment
end

---Installs the environment policy on `kubectl.nvim`'s command layer.
---
---Called after the plugin's own `setup`, and safe to call again: a second call
---on the same command table does nothing rather than stacking a wrapper.
function M.setup()
  local commands = require("kubectl.actions.commands")

  if patched[commands] then
    return
  end

  local configure = commands.configure_command
  -- Louder than an environment that quietly went back to four variables.
  assert(type(configure) == "function", "kubectl.nvim: no configure_command to take the environment from")

  commands.configure_command = function(...)
    local command = configure(...)
    -- Read here rather than at setup: the environment moves during a session,
    -- and a snapshot taken now would be the profile the editor started with.
    command.env = merged(command.env)
    return command
  end

  patched[commands] = true
end

return M
