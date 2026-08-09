---External tools: the ones that belong to the user, not to Chroma.
---
---Chroma does not install `terraform`, `kubectl`, `helm`, `ansible`, `aws` or
---`docker`, and enabling a component does not ask for them. Enabling the
---kubernetes component asks for Chroma's Kubernetes features; the CLI those
---features shell out to is the user's to provide. So the question "is it here"
---is asked at the moment somebody runs the thing — never by the installer,
---which would be refusing to install an editor over a missing CLI.
---
---This holds the two ways of asking, so that the answer is reached the same way
---everywhere. It deliberately does not hold a `notify`-and-refuse helper: every
---place in this configuration that runs an external process already checks
---first and returns an error to its caller, with wording those callers' tests
---pin. A third shape would be a third thing to keep in step.

local M = {}

---Reports whether `name` is on PATH.
---@param name string
---@return boolean
function M.have(name)
  return vim.fn.executable(name) == 1
end

---Returns the first of `names` that is on PATH, or nil.
---
---For requirements the contract writes as alternatives — terraform or tofu, cc
---or gcc or clang. First-present is the same rule `chroma doctor` and the
---installer use, so the three cannot disagree about which binary a machine is
---going to run.
---@param names string[]
---@return string|nil
function M.first(names)
  for _, name in ipairs(names) do
    if vim.fn.executable(name) == 1 then
      return name
    end
  end
  return nil
end

return M
