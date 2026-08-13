-- Starting a task: everything is already decided, so this opens a terminal and
-- starts the process. Two rules from `doc/CONTRACT.md`, "The execution layer" —
-- one Run is one new process with an identity of its own, and the terminal
-- survives whatever it exits with — and neither is the library's default.
--
-- Measured at the pinned commit: `toggle()` would hide a matching terminal
-- rather than run anything, so this uses `open()`; and `auto_close` closes a
-- terminal that exited 0, which is exactly the output somebody wanted to read.

local M = {}

--- Shared with every other Chroma module that opens a terminal, because the
--- library builds identity from command, directory, environment and count, with
--- no room for whoever opened it. A well-known variable rather than a shared
--- module, so neither side has to require the other to agree.
local COUNTER = "chroma_terminal_run_id"

---A variable because a test cannot open one: this is the boundary where the
---decisions above become somebody else's library.
---@type fun(cmd: string[], opts: table): table
M.open = function(cmd, opts)
  return require("snacks").terminal.open(cmd, opts)
end

---How a failure is reported. Also a variable, and for the same reason.
---@type fun(message: string)
M.report = function(message)
  vim.notify(message, vim.log.levels.ERROR)
end

---What the process exited with, asked when `TermClose` fires. A variable
---because `vim.v.event` is read-only, so a test could otherwise only check that
---a handler was registered, never what it does with a failure.
---@type fun(): integer
M.status = function()
  local event = vim.v.event
  return type(event) == "table" and event.status or 0
end

---Starts a prepared task.
---
---@param task table the task, for what it is called in a failure
---@param directory string the working directory, already resolved
---@param prepared table the prepared { argv, env } from chroma.tasks.command
---@return table terminal, integer run_id
function M.start(task, directory, prepared)
  local id = (vim.g[COUNTER] or 0) + 1
  vim.g[COUNTER] = id

  local terminal = M.open(prepared.argv, {
    cwd = directory,
    env = prepared.env,
    count = id,
    -- The output outlives the process; a successful plan is what was wanted.
    auto_close = false,
  })

  terminal:on("TermClose", function()
    local status = M.status()
    if status ~= 0 then
      -- Reported and nothing else: the window keeps whatever was printed.
      M.report(("%s exited with %s"):format(task.name, status))
    end
  end, { buf = true })

  return terminal, id
end

return M
