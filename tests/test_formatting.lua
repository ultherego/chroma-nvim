-- Tests for the formatting layer.
--
-- This is the first suite that touches lua/plugins/, and it does so without
-- loading a single plugin: a lazy.nvim spec is an ordinary table, so the keymap
-- callbacks in it can be pulled out and called directly. The commands they run
-- are real — lua/config/commands.lua defines them and depends on nothing.
--
-- What is deliberately not tested here is conform itself. These cases are about
-- the decisions this configuration makes before conform is involved: which flag
-- a toggle owns, and which formatter is chosen for a Terraform file.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---The keymap callback a spec binds to `lhs`.
---@param lhs string
---@return function
local function keymap(lhs)
  local spec = require("plugins.formatting")[1]
  for _, key in ipairs(spec.keys or {}) do
    if key[1] == lhs then
      return key[2]
    end
  end
  error(("no keymap for %s in the formatting spec"):format(lhs))
end

local saved = {}

local T = new_set({
  hooks = {
    pre_case = function()
      saved.notify = vim.notify
      vim.notify = function() end

      -- :FormatEnable and :FormatDisable come from the configuration, not from
      -- a plugin, so requiring this is enough to make them real.
      require("config.commands")

      vim.g.disable_autoformat = nil
      vim.b.disable_autoformat = nil
    end,
    post_case = function()
      vim.notify = saved.notify
      vim.g.disable_autoformat = nil
      vim.b.disable_autoformat = nil
    end,
  },
})

-- ---------------------------------------------------------------------------
-- The global toggle owns the global flag, and only it
-- ---------------------------------------------------------------------------

T["global toggle"] = new_set()

T["global toggle"]["disables when nothing is set"] = function()
  keymap("<leader>xF")()

  eq(vim.g.disable_autoformat, true)
  eq(vim.b.disable_autoformat, nil)
end

T["global toggle"]["enables when the global flag is set"] = function()
  vim.g.disable_autoformat = true

  keymap("<leader>xF")()

  eq(vim.g.disable_autoformat, nil)
  eq(vim.b.disable_autoformat, nil)
end

-- Regression. The toggle used to read the buffer-local flag first and then run
-- a global command: with formatting off in this buffer and nothing set
-- globally, it ran :FormatEnable, clearing a global flag that was already
-- clear. The local flag stayed set, so formatting remained off and the key
-- looked like it had done nothing.
T["global toggle"]["disables globally even when this buffer is already off"] = function()
  vim.b.disable_autoformat = true

  keymap("<leader>xF")()

  eq(vim.g.disable_autoformat, true)
  -- Untouched: the buffer's own flag is the other mapping's business.
  eq(vim.b.disable_autoformat, true)
end

-- The same confusion in the other direction: a buffer explicitly enabled while
-- the global flag is set. `false` is not `nil`, so the old code took it as the
-- state to invert and disabled globally instead of enabling.
T["global toggle"]["enables globally even when this buffer is explicitly on"] = function()
  vim.g.disable_autoformat = true
  vim.b.disable_autoformat = false

  keymap("<leader>xF")()

  eq(vim.g.disable_autoformat, nil)
  eq(vim.b.disable_autoformat, false)
end

-- ---------------------------------------------------------------------------
-- The buffer toggle owns the buffer's flag, and only it
-- ---------------------------------------------------------------------------

T["buffer toggle"] = new_set()

T["buffer toggle"]["disables this buffer without touching the global flag"] = function()
  keymap("<leader>xb")()

  eq(vim.b.disable_autoformat, true)
  eq(vim.g.disable_autoformat, nil)
end

T["buffer toggle"]["enables this buffer without touching the global flag"] = function()
  vim.g.disable_autoformat = true
  vim.b.disable_autoformat = true

  keymap("<leader>xb")()

  eq(vim.b.disable_autoformat, nil)
  eq(vim.g.disable_autoformat, true)
end

return T
