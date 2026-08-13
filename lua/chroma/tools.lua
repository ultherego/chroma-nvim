---External tools: the ones that belong to the user, not to Chroma. `is it
---here` is asked when somebody runs the thing, never by the installer, which
---would be refusing to install an editor over a missing CLI.
---
---Deliberately no notify-and-refuse helper: every caller already checks and
---returns an error whose wording its own tests pin.

local M = {}

---Reports whether `name` is on PATH.
---@param name string
---@return boolean
function M.have(name)
  return vim.fn.executable(name) == 1
end

---Returns the first of `names` that is on PATH, or nil.
---
---For requirements the contract writes as alternatives. First-present is the
---rule `chroma doctor` and the installer use too, so the three cannot disagree.
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
