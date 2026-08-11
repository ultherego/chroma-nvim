-- The terminal Chroma exposes.
--
-- snacks.nvim has had `Snacks.terminal` all along and this configuration never
-- put a key in front of it, so the feature was in the dependency and out of
-- reach. What that key is, is the part worth protecting: `<leader>xt` is Todo
-- comments and has been since before this, and the contract calls a keymap
-- conflict a bug rather than an inconvenience.
--
-- What toggling does — a shell in a split at the bottom, the same one each
-- time, identified by command, working directory, environment and count — is
-- upstream's behaviour at the pinned commit and is not restated here.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---The keys the snacks base spec binds.
---@return table<string, table>
local function bound()
  local keys = {}
  for _, spec in ipairs(require("plugins.ui")) do
    if spec[1] == "folke/snacks.nvim" then
      for _, key in ipairs(spec.keys or {}) do
        keys[key[1]] = key
      end
    end
  end
  return keys
end

local T = new_set()

T["the shell has a key in front of it"] = function()
  local key = bound()["<leader>xs"]

  if not key then
    error("nothing in the snacks spec binds <leader>xs")
  end
  eq(key.desc, "Shell")
  eq(type(key[2]), "function")
end

T["it does not take the key Todo comments already has"] = function()
  eq(bound()["<leader>xt"], nil)
end

return T
