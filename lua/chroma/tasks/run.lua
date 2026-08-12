-- Starting a task.
--
-- The last step, and the shortest: everything has already been decided. The
-- directory is resolved, the argument vector is prepared, the overrides are
-- known, and somebody has said yes. This opens a terminal and starts the
-- process in it, and takes two decisions of its own — both from
-- `doc/CONTRACT.md`, "The execution layer".
--
--     one Run = one new process, with an identity of its own
--     the terminal survives the process, whatever it exits with
--
-- Neither is what the terminal library does by default, and both were measured
-- at the pinned commit rather than assumed:
--
--   * `toggle()` finds the terminal whose command, directory, environment and
--     count match and hides it. A second Run of one task would flicker a window
--     instead of running anything, so tasks use `open()`.
--   * a terminal's identity has no room for a task id, so two tasks running the
--     same command in the same place would collide. Each Run takes the next
--     number from one counter for the session, and that number is the count.
--     The counter is shared with every other Chroma module that opens a
--     terminal — see `chroma-ansible/run.lua` and its §15.5.1 — because a
--     second private counter starting at one recreates the collision this
--     bullet exists to prevent.
--   * `auto_close` is on by default through `interactive`, and it closes a
--     terminal whose process exited 0 — which is precisely the output somebody
--     wanted to read. It is off here, and because the library installs its
--     failure notice inside that same switch, reporting a non-zero exit becomes
--     this module's job.

local M = {}

--- Where the run counter lives. Not per task, not per group and — since
--- `chroma-ansible` opens terminals too — not per module either: the library
--- builds identity from the command, the directory, the environment and the
--- count, with no room for whoever opened it. Two tasks running the same thing
--- in the same place would share an identity on their first run each, and so
--- would a task and a planner run that happened to be `ansible-playbook` in the
--- same directory, which is a task a repository is allowed to declare.
---
--- A well-known variable rather than a shared module, so that neither module
--- has to require the other to agree with it.
local COUNTER = "chroma_terminal_run_id"

---How a terminal is opened.
---
---A variable because a test cannot open one: this is the boundary where the
---decisions above become somebody else's library, and what is worth checking is
---what we ask it for.
---@type fun(cmd: string[], opts: table): table
M.open = function(cmd, opts)
  return require("snacks").terminal.open(cmd, opts)
end

---How a failure is reported. Also a variable, and for the same reason.
---@type fun(message: string)
M.report = function(message)
  vim.notify(message, vim.log.levels.ERROR)
end

---What the process exited with, asked at the moment `TermClose` fires.
---
---A variable too, and not for symmetry: `vim.v.event` is read-only, so a test
---that could not replace this could only check that a handler was registered —
---never what the handler does with a failure, which is the part worth having.
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
    -- The output outlives the process. A successful `terraform plan` is the
    -- thing somebody opened this to read.
    auto_close = false,
  })

  terminal:on("TermClose", function()
    local status = M.status()
    if status ~= 0 then
      -- Reported, and nothing else: the window stays exactly as it is, with
      -- whatever the process printed before it gave up.
      M.report(("%s exited with %s"):format(task.name, status))
    end
  end, { buf = true })

  return terminal, id
end

return M
