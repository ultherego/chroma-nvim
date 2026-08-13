-- Starting the playbook: everything is decided, so this opens a terminal, starts
-- the process, and refuses where what was agreed to no longer exists (§15.5, §16).
--
-- Measured at the pinned commit (§20.8): `toggle()` would hide a matching
-- terminal rather than run anything, and `auto_close` closes a terminal that
-- exited 0. The other interactive defaults stay, because `BECOME password:` has
-- to be answerable (§11).
--
-- A second implementation of `chroma.tasks.run`'s policy rather than a call into
-- it, so these modules stay liftable (§15.5); a test runs the invariants against
-- both. The run counter is one counter for all of Chroma (§15.5.1).

local context = require("chroma-ansible.context")

local M = {}

--- Where the run counter lives, for every module of Chroma that opens a
--- terminal. Named here and in `chroma.tasks.run`, which moved onto it.
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

---What stands between the confirmation and the process, if anything. Asked here
---rather than trusted from the planning steps: minutes can pass while somebody
---reads the preview (§16), and the same question a recalled repeat asks (§14.4)
---is answered in the same place.
---
---`argv[0]` is this module's addition (§15.2): measured on 0.12.4, `jobstart`
---validates it after the terminal window exists, so an unchecked path gives
---`E475` inside an empty window instead of a refusal that names it.
---@param run chroma_ansible.Run
---@param command string[]
---@return string|nil problem
local function refusal(run, command)
  local gone = context.still_usable(run.directory)
  if gone then
    return gone
  end

  if vim.uv.fs_access(command[1], "X") ~= true then
    return ("%s is no longer an executable this user can run"):format(command[1])
  end

  return context.runnable(run.directory, run.plan.playbooks, run.plan.inventory)
end

---Starts the run the preview described.
---
---@param run chroma_ansible.Run
---@param command string[] the prepared array, the same one the preview showed
---@return table|nil terminal, string|nil problem, integer|nil id
function M.start(run, command)
  local problem = refusal(run, command)
  if problem then
    return nil, problem
  end

  local id = (vim.g[COUNTER] or 0) + 1
  vim.g[COUNTER] = id

  -- No `env`: §3.5 wants one effective environment for every subprocess of the
  -- run, and the library extends the inherited one rather than replacing it.
  local terminal = M.open(command, {
    cwd = run.directory,
    count = id,
    -- The output outlives the process; a playbook that exited 0 is what was
    -- opened to be read.
    auto_close = false,
  })

  terminal:on("TermClose", function()
    local status = M.status()
    if status ~= 0 then
      -- Reported and nothing else: the window keeps whatever Ansible printed.
      M.report(("ansible-playbook exited with %s"):format(status))
    end
  end, { buf = true })

  return terminal, nil, id
end

return M
