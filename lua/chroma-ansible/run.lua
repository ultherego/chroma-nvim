-- Starting the playbook.
--
-- Everything has been decided by the time this runs: the directory is frozen,
-- the array is prepared, and somebody has answered yes to the preview. This
-- opens a terminal, starts the process in it, and refuses in the two cases
-- where what was agreed to no longer exists. The rules are
-- `doc/chroma-ansible-design.md`, sections 15.5 and 16.
--
--     one Run = one new process, with an identity of its own
--     the terminal survives the process, whatever it exits with
--
-- Neither is what the terminal library does by default, and both were measured
-- at the pinned commit (§20.8): `toggle()` finds the terminal whose command,
-- directory, environment and count match and hides it, so a second Run would
-- flicker a window instead of running anything; and `auto_close` is on by
-- default through `interactive`, closing a terminal whose process exited 0 —
-- which is exactly the output somebody wanted to read. The interactive defaults
-- are otherwise kept, because `BECOME password:` has to be answerable (§11).
--
-- **This is a second implementation of `chroma.tasks.run`'s policy, not a call
-- into it** (§15.5). The own modules are self-contained so that any of them can
-- be lifted into its own repository without edits, exactly as
-- `chroma-vault/runtime.lua` and `chroma-terraform/runtime.lua` already are.
-- The cost is that two copies can drift, and the answer is the same: a test
-- runs the invariants against both (§19.6).
--
-- **The run counter is one counter for all of Chroma** (§15.5.1). A terminal's
-- identity is its command, directory, environment and count, with no room for
-- the module that opened it, so a planner counting 1, 2, 3 beside Project Tasks
-- counting 1, 2, 3 would collide — and a Project Task declaring
-- `argv: ["ansible-playbook", …]` in the same directory is exactly what §2 says
-- a repository is allowed to write. A well-known variable rather than a shared
-- module, because a shared module would end the self-containment this file
-- pays for; lifted into its own repository, this becomes the only writer of a
-- counter nobody else increments.

local context = require("chroma-ansible.context")

local M = {}

--- Where the run counter lives, for every module of Chroma that opens a
--- terminal. Named here and in `chroma.tasks.run`, which moved onto it.
local COUNTER = "chroma_terminal_run_id"

---How a terminal is opened.
---
---A variable because a test cannot open one: this is the boundary where the
---decisions above become somebody else's library, and what is worth checking is
---what it is asked for.
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

---What stands between the confirmation and the process, if anything.
---
---Asked here rather than trusted from the planning steps: minutes may have
---passed while the operator read the preview, and a directory can be removed or
---a playbook made unreadable in that time (§16). The directory and the
---playbooks are the same question a recalled repeat asks (§14.4), so they are
---asked in the same place and answered the same way.
---
---`argv[0]` is this module's own addition, for the reason §15.2 gives:
---measured on Neovim 0.12.4, `jobstart` validates it after the terminal window
---already exists, so an unchecked path produces `E475` inside an empty window
---instead of a refusal that names it.
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

  return context.runnable(run.directory, run.plan.playbooks)
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

  -- No `env`: §3.5 wants the same effective environment for every subprocess of
  -- the run, and the way to have one is to edit none. The library extends the
  -- inherited environment rather than replacing it (§20.8), so passing nothing
  -- is inheriting everything.
  local terminal = M.open(command, {
    cwd = run.directory,
    count = id,
    -- The output outlives the process. A playbook that exited 0 is the run
    -- somebody opened this to read.
    auto_close = false,
  })

  terminal:on("TermClose", function()
    local status = M.status()
    if status ~= 0 then
      -- Reported, and nothing else: the window stays exactly as it is, with
      -- whatever Ansible printed before it gave up.
      M.report(("ansible-playbook exited with %s"):format(status))
    end
  end, { buf = true })

  return terminal, nil, id
end

return M
