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

---How the process itself is started, once there is a buffer to start it in.
---A variable for the same reason, and separately from `M.open`, because the
---window is the library's and the process is not.
---@type fun(cmd: string[], options: table): integer
M.spawn = function(cmd, options)
  return vim.fn.jobstart(cmd, options)
end

---What the playbook's process starts with. The one place §3.5's execution half
---is kept, named so that a test can cross a real process boundary with exactly
---this table.
---
---`clear_env`, not `env` alone: measured on 0.12.4, both `jobstart` and
---`vim.system` merge `env` over the editor's current environment. A variable
---invented after the run began would reach the playbook, having reached none of
---the inspections that decided what the playbook would do.
---@param opts table the library's resolved options, carrying `cwd` and `env`
---@return table
function M.job(opts)
  return {
    cwd = opts.cwd,
    env = opts.env,
    clear_env = true,
    term = true,
  }
end

---Starts the process in the window the library was about to make.
---
---`override` is the library's own hook for this — *use a different terminal
---implementation* — and it is taken before any window or job exists, so what
---changes is the spawn and nothing about the window: `opts.win` has already
---been resolved and is used as it stands.
---
---It has to change because the library passes `jobstart` only `cwd`, `env` and
---`term`, and `clear_env` is what makes the frozen environment the whole answer
---rather than an overlay on the editor's. There is no way to reach it through
---`terminal.open`, and the alternative — editing `vim.env` around the call —
---would be a global mutable window in place of the problem it fixes.
---@param cmd string[]
---@param opts table
---@return table terminal
function M.override(cmd, opts)
  local terminal = require("snacks").win(opts.win)
  terminal:show()

  vim.api.nvim_buf_call(terminal.buf, function()
    M.spawn(cmd, M.job(opts))
  end)

  -- §11: `BECOME password:` has to be answerable. The library arranges this
  -- after the point `override` takes, so it is arranged here instead.
  terminal:on("BufEnter", function()
    vim.cmd.startinsert()
  end, { buf = true })
  if vim.api.nvim_get_current_buf() == terminal.buf then
    vim.cmd.startinsert()
  end

  return terminal
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

  local terminal = M.open(command, {
    cwd = run.directory,
    -- §3.5: the environment the inspections ran in, not the one the editor
    -- happens to hold now. `M.override` is what makes it exact.
    env = run.environment,
    count = id,
    -- The output outlives the process; a playbook that exited 0 is what was
    -- opened to be read.
    --
    -- Inert while `override` is in place — the library's auto-close is wired
    -- after the point the hook takes — and passed anyway, because it is the
    -- declared policy and removing the hook must not silently flip it back to
    -- the library's interactive default of closing on success.
    auto_close = false,
    override = M.override,
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
