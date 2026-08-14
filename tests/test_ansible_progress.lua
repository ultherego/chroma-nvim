-- The window an inspection runs behind, with real windows.
--
-- One thing is being checked from several directions: an inspection that
-- finished takes its own window away, and that must never be mistaken for the
-- operator saying no. Every other way the window can disappear is the operator
-- saying no, because a window that is gone while a subprocess is still running
-- is exactly the state §13.4 exists to prevent.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local progress = require("chroma-ansible.progress")

---Opens one, and counts the cancellations it reports.
---@return { close: fun() }, { count: integer }
local function opened()
  local cancelled = { count = 0 }
  local handle = progress.open("Resolving inventory", function()
    cancelled.count = cancelled.count + 1
  end)
  return handle, cancelled
end

---The floating windows that are not the one this suite started in.
---@return integer[]
local function floats()
  local found = {}
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(window).relative ~= "" then
      table.insert(found, window)
    end
  end
  return found
end

---The buffer-local normal-mode mapping for `key`, or nil. Compared through
---`nvim_replace_termcodes` because `<Esc>` is written one way and stored
---another.
---@param buffer integer
---@param key string
---@return table|nil
local function mapping(buffer, key)
  local want = vim.api.nvim_replace_termcodes(key, true, true, true)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buffer, "n")) do
    if vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == want then
      return map
    end
  end
  return nil
end

local T = new_set({
  hooks = {
    post_case = function()
      for _, window in ipairs(floats()) do
        pcall(vim.api.nvim_win_close, window, true)
      end
    end,
  },
})

-- ---------------------------------------------------------------------------
-- Showing

T["showing"] = new_set()

T["showing"]["puts one window up and does not enter it"] = function()
  local before = vim.api.nvim_get_current_win()

  opened()

  eq(#floats(), 1)
  -- An inspection is something the editor is doing, not something it is asking.
  eq(vim.api.nvim_get_current_win(), before)
end

T["showing"]["says what is happening and how to stop it"] = function()
  opened()

  local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(floats()[1]), 0, -1, false)[1]
  eq(line:find("Resolving inventory", 1, true) ~= nil, true)
  eq(line:find("Cancel", 1, true) ~= nil, true)
  eq(line:find(":AnsibleCancel", 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- The two doors

T["closing"] = new_set()

T["closing"]["takes the window away without saying anybody cancelled"] = function()
  -- The inspection answered. Nothing was refused, and treating this as a
  -- cancellation would end a run at the moment it succeeded.
  local handle, cancelled = opened()

  handle.close()

  eq(#floats(), 0)
  eq(cancelled.count, 0)
end

T["closing"]["twice is not two events"] = function()
  local handle, cancelled = opened()

  handle.close()
  handle.close()

  eq(cancelled.count, 0)
end

T["cancelling"] = new_set()

T["cancelling"]["is what the window going away any other way means"] = new_set({
  -- §13.4: however it went, the operator is no longer watching an inspection
  -- they cannot see. Each of these is a different event inside Neovim.
  parametrize = { { "window" }, { "buffer" } },
})

T["cancelling"]["is what the window going away any other way means"][""] = function(how)
  local _, cancelled = opened()
  local window = floats()[1]
  local buffer = vim.api.nvim_win_get_buf(window)

  if how == "window" then
    vim.api.nvim_win_close(window, true)
  else
    vim.api.nvim_buf_delete(buffer, { force = true })
  end

  eq(cancelled.count, 1)
  eq(#floats(), 0)
end

T["cancelling"]["is what the keys inside it mean"] = new_set({
  parametrize = { { "<Esc>" }, { "q" }, { "<CR>" } },
})

T["cancelling"]["is what the keys inside it mean"][""] = function(key)
  local _, cancelled = opened()

  local bound = mapping(vim.api.nvim_win_get_buf(floats()[1]), key)
  eq({ key, bound ~= nil }, { key, true })

  bound.callback()

  eq(cancelled.count, 1)
end

T["cancelling"]["once is once, however many ways it then unwinds"] = function()
  -- Cancelling closes the window, which is itself one of the ways a
  -- cancellation is reported. It must not come back round.
  local _, cancelled = opened()

  mapping(vim.api.nvim_win_get_buf(floats()[1]), "q").callback()

  eq(cancelled.count, 1)
  eq(#floats(), 0)
end

T["cancelling"]["after the inspection already answered is not an event"] = function()
  local handle, cancelled = opened()

  handle.close()
  -- Whatever the operator does now, they are doing it to a window that is gone.
  eq(cancelled.count, 0)
end

return T
